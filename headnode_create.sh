#!/bin/bash

SSH_PUB_KEY=cri_cluster_test.pub
SSH_KEY=cri_cluster_test

if [[ ! -e ./openrc.sh ]]; then
  echo "NO OPENRC FOUND! CREATE ONE, AND TRY AGAIN!"
  exit
fi

if [[ -z "$1" ]]; then
  echo "NO SERVER NAME GIVEN! Please re-run with ./headnode_create.sh <server-name>"
  exit
fi

if [[ ! -e ${HOME}/.ssh/$SSH_PUB_KEY ]]; then
#This may be temporary... but seems fairly reasonable.
  echo "NO KEY FOUND IN ${HOME}/.ssh/$SSH_PUB_KEY! - please create one and re-run!"  
  exit
fi

server_name=$1
source ./openrc.sh

# Defining a function here to check for quotas, and exit if this script will cause problems!
# also, storing 'quotas' in a global var, so we're not calling it every single time
# quotas=$(openstack quota show)
# quota_check () 
# {
# quota_name=$1
# type_name=$2 #the name for a quota and the name for the thing itself are not the same
# number_created=$3 #number of the thing that we'll create here.
# 
# current_num=$(openstack ${type_name} list -f value | wc -l)
# 
# max_types=$(echo "${quotas}" | awk -v quota=${quota_name} '$0 ~ quota {print $4}')
# 
# #echo "checking quota for ${quota_name} of ${type_name} to create ${number_created} - want ${current_num} to be less than ${max_types}"
# 
# if [[ "${current_num}" -lt "$((max_types + number_created))" ]]; then 
  # return 0
# fi
# return 1
# }


# quota_check "secgroups" "security group" 1
# quota_check "networks" "network" 1
# quota_check "subnets" "subnet" 1
quota_check "routers" "router" 1
quota_check "key-pairs" "keypair" 1
quota_check "instances" "server" 1

RC_subnet_options="--dns-nameserver 10.84.5.252 --dns-nameserver 10.84.40.250 --dhcp --gateway auto"

# Ensure that the correct private network/router/subnet exists
## check openrc credentials work with exit code
if [[ -z "$(openstack network list | grep ${OS_USERNAME}-elastic-net)" ]]; then
  openstack network create ${OS_USERNAME}-elastic-net


##  openstack subnet create --network ${OS_USERNAME}-elastic-net --subnet-range 10.0.0.0/24 ${OS_USERNAME}-elastic-subnet1
##  echo "openstack subnet create ${RC_subnet_options} --subnet-range 10.0.0.0/24 --network ${OS_USERNAME}-elastic-net ${OS_USERNAME}-elastic-subnet1"
## Don't quote the RC_subnet_options below! Breaks the os command for some reason. 
##  openstack subnet create --dns-nameserver 10.84.5.252 --dns-nameserver 10.84.40.250 --dhcp --gateway auto --ip-version 4 --network ${OS_USERNAME}-elastic-net --subnet-range 192.168.1.0/24 ${OS_USERNAME}-elastic-subnet1

openstack subnet create ${RC_subnet_options} --subnet-range 10.0.0.0/24 --network ${OS_USERNAME}-elastic-net ${OS_USERNAME}-elastic-subnet1 
## openstack subnet create --dns-nameserver 10.84.5.252 --dns-nameserver 10.84.40.250 --dhcp --gateway auto --ip-version 4 --network ${OS_USERNAME}-elastic-net --subnet-range 10.0.0.0/24 ${OS_USERNAME}-elastic-subnet1
fi

##openstack subnet list
if [[ -z "$(openstack router list | grep ${OS_USERNAME}-elastic-router)" ]]; then
  openstack router create ${OS_USERNAME}-elastic-router
  openstack router add subnet ${OS_USERNAME}-elastic-router ${OS_USERNAME}-elastic-subnet1
  openstack router set --external-gateway public ${OS_USERNAME}-elastic-router
else
  OS_keyname=${OS_USERNAME}-elastic-key
fi
#openstack router show ${OS_USERNAME}-api-router

security_groups=$(openstack security group list -f value)
if [[ ! ("${security_groups}" =~ "${OS_USERNAME}-global-ssh") ]]; then
  openstack security group create --description "ssh \& icmp enabled" ${OS_USERNAME}-global-ssh
  openstack security group rule create --protocol tcp --dst-port 22:22 --remote-ip 0.0.0.0/0 ${OS_USERNAME}-global-ssh
  openstack security group rule create --protocol icmp ${OS_USERNAME}-global-ssh
fi
if [[ ! ("${security_groups}" =~ "${OS_USERNAME}-cluster-internal") ]]; then
  openstack security group create --description "internal group for cluster" ${OS_USERNAME}-cluster-internal
##  openstack security group rule create --protocol tcp --dst-port 1:65535 --remote-ip 10.0.0.0/0 ${OS_USERNAME}-cluster-internal
  openstack security group rule create --protocol tcp --dst-port 1:65535 --remote-ip 192.168.1.0/24 ${OS_USERNAME}-cluster-internal
  openstack security group rule create --protocol icmp ${OS_USERNAME}-cluster-internal
fi

#Check if ${HOME}/.ssh/$SSH_PUB_KEY exists in JS
if [[ -e ${HOME}/.ssh/$SSH_PUB_KEY ]]; then
  home_key_fingerprint=$(ssh-keygen -l -E md5 -f ${HOME}/.ssh/$SSH_PUB_KEY| sed  's/.*MD5:\(\S*\) .*/\1/')
fi
openstack_keys=$(openstack keypair list -f value)

home_key_in_OS=$(echo "${openstack_keys}" | awk -v mykey="${home_key_fingerprint}" '$2 ~ mykey {print $1}')

if [[ -n "${home_key_in_OS}" ]]; then
  OS_keyname=${home_key_in_OS}
elif [[ -n $(echo "${openstack_keys}" | grep ${OS_USERNAME}-elastic-key) ]]; then
  openstack keypair delete ${OS_USERNAME}-elastic-key
# This doesn't need to depend on the OS_PROJECT_NAME, as the slurm-key does, in install.sh and slurm_resume
  openstack keypair create --public-key ${HOME}/.ssh/$SSH_PUB_KEY ${OS_USERNAME}-elastic-key
  OS_keyname=${OS_USERNAME}-elastic-key
else
# This doesn't need to depend on the OS_PROJECT_NAME, as the slurm-key does, in install.sh and slurm_resume
  openstack keypair create --public-key ${HOME}/.ssh/$SSH_PUB_KEY ${OS_USERNAME}-elastic-key
  OS_keyname=${OS_USERNAME}-elastic-key
fi

#centos_base_image=$(openstack image list --status active | grep -iE "API-Featured-centos7-[[:alpha:]]{3,4}-[0-9]{2}-[0-9]{4}" | awk '{print $4}' | tail -n 1)
centos_base_image="centos-7.9"

echo -e "openstack server create\
        --user-data prevent-updates.ci \
        --flavor c1.m8 \
        --image ${centos_base_image} \
        --key-name ${OS_keyname} \
        --security-group ${OS_USERNAME}-global-ssh \
        --security-group ${OS_USERNAME}-cluster-internal \
        --nic net-id=${OS_USERNAME}-elastic-net \
        ${server_name}"

openstack server create \
        --user-data prevent-updates.ci \
        --flavor c1.m8 \
        --image ${centos_base_image} \
        --key-name ${OS_keyname} \
        --security-group ${OS_USERNAME}-global-ssh \
        --security-group ${OS_USERNAME}-cluster-internal \
        --nic net-id=${OS_USERNAME}-elastic-net \
        ${server_name}

public_ip=$(openstack floating ip create public | awk '/floating_ip_address/ {print $4}')
#For some reason there's a time issue here - adding a sleep command to allow network to become ready
## sleep 60 
openstack server add floating ip ${server_name} ${public_ip}

## hostname_test=$(ssh -q -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no centos@${public_ip} 'hostname')
hostname_test=$(ssh -q -i $SSH_KEY -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no centos@${public_ip} 'hostname')
## echo "test1: ${hostname_test}"
echo "Common server start times may be as long as 5 minutes depending on demand for usage." 

until [[ ${hostname_test} =~ "${server_name}.novalocal" ]]; do
  sleep 60
##  hostname_test=$(ssh -q -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no centos@${public_ip} 'hostname')
echo "hostname should be listed next"
    hostname_test=$(ssh -q -i $SSH_KEY -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no centos@${public_ip} 'hostname')
## Delete next line after debugging
  ssh -i $SSH_KEY -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no centos@${public_ip} 'hostname'
##  echo "ssh -q -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no centos@${public_ip} 'hostname'"
  echo "test2: ${hostname_test}"
  echo "Waiting on hostname & IP setup... "
done

echo "TESTING - hostname should have been set and listed in the test2 line "
## scp -qr -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no ${PWD} centos@${public_ip}:
scp -r -i $SSH_KEY -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no ${PWD} centos@${public_ip}:

echo "You should be able to login to your server with your ssh key pair: ${OS_keyname}, at ${public_ip}"
