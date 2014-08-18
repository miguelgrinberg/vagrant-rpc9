#!/bin/bash

if [ `id -u` -ne 1000 ]; then
  echo "This script must be run as root."
  exit 1
fi

set -e
set -o pipefail
set -x

export GIT_URL=git@github.com:rcbops/ansible-lxc-rpc.git
export GIT_BRANCH=master
export DEBIAN_FRONTEND=noninteractive


# APT PACKAGES
sudo apt-get update
sudo apt-get install -q -y update-notifier-common
sudo apt-get install -q -y git lvm2 parted bridge-utils git aptitude python-dev emacs24-nox vim tmux python-setuptools linux-image-extra-virtual
# linux-image-extra is equired for vhost_net kernel module
sudo apt-get dist-upgrade -q -y
sudo apt-get autoremove -y

# Reboot if necessary
test -e /var/run/reboot-required && sudo shutdown -h now || true

# Get modern pip
sudo easy_install pip

# GIT CLONE
ssh -o StrictHostKeyChecking=no git@github.com || true
sudo rm -rf /opt/ansible-lxc-rpc
sudo mkdir -p /opt
sudo chown vagrant:vagrant /opt
git clone $GIT_URL -b $GIT_BRANCH /opt/ansible-lxc-rpc


# Install ansible
sudo pip install ansible==1.6.6


# Configure Disks
sudo parted -s /dev/sdb mktable gpt
sudo parted -s /dev/sdc mktable gpt
sudo parted -s /dev/sdb mkpart lvm 0% 100%
sudo parted -s /dev/sdc mkpart lvm 0% 100%
sudo pvcreate /dev/sdb1
sudo pvcreate /dev/sdc1
sudo vgcreate lxc /dev/sdb1
sudo vgcreate cinder-volumes /dev/sdc1


# networking
echo net.ipv4.ip_forward=1 >> sudo tee /etc/sysctl.conf
sudo sysctl -w net.ipv4.ip_forward=1



cat << EOF | sudo tee /etc/network/interfaces.d/eth1.cfg
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
sudo brctl addbr br-ext


cat << EOF | sudo tee /etc/network/interfaces.d/eth2.cfg
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
sudo brctl addbr br-mgmt


cat << EOF | sudo tee /etc/network/interfaces.d/eth3.cfg
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
sudo brctl addbr br-vmnet



sleep 5
sudo ifdown eth1
sudo ifdown eth2
sudo ifdown eth3
sleep 5
sudo ifup eth1
sudo ifup eth2
sudo ifup eth3
sleep 5
sudo ifdown br-mgmt
sudo ifdown br-ext
sudo ifdown br-vmnet
sleep 5
sudo ifup br-mgmt
sudo ifup br-vmnet
sudo ifup br-ext

sudo pip install --upgrade -r /opt/ansible-lxc-rpc/requirements.txt

sudo cp -R /opt/ansible-lxc-rpc/etc/rpc_deploy /etc/rpc_deploy

sudo rm -f /root/.ssh/id_rsa
sudo rm -rf /root/.ssh/id_rsa.pub
sudo ssh-keygen -t rsa -f /root/.ssh/id_rsa -N ''
sudo cat /root/.ssh/id_rsa.pub | sudo tee /root/.ssh/authorized_keys


cat << EOF | sudo tee /etc/rpc_deploy/rpc_user_config.yml
---
# User defined CIDR used for containers
mgmt_cidr: 10.51.50.0/24

vmnet_cidr: 192.168.20.0/24

used_ips:
  - 10.51.50.1
  - 192.168.20.1

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


sudo /usr/bin/python /opt/ansible-lxc-rpc/tools/install.py --haproxy --galera --rabbit

