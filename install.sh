#!/bin/bash

if [ `id -u` -ne 0 ]; then
  echo "This script must be run as root."
  exit 1
fi

set -e
set -o pipefail
set -x

GIT_URL=https://github.com/johnmarkschofield/ansible-lxc-rpc.git
GIT_BRANCH=non-blocking-io-for-subprocess


export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -q -y update-notifier-common

# Do this early because there's an authentication prompt.
apt-get install -q -y git
rm -rf /opt/ansible-lxc-rpc
mkdir -p /opt
git clone $GIT_URL -b $GIT_BRANCH /opt/ansible-lxc-rpc


apt-get autoremove -y
apt-get dist-upgrade -q -y
test -e /var/run/reboot-required && shutdown -h now || true

# Disk stuff
apt-get -q -y install lvm2 parted

# Network stuff
apt-get -q -y install bridge-utils

# Build Requirements
apt-get -q -y install git aptitude python-dev

# Not-crappy editors + tools
apt-get -q -y install emacs24-nox vim tmux

# Get modern pip
apt-get -q -y install python-setuptools
easy_install pip


# Required for vhost_net kernel module
apt-get -q -y install linux-image-extra-`uname -r`

# Shutdown if necessary
test -f /var/run/reboot-required && shutdown -h now || true

# Install ansible
pip install ansible==1.6.6


# Configure Disks
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



cat << EOF > /etc/network/interfaces.d/eth1.cfg
auto eth1
iface eth1 inet manual
auto br-ext
iface br-ext inet static
        address 10.10.10.10
        netmask 255.255.255.0
        bridge_ports eth1
        bridge_stp off
        bridge_fd 0
        bridge_maxwait 0
        dns-nameservers 8.8.8.8 8.8.4.4
EOF
brctl addbr br-ext


cat << EOF > /etc/network/interfaces.d/eth2.cfg
auto eth2
iface eth2 inet manual
auto br-mgmt
iface br-mgmt inet static
        address 10.51.50.10
        netmask 255.255.255.0
        bridge_ports eth2
        bridge_stp off
        bridge_fd 0
        bridge_maxwait 0
        dns-nameservers 8.8.8.8 8.8.4.4
EOF
brctl addbr br-mgmt


cat << EOF > /etc/network/interfaces.d/eth3.cfg
auto eth3
iface eth3 inet manual
auto br-mgmt
iface br-mgmt inet static
        address 10.51.50.10
        netmask 255.255.255.0
        bridge_ports eth2
        bridge_stp off
        bridge_fd 0
        bridge_maxwait 0
        dns-nameservers 8.8.8.8 8.8.4.4
EOF
brctl addbr br-vmnet



sleep 5
ifdown eth1
ifdown eth2
ifdown eth3
sleep 5
ifup eth1
ifup eth2
ifup eth3
sleep 5
ifdown br-mgmt
ifdown br-ext
ifdown br-vmnet
sleep 5
ifup br-mgmt
ifup br-vmnet
ifup br-ext

pip install --upgrade -r /opt/ansible-lxc-rpc/requirements.txt

cp -R /opt/ansible-lxc-rpc/etc/rpc_deploy /etc/rpc_deploy

rm -f /root/.ssh/id_rsa
rm -rf /root/.ssh/id_rsa.pub
ssh-keygen -t rsa -f /root/.ssh/id_rsa -N ''
cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys

# Not necessary because d34dh0r53 made these parameters auto-configuring
# sed -i 's/^elasticsearch_heap:.*/elasticsearch_heap: 1g/g' /opt/ansible-lxc-rpc/rpc_deployment/inventory/group_vars/elasticsearch.yml
# sed -i 's/^logstash_heap:.*/logstash_heap: 1g/g' /opt/ansible-lxc-rpc/rpc_deployment/inventory/group_vars/logstash.yml


cat <<EOF >/etc/rpc_deploy/rpc_user_config.yml
---
# User defined CIDR used for containers
mgmt_cidr: 10.51.50.0/24

vmnet_cidr: 192.168.20.0/24

global_overrides:
  internal_lb_vip_address: 10.51.50.10
  external_lb_vip_address: 10.51.50.10

infra_hosts:
  infra1:
    ip: 10.51.50.10

compute_hosts:
  infra1:
    ip: 10.51.50.10

storage_hosts:
  infra1:
    ip: 10.51.50.10

log_hosts:
  infra1:
    ip: 10.51.50.10

network_hosts:
  infra1:
    ip: 10.51.50.10

haproxy_hosts:
  infra1:
    ip: 10.51.50.10
EOF

cd /opt/ansible-lxc-rpc/rpc_deployment/
find . -name "*.yml" -exec sed -i "s/container_lvm_fssize: 5G/container_lvm_fssize: 2G/g" '{}' \;
sed -i "s/^lb_vip_address:.*/lb_vip_address: 10.51.50.10/" /opt/ansible-lxc-rpc/rpc_deployment/vars/user_variables.yml


/usr/bin/python /opt/ansible-lxc-rpc/tools/install.py --haproxy --galera --rabbit

