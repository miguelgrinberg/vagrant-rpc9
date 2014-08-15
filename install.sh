#!/bin/bash

# configuration section (cloud server)
LVM_LXC_DEV=/dev/xvde
LVM_CINDER_DEV=/dev/xvdb
BR_MGMT_ETH=eth2
BR_MGMT_IP=192.168.21.1
BR_MGMT_CIDR=192.168.21.128/25
BR_VMNET_ETH=eth3
BR_VMNET_IP=192.168.22.2
BR_VMNET_CIDR=192.168.22.128/25
BR_EXT_ETH=eth4
BR_EXT_IP=192.168.25.1
BR_EXT_CIDR=192.168.25.128/25

# configuration section (vagrant)
#LVM_LXC_DEV=/dev/sdb
#LVM_CINDER_DEV=/dev/sdc
#BR_MGMT_ETH=eth1
#BR_MGMT_IP=10.0.0.11
#BR_MGMT_CIDR=10.0.0.128/25
#BR_VMNET_ETH=eth2
#BR_VMNET_IP=10.1.0.11
#BR_VMNET_CIDR=10.1.0.128/25
#BR_EXT_ETH=eth3
#BR_EXT_IP=10.2.0.11
#BR_EXT_CIDR=10.2.0.128/25

# this script must run as root
set -e
if [ `id -u` -ne 0 ]; then
  echo "This script must be run as root."
    exit 1
fi
cd /root

# base dependencies
apt-get update
apt-get dist-upgrade -y
apt-get install -q -y linux-image-extra-`uname -r` aptitude bridge-utils lxc lvm2 build-essential git python-dev python-pip

# lvm
parted -s $LVM_LXC_DEV mktable gpt
parted -s $LVM_CINDER_DEV mktable gpt
parted -s $LVM_LXC_DEV mkpart lvm 0% 100%
parted -s $LVM_CINDER_DEV mkpart lvm 0% 100%
pvcreate -ff -y ${LVM_LXC_DEV}1
pvcreate -ff -y ${LVM_CINDER_DEV}1
vgcreate lxc ${LVM_LXC_DEV}1
vgcreate cinder-volumes ${LVM_CINDER_DEV}1

# networking
echo net.ipv4.ip_forward=1 >> /etc/sysctl.conf
sysctl -w net.ipv4.ip_forward=1

cat << EOF >> /etc/network/interfaces
# br-mgmt on $BR_MGMT_ETH
auto $BR_MGMT_ETH
iface $BR_MGMT_ETH inet manual
auto br-mgmt
iface br-mgmt inet static
        address $BR_MGMT_IP
        netmask 255.255.255.0
        bridge_ports $BR_MGMT_ETH

# br-vmnet on $BR_VMNET_ETH
auto $BR_VMNET_ETH
iface $BR_VMNET_ETH inet manual
auto br-vmnet
iface br-vmnet inet static
        address $BR_VMNET_IP
        netmask 255.255.255.0
        bridge_ports $BR_VMNET_ETH

# br-ext on $BR_EXT_ETH
auto $BR_EXT_ETH
iface $BR_EXT_ETH inet manual
auto br-ext
iface br-ext inet static
        address $BR_EXT_IP
        netmask 255.255.255.0
        bridge_ports $BR_EXT_ETH
        dns-nameservers 8.8.8.8 8.8.4.4
EOF
ifup $BR_MGMT_ETH
ifup $BR_VMNET_ETH
ifup $BR_EXT_ETH
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
mgmt_cidr: $BR_MGMT_CIDR
vmnet_cidr: $BR_VMNET_CIDR

global_overrides:
  internal_lb_vip_address: $BR_MGMT_IP
  external_lb_vip_address: $BR_EXT_IP
  tunnel_bridge: "br-vmnet"
  container_bridge: "br-mgmt"
  neutron_provider_networks:
    - network:
        container_bridge: "br-vmnet"
        container_interface: "eth3"
        type: "vxlan"
        range: "1:1000"
        net_name: "vmnet"
    - network:
        container_bridge: "br-ext"
        container_interface: "eth4"
        type: "flat"
        net_name: "extnet"
    - network:
        container_bridge: "br-ext"
        container_interface: "eth4"
        type: "vlan"
        range: "1:1000"
        net_name: "extnet"

infra_hosts:
  infra1:
    ip: $BR_MGMT_IP

compute_hosts:
  infra1:
    ip: $BR_MGMT_IP

storage_hosts:
  infra1:
    ip: $BR_MGMT_IP

log_hosts:
  infra1:
    ip: $BR_MGMT_IP

network_hosts:
  infra1:
    ip: $BR_MGMT_IP

haproxy_hosts:
  infra1:
    ip: $BR_MGMT_IP
EOF
cd ansible-lxc-rpc/rpc_deployment/
#find . -name "*.yml" -exec sed -i "s/container_lvm_fssize: 5G/container_lvm_fssize: 2G/g" '{}' \;

run_playbook()
{
    ATTEMPT=1
    RETRIES=3
    VERBOSE=""
    RETRY=""
    while ! ansible-playbook $VERBOSE -e @vars/user_variables.yml playbooks/$1/$2.yml $RETRY ; do 
        if [ $ATTEMPT -ge $RETRIES ]; then
            exit 1
        fi
        ATTEMPT=$((ATTEMPT+1))
        sleep 10
        VERBOSE=-vvv
        RETRY="--limit @/root/$2.retry"
    done
}

run_playbook setup setup-common
run_playbook setup build-containers
run_playbook setup restart-containers
run_playbook setup host-common

run_playbook infrastructure memcached-install
run_playbook infrastructure galera-install
run_playbook infrastructure rabbit-install
run_playbook infrastructure rsyslog-install
run_playbook infrastructure elasticsearch-install
run_playbook infrastructure logstash-install
run_playbook infrastructure kibana-install
run_playbook infrastructure es2unix-install
run_playbook infrastructure rsyslog-config
run_playbook infrastructure haproxy-install

run_playbook openstack openstack-common
run_playbook openstack keystone
run_playbook openstack keystone-add-all-services
run_playbook openstack keystone-add-users
run_playbook openstack glance-all
run_playbook openstack heat-all
run_playbook openstack nova-all
run_playbook openstack neutron-all
run_playbook openstack cinder-all
run_playbook openstack horizon
run_playbook openstack utility
