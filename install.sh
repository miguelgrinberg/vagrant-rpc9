#!/bin/bash
set -e
if [ `id -u` -ne 0 ]; then
  echo "This script must be run as root."
    exit 1
fi
cd /root

# base dependencies
apt-get update
apt-get dist-upgrade -y
apt-get install -y aptitude bridge-utils lxc lvm2 build-essential git python-dev python-pip
apt-get install -y --reinstall linux-image-3.13.0

# lvm
parted -s /dev/sdb mktable gpt
parted -s /dev/sdc mktable gpt
parted -s /dev/sdb mkpart lvm 0% 100%
parted -s /dev/sdc mkpart lvm 0% 100%
pvcreate /dev/sdb1
pvcreate /dev/sdc1
vgcreate lxc /dev/sdb1
vgcreate cinder-volumes /dev/sdc1

# networking
echo net.ipv4.ip_forward=1 >> /etc/sysctl.conf
sysctl -w net.ipv4.ip_forward=1

cat << EOF >> /etc/network/interfaces
# br-mgmt on eth1
auto eth1
iface eth1 inet manual
auto br-mgmt
iface br-mgmt inet static
        address 10.0.0.11
        netmask 255.255.255.0
        bridge_ports eth1

# br-vmnet on eth2
auto eth2
iface eth2 inet manual
auto br-vmnet
iface br-vmnet inet static
        address 10.1.0.11
        netmask 255.255.255.0
        bridge_ports eth2

# br-ext on eth3
auto eth3
iface eth3 inet manual
auto br-ext
iface br-ext inet static
        address 10.3.0.11
        netmask 255.255.255.0
        bridge_ports eth3
        dns-nameservers 8.8.8.8 8.8.4.4
EOF
ifup eth1
ifup eth2
ifup eth3
brctl addbr br-mgmt
brctl addbr br-vmnet
brctl addbr br-ext

# ssh keys
ssh-keygen -f /root/.ssh/id_rsa -N ""
cat /root/.ssh/id_rsa.pub >> /root/.ssh/authorized_keys

# ansible playbooks setup
git clone https://github.com/rcbops/ansible-lxc-rpc.git
pip install -r ansible-lxc-rpc/requirements.txt
cp -R ansible-lxc-rpc/etc/rpc_deploy/ /etc/rpc_deploy
cat <<EOF >/etc/rpc_deploy/rpc_user_config.yml
---
mgmt_cidr: 10.0.0.0/24
vmnet_cidr: 10.1.0.0/24

global_overrides:
  internal_lb_vip_address: 10.0.0.11
  external_lb_vip_address: 10.2.0.11

infra_hosts:
  infra1:
    ip: 10.0.0.11

compute_hosts:
  infra1:
    ip: 10.0.0.11

storage_hosts:
  infra1:
    ip: 10.0.0.11

log_hosts:
  infra1:
    ip: 10.0.0.11

network_hosts:
  infra1:
    ip: 10.0.0.11

haproxy_hosts:
  infra1:
    ip: 10.0.0.11
EOF
cd ansible-lxc-rpc/rpc_deployment/
find . -name "*.yml" -exec sed -i "s/container_lvm_fssize: 5G/container_lvm_fssize: 2G/g" '{}' \;

run_playbook()
{
    ATTEMPT=1
    VERBOSE=""
    RETRY=""
    while ! ansible-playbook $VERBOSE -e @vars/user_variables.yml playbooks/$1/$2.yml $RETRY; do 
        if [ $ATTEMPT -ge $RETRIES ]; then
            exit 1
        fi
        ATTEMPT=$((ATTEMPT+1))
        sleep 10
        VERBOSE=-vvv
        RETRY="--limit @/root/$2.retry"
    done
}

run_playbook setup host-setup
run_playbook setup build-containers
run_playbook setup restart-containers
run_playbook setup it-puts-common-bits-on-disk

run_playbook infrastructure galera-install
run_playbook infrastructure memcached-install
run_playbook infrastructure rabbit-install
run_playbook infrastructure rsyslog-install
run_playbook infrastructure elasticsearch-install
run_playbook infrastructure logstash-install
run_playbook infrastructure kibana-install
run_playbook infrastructure rsyslog-config
run_playbook infrastructure es2unix-install
run_playbook infrastructure haproxy-install

run_playbook openstack utility
run_playbook openstack it-puts-openstack-bits-on-disk
run_playbook openstack keystone
run_playbook openstack keystone-add-all-services
run_playbook openstack keystone-add-users
run_playbook openstack glance-all
run_playbook openstack heat-all
run_playbook openstack nova-all
run_playbook openstack neutron-all
run_playbook openstack cinder-all
run_playbook openstack horizon
