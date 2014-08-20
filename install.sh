#!/bin/bash

# configuration section (cloud server)
LVM_LXC_DEV=/dev/xvde
LVM_CINDER_DEV=/dev/xvdb
MGMT_ETH=eth2
MGMT_IP=192.168.21.1
MGMT_CIDR=192.168.21.0/24
TUNNEL_ETH=eth3
TUNNEL_IP=192.168.22.1
TUNNEL_CIDR=192.168.22.0/24
EXT_ETH=eth4
EXT_IP=192.168.25.1
EXT_CIDR=192.168.25.0/24

# configuration section (vagrant)
#LVM_LXC_DEV=/dev/sdb
#LVM_CINDER_DEV=/dev/sdc
#MGMT_ETH=eth1
#MGMT_IP=10.0.0.11
#MGMT_CIDR=10.0.0.128/25
#TUNNEL_ETH=eth2
#TUNNEL_IP=10.1.0.11
#TUNNEL_CIDR=10.1.0.128/25
#EXT_ETH=eth3
#EXT_IP=10.2.0.11
#EXT_CIDR=10.2.0.128/25

# this script must run as root
set -e
if [ `id -u` -ne 0 ]; then
  echo "This script must be run as root."
    exit 1
fi
cd /root

# base dependencies
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" dist-upgrade
KERNEL=`uname -r`
apt-get -qy install linux-image-extra-$KERNEL aptitude bridge-utils lxc lvm2 build-essential git python-dev python-pip

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
# br-mgmt on $MGMT_ETH
auto $MGMT_ETH
iface $MGMT_ETH inet manual
auto br-mgmt
iface br-mgmt inet static
        address $MGMT_IP
        netmask 255.255.255.0
        bridge_ports $MGMT_ETH

# br-vmnet on $TUNNEL_ETH
auto $TUNNEL_ETH
iface $TUNNEL_ETH inet manual
auto br-vmnet
iface br-vmnet inet static
        address $TUNNEL_IP
        netmask 255.255.255.0
        bridge_ports $TUNNEL_ETH

# br-ext on $EXT_ETH
auto $EXT_ETH
iface $EXT_ETH inet manual
auto br-ext
iface br-ext inet static
        address $EXT_IP
        netmask 255.255.255.0
        bridge_ports $EXT_ETH
        dns-nameservers 8.8.8.8 8.8.4.4
EOF
ifup $MGMT_ETH
ifup $TUNNEL_ETH
ifup $EXT_ETH
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
mgmt_cidr: $MGMT_CIDR
tunnel_cidr: $TUNNEL_CIDR
storage_cidr: $TUNNEL_CIDR
global_overrides:
  internal_lb_vip_address: $MGMT_IP
  external_lb_vip_address: $EXT_IP
  tunnel_bridge: "br-vmnet"
  container_bridge: "br-mgmt"
  provider_networks:
    - network:
        group_binds:
          - neutron_linuxbridge_agent
        container_bridge: "br-vmnet"
        container_interface: "$TUNNEL_ETH"
        type: "vxlan"
        range: "1:1000"
        net_name: "vmnet"
    - network:
        group_binds:
          - neutron_linuxbridge_agent
        container_bridge: "br-ext"
        container_interface: "$EXT_ETH"
        type: "flat"
        net_name: "extnet"
    - network:
        group_binds:
          - neutron_linuxbridge_agent
        container_bridge: "br-ext"
        container_interface: "$EXT_ETH"
        type: "vlan"
        range: "1:1"
        net_name: "extnet"
  lb_name: "lb"

infra_hosts:
  infra1:
    ip: $MGMT_IP

compute_hosts:
  infra1:
    ip: $MGMT_IP

storage_hosts:
  infra1:
    ip: $MGMT_IP

log_hosts:
  infra1:
    ip: $MGMT_IP

network_hosts:
  infra1:
    ip: $MGMT_IP

haproxy_hosts:
  infra1:
    ip: $MGMT_IP
EOF
cd ansible-lxc-rpc/rpc_deployment/
sed -i "s/^required_kernel:.*\$/required_kernel: $KERNEL/" inventory/group_vars/all.yml

run_playbook()
{
    ATTEMPT=1
    RETRIES=3
    VERBOSE=""
    RETRY=""
    while ! ansible-playbook $VERBOSE -e @/etc/rpc_deploy/user_variables.yml playbooks/$1/$2.yml $RETRY ; do 
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
