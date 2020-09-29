#!/bin/bash

source /etc/slurm/openrc.sh

node_size="m1.small"
node_image=$(openstack image list -f value | grep -i ${OS_USERNAME}-compute-image- | cut -f 2 -d' '| tail -n 1)
key_name="${OS_USERNAME}-${OS_PROJECT_NAME}-slurm-key"
network_name=${OS_USERNAME}-elastic-net
log_loc=/var/log/slurm/slurm_elastic.log

#def f'n to generate a write_files entry for cloud-config for copying over a file
# arguments are owner path permissions file_to_be_copied
# All calls to this must come after an "echo "write_files:\n"
generate_write_files () {
#This is generating YAML, so... spaces are important.
echo -e "  - encoding: b64\n    owner: $1\n    path: $2\n    permissions: $3\n    content: |\n$(cat $4 | base64 | sed 's/^/      /')"
}

user_data_long="$(cat /etc/slurm/prevent-updates.ci)\n"
user_data_long+="$(echo -e "hostname: $host \npreserve_hostname: true\ndebug: \nmanage_etc_hosts: false\n")\n"
user_data_long+="$(echo -e "write_files:")\n"
user_data_long+="$(generate_write_files slurm "/etc/slurm/slurm.conf" "0644" "/etc/slurm/slurm.conf")\n"
user_data_long+="$(generate_write_files root "/etc/hosts" "0664" "/etc/hosts")\n"
user_data_long+="$(generate_write_files root "/etc/passwd" "0644" "/etc/passwd")\n"
#Done generating the cloud-config for compute nodes

echo "Node resume invoked: $0 $*" >> $log_loc

#First, loop over hosts and run the openstack create commands for *all* resume hosts at once.
for host in $(scontrol show hostname $1)
do

#Launch compute nodes and check for new ip address in same subprocess - with 2s delay between Openstack requests
    #--user-data <(cat /etc/slurm/prevent-updates.ci && echo -e "hostname: $host \npreserve_hostname: true\ndebug:") \
    # the current --user-data pulls in the slurm.conf and /etc/passwd as well, to avoid rebuilding node images
    # when adding / changing partitions

    (echo "creating $host" >> $log_loc;
    openstack server create $host \
    --flavor $node_size \
    --image $node_image \
    --key-name $key_name \
    --user-data <(echo -e "${user_data_long}") \
    --security-group ${OS_USERNAME}-global-ssh --security-group ${OS_USERNAME}-cluster-internal \
    --nic net-id=$network_name 2>&1 \
    | tee -a $log_loc | awk '/status/ {print $4}' >> $log_loc 2>&1;

  node_status="UNKOWN";
	stat_count=0
	declare -i stat_count;
  until [[ $node_status == "ACTIVE" || $stat_count -ge 20 ]]; do
    node_state=$(openstack server show $host 2>&1);
    node_status=$(echo -e "${node_state}" | awk '/status/ {print $4}');
#    echo "$host status is: $node_status" >> $log_loc;
#    echo "$host ip is: $node_ip" >> $log_loc;
    stat_count+=1
    sleep 3;
  done;
	if [[ $node_status != "ACTIVE" ]]; then
		 echo "$host creation failed" >> $log_loc;
		 exit 1;
  fi;
  node_ip=$(echo -e "${node_state}" | awk '/addresses/ {print gensub(/^.*=/,"","g",$4)}');

  echo "$host ip is $node_ip" >> $log_loc;
  scontrol update nodename=$host nodeaddr=$node_ip >> $log_loc;)&
  sleep 2 # don't send all the JS requests at "once"
done
