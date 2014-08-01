#!/bin/bash

set -e
set -o pipefail
set -x

RETRIES=3


run_playbook()
{
	cd /opt/ansible-lxc-rpc/rpc_deployment
	ATTEMPT=1
	VERBOSE=""
	set +e
	while ! ansible-playbook $VERBOSE -e @vars/user_variables.yml $1 ; do 
		if [ $ATTEMPT -ge $RETRIES ]; then
			exit 1
		fi
		ATTEMPT=$((ATTEMPT+1))
		sleep 90
		VERBOSE=-vvv
	done
	set -e
}

run_playbook playbooks/setup/host-setup.yml
run_playbook playbooks/setup/build-containers.yml
run_playbook playbooks/setup/restart-containers.yml
run_playbook playbooks/setup/it-puts-common-bits-on-disk.yml



GALERA_CONTAINER=`lxc-ls | grep galera`
if [ -f "/openstack/$GALERA_CONTAINER/galera.cache" ]; then 
	run_playbook playbooks/infrastructure/galera-config.yml
	run_playbook playbooks/infrastructure/galera-startup.yml
else
	run_playbook playbooks/infrastructure/galera-install.yml
fi


run_playbook playbooks/infrastructure/memcached.yml
run_playbook playbooks/infrastructure/rabbit-install.yml
run_playbook playbooks/infrastructure/rsyslog-install.yml
run_playbook playbooks/infrastructure/elasticsearch-install.yml
run_playbook playbooks/infrastructure/logstash-install.yml
run_playbook playbooks/infrastructure/kibana-install.yml
run_playbook playbooks/infrastructure/rsyslog-config.yml
run_playbook playbooks/infrastructure/es2unix-install.yml
run_playbook playbooks/infrastructure/haproxy-install.yml

run_playbook playbooks/openstack/utility.yml
run_playbook playbooks/openstack/it-puts-openstack-bits-on-disk.yml
run_playbook playbooks/openstack/keystone.yml
run_playbook playbooks/openstack/keystone-add-all-services.yml
run_playbook playbooks/openstack/keystone-add-users.yml
run_playbook playbooks/openstack/glance-all.yml
run_playbook playbooks/openstack/heat-all.yml
run_playbook playbooks/openstack/nova-all.yml
run_playbook playbooks/openstack/neutron-all.yml
run_playbook playbooks/openstack/cinder-all.yml
run_playbook playbooks/openstack/horizon.yml

echo "All DONE!"