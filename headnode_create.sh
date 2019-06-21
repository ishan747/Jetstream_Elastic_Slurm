#!/bin/bash

if [[ ! -e ./openrc.sh ]]; then
  echo "NO OPENRC FOUND! CREATE ONE, AND TRY AGAIN!"
  exit
fi

if [[ -z "$1" ]]; then
  echo "NO SERVER NAME GIVEN! Please re-run with ./headnode_create.sh <server-name>"
  exit
fi

if [[ ! -e ${HOME}/.ssh/id_rsa.pub ]]; then
#This may be temporary... but seems fairly reasonable.
  echo "NO KEY FOUND IN ${HOME}/.ssh/id_rsa.pub! - please create one and re-run!"
  exit
fi

# source ./openrc.sh

# Defining a function here to check for quotas, and exit if this script will cause problems!
# also, storing 'quotas' in a global var, so we're not calling it every single time
quotas=$(openstack quota show)
quota_check ()
{
quota_name=$1
type_name=$2 #the name for a quota and the name for the thing itself are not the same
number_created=$3 #number of the thing that we'll create here.

current_num=$(openstack $type_name list -f value | wc -l)

max_types=$(echo "$quotas" | awk -v quota=$quota_name '$0 ~ quota {print $4}')

#echo "checking quota for $quota_name of $type_name to create $number_created - want $current_num to be less than $max_types"

if [[ "$current_num" -lt "$((max_types + number_created))" ]]; then
  return 0
fi
return 1
}


quota_check "networks" "network" 1
quota_check "subnets" "subnet" 1
quota_check "routers" "router" 1
quota_check "key-pairs" "keypair" 1
quota_check "instances" "server" 1

# Ensure that the correct private network/router/subnet exists
if [[ -z "$(openstack network list | grep ${OS_USERNAME}-elastic-net)" ]]; then
  openstack network create ${OS_USERNAME}-elastic-net
  openstack subnet create --network ${OS_USERNAME}-elastic-net --subnet-range 10.0.0.0/24 ${OS_USERNAME}-elastic-subnet1
fi
##openstack subnet list
if [[ -z "$(openstack router list | grep ${OS_USERNAME}-elastic-router)" ]]; then
  openstack router create ${OS_USERNAME}-elastic-router
  openstack router add subnet ${OS_USERNAME}-elastic-router ${OS_USERNAME}-elastic-subnet1
  openstack router set --external-gateway bright-external-flat-externalnet ${OS_USERNAME}-elastic-router
fi
#openstack router show ${OS_USERNAME}-api-router

security_groups=$(openstack security group list -f value)
if [[ ! ("$security_groups" =~ "${OS_USERNAME}-global-ssh") ]]; then
  openstack security group create --description "ssh \& icmp enabled" $OS_USERNAME-global-ssh
  openstack security group rule create --protocol tcp --dst-port 22:22 --remote-ip 0.0.0.0/0 $OS_USERNAME-global-ssh
  openstack security group rule create --protocol icmp $OS_USERNAME-global-ssh
fi
if [[ ! ("$security_groups" =~ "${OS_USERNAME}-cluster-internal") ]]; then
  openstack security group create --description "internal group for cluster" $OS_USERNAME-cluster-internal
  openstack security group rule create --protocol tcp --dst-port 1:65535 --remote-ip 10.0.0.0/0 $OS_USERNAME-cluster-internal
  openstack security group rule create --protocol icmp $OS_USERNAME-cluster-internal
fi

#Check if ${HOME}/.ssh/id_rsa.pub exists in JS
if [[ -e ${HOME}/.ssh/id_rsa.pub ]]; then
  home_key_fingerprint=$(ssh-keygen -l -E md5 -f ${HOME}/.ssh/id_rsa.pub | sed  's/.*MD5:\(\S*\) .*/\1/')
fi
#echo $home_key_fingerprint
openstack_keys=$(openstack keypair list -f value)
echo $openstack_keys

home_key_in_OS=$(echo "$openstack_keys" | awk -v mykey=$home_key_fingerprint '$2 ~ mykey {print $1}')

if [[ -n "$home_key_in_OS" ]]; then
  OS_keyname=$home_key_in_OS
elif [[ -n $(echo "$openstack_keys" | grep ${OS_USERNAME}-elastic-key) ]]; then
  openstack keypair delete ${OS_USERNAME}-elastic-key
# This doesn't need to depend on the OS_PROJECT_NAME, as the slurm-key does, in install.sh and slurm_resume
  openstack keypair create --public-key ${HOME}/.ssh/id_rsa.pub ${OS_USERNAME}-elastic-key
  OS_keyname=${OS_USERNAME}-elastic-key
else
# This doesn't need to depend on the OS_PROJECT_NAME, as the slurm-key does, in install.sh and slurm_resume
  openstack keypair create --public-key ${HOME}/.ssh/id_rsa.pub ${OS_USERNAME}-elastic-key
  OS_keyname=${OS_USERNAME}-elastic-key
fi

image_name="CentOS-7-x86_64-GenericCloud-1905"
echo "openstack server create --user-data prevent-updates.ci --flavor m1.large --image $image_name --key-name $OS_keyname --security-group $OS_USERNAME-global-ssh --security-group $OS_USERNAME-cluster-internal --nic net-id=${OS_USERNAME}-elastic-net $1"
openstack server create --user-data prevent-updates.ci --flavor m1.large --image $image_name --key-name $OS_keyname --security-group ${OS_USERNAME}-global-ssh --security-group ${OS_USERNAME}-cluster-internal --nic net-id=${OS_USERNAME}-elastic-net $1
public_ip="192.168.16.144"
public_ip_ext="164.111.161.144"
#public_ip=$(openstack floating ip create bright-external-flat-externalnet | awk '/floating_ip_address/ {print $4}')
#For some reason there's a time issue here - adding a sleep command to allow network to become ready
sleep 10
openstack server add floating ip $1 $public_ip

hostname_test=$(ssh -q -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no centos@$public_ip_ext 'hostname')
echo "test1: $hostname_test"
until [[ $hostname_test =~ "$1" ]]; do
  sleep 2
  hostname_test=$(ssh -q -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no centos@$public_ip_ext 'hostname')
  echo "ssh -q -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no centos@$public_ip_ext 'hostname'"
  echo "test2: $hostname_test"
done

scp -qr -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no ${PWD} centos@$public_ip_ext:

echo "You should be able to login to your server with your Jetstream key: $OS_keyname, at $public_ip_ext"
