#!/bin/bash

# This script will go through and configure Strongswan according to users input in Cloudformation. 

# Get userdata and variables
source /etc/strongswan/variables
MY_ID=$(curl http://169.254.169.254/latest/meta-data/instance-id)
MY_EIP=$(curl http://169.254.169.254/latest/meta-data/public-ipv4)

# Map user friendly DH group to Strongswan keyword
groups=( ["Group2"]="modp1024" ["Group5"]="modp1536" ["Group14"]="modp2048" ["Group15"]="modp3072" ["Group16"]="modp4096" ["Group17"]="modp6144" ["Group18"]="modp8192" ["Group22"]="modp1024s160" ["Group23"]="modp2048s224" ["Group24"]="modp2048s256" ["Group25"]="ecp192" ["Group26"]="ecp224" ["Group19"]="ecp256" ["Group20"]="ecp384" ["Group21"]="ecp521" ["Group27"]="ecp224bp" ["Group28"]="ecp256bp" ["Group29"]="ecp384bp" ["Group30"]="ecp512bp" )


# Remove any whitespacing from commadelimitedlist variables. Lowercase NAT variable
ONPREM=$(echo ${ONPREM//[[:blank:]]/})
NAT=$(echo ${NAT//[[:blank:]]/})
NAT=$(echo "$NAT" | tr '[:upper:]' '[:lower:]')

# Detect if user wants to NAT their traffic. If they do, then set the NAT to their local LEFTSUBNET=, otherwise use their VPC CIDR. Also, if they are using NAT determine if it is dynamic or 1:1, and create the iptables accordingly.
if [ "$NAT" == "disabled" ]
then
        LEFTSUBNET=$(aws ec2 describe-vpcs --vpc-ids ${VPC} --region us-west-2 --query 'Vpcs[*].[CidrBlock]' --output text)
else
        if [[ "$NAT" =~ [,]+ ]]
        then
                count=0
                for ip in $(echo $NAT | sed "s/,/\n/g");do
                        count=$((count + 1))
                        if ! ((count % 2)) # Checks if IP is even index in list. If it is, then its the NAT IP. Odd index is the actual VPC host IP to be translated.
                        then
						    NAT_IPs+=("$ip")
							LEFTSUBNET+="${ip}/32,"
						elif ((count % 2))
						then
							REAL_IPs+=("$ip")
                        fi
				done
                LEFTSUBNET=${LEFTSUBNET::-1}
				x=0
				for i in "${REAL_IPs[@]}"; do
						iptables -t nat -A POSTROUTING -s $i -j SNAT --to-source ${NAT_IPs[$x]}
						iptables -t nat -A PREROUTING -d ${NAT_IPs[$x]} -j DNAT --to-destination $i
						(( ++x ))
				done
        else
                LEFTSUBNET=$NAT
				VPC_CIDR=$(aws ec2 describe-vpcs --vpc-ids ${VPC} --region us-west-2 --query 'Vpcs[*].[CidrBlock]' --output text)
				for NET in $(echo $ONPREM | sed "s/,/\n/g");do
					iptables -t nat -A POSTROUTING -s $VPC_CIDR -d $NET -j NETMAP --to $NAT
					iptables -t nat -A PREROUTING -d $NAT -j NETMAP --to $VPC_CIDR
				done
        fi
fi

#This next section will update all the relevant SGs and VPC route tables in this VPC, so that EC2s can openly communication via the Strongswan box
# Get all the route table ids in this VPC
route_tables=$(aws ec2 describe-route-tables --region ${REGION} --query 'RouteTables[*].[VpcId==`'${VPC}'`,RouteTableId]' --output text | grep True | awk '{print $2}')

# Check what routes are in each route table
existing_routes () {
aws ec2 describe-route-tables --region ${REGION} --query 'RouteTables[?RouteTableId==`'$1'`].Routes[*]' --output text | awk '{print $1}'
}

# Update the VPC route table(s) with route to on-prem network
create_onprem_route () {
aws ec2 create-route --region $REGION --route-table-id $1 --destination-cidr-block $2 --instance-id $MY_ID
}

# List the security group ids for this VPC
security_groups=$(aws ec2 describe-security-groups --region ${REGION} --query 'SecurityGroups[*].[VpcId==`'${VPC}'`,GroupId]' --output text | grep True | awk '{print $2}')

# Update SGs to allow traffic from another SG
update_sg () {
aws ec2 authorize-security-group-ingress --region $REGION --group-id $1 --protocol all --source-group $2
} 




# Loop will go through each route table in this VPC, and if there is no conflicting route for on-prem, will point on-prem route to Openswan ENI
for table in $route_tables;do
	existing_rts=$(existing_routes $table)
	for onprem in $(echo $ONPREM | sed "s/,/\n/g");do	
		conflict=0
		for route in $existing_rts; do

			if [ "$route" == "$onprem" ]
			then
				conflict=1
				break
			fi
			done
		if [ $conflict -eq 0 ]
		then
			echo "NO conflict for $onprem in $table"
			create_onprem_route $table $onprem
		else
			echo "conflict for $onprem in $table"
		fi
	done
done	
# This next loop will go through and allow all security groups in the VPC to communicate with the Openswan EC2, and vice versa
for sg in $security_groups; do
	update_sg $sg $SG_ID
	update_sg $SG_ID $sg
done

# Create the IPSEC config file for strongswan
CONFIG="/etc/strongswan/${NAME}.vpn.conf"
ESP="${P2ENC}-${P2HASH}-${groups[${PFS}]}"
if [ "$PFS" == "Skip" ] && [ "$TYPE" == "route-based" ] # if user chose route-based VPN with ikev1 PFS disabled, we don't need to know phase 1 or phase 2 parameters from peer
then
  cat <<EOF > $CONFIG
conn $NAME
	auto=add
	type=tunnel
	authby=secret
	leftid=$MY_EIP
	left=%defaultroute
	right=$PEER
	rekey=no
	leftsubnet=0.0.0.0/0
	rightsubnet=0.0.0.0/0
	mark=50
	leftupdown="/etc/strongswan/aws.updown -ln vti0 -ll ${LINKLOCAL} -lr ${LINKREMOTE} -m 50"
EOF
chmod 644 $CONFIG
	
elif [ "$PFS" != "Skip" ] && [ "$TYPE" == "route-based" ] # if user chose route-based with ikev1 PFS enabled, we must specify ESP parameters expected from peer
then
		cat <<EOF > $CONFIG
conn $NAME
	auto=add
	type=tunnel
	authby=secret
	leftid=$MY_EIP
	left=%defaultroute
	right=$PEER
	esp=$ESP
	rekey=no
	leftsubnet=0.0.0.0/0
	rightsubnet=0.0.0.0/0
	mark=50
	leftupdown="/etc/strongswan/aws.updown -ln vti0 -ll ${LINKLOCAL} -lr ${LINKREMOTE} -m 50"
EOF
chmod 644 $CONFIG

elif [ "$PFS" == "Skip" ] && [ "$TYPE" == "policy-based" ] # if user chose policy-based with ikev1 PFS disabled, we need to specify subnets
then
		cat <<EOF > $CONFIG
conn $NAME
	auto=add
	type=tunnel
	authby=secret
	leftid=$MY_EIP
	left=%defaultroute
	right=$PEER
	rekey=no
	leftsubnet=$LEFTSUBNET
	rightsubnet=$ONPREM
EOF
chmod 644 $CONFIG
			
elif [ "PFS" != "Skip" ] && [ "$TYPE" == "policy-based" ] # if user chose policy-based with ikev1 PFS enabled. We need to specify subnets as well as ESP parameters
then 
		cat <<EOF > $CONFIG
conn $NAME
	auto=add
	type=tunnel
	authby=secret
	leftid=$MY_EIP
	left=%defaultroute
	right=$PEER
	esp=$ESP
	rekey=no
	leftsubnet=$LEFTSUBNET
	rightsubnet=$ONPREM
EOF
chmod 644 $CONFIG
fi

# Create PSK file
cat <<EOF > /etc/strongswan/${NAME}.vpn.secrets
$PEER : PSK "${PSK}"
EOF
chmod 644 /etc/strongswan/${NAME}.vpn.secrets

# Remove this script. It only neeeds to run once for initial setup
rm -- "$0"