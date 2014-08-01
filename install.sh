#!/bin/bash

if [ `id -u` -ne 0 ]; then
  echo "This script must be run as root."
  exit 1
fi

set -e
set -o pipefail
set -x

GIT_URL=https://github.com/rcbops/ansible-lxc-rpc.git
GIT_BRANCH=development


export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -q -y update-notifier-common
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

# Don't think any of this is necessary
# LXC
# add-apt-repository -y ppa:ubuntu-lxc/stable
# apt-get update
# apt-get install -y lxc python3-lxc lxc-templates liblxc1

# git clone https://github.com/cloudnull/lxc_defiant
# cp lxc_defiant/lxc-defiant.py /usr/share/lxc/templates/lxc-defiant
# chmod +x /usr/share/lxc/templates/lxc-defiant
# cp lxc_defiant/defiant.common.conf /usr/share/lxc/config/defiant.common.conf

echo net.ipv4.ip_forward=1 >> /etc/sysctl.conf
sysctl -w net.ipv4.ip_forward=1

# cat > /etc/lxc/lxc-defiant.conf <<EOF
# lxc.start.auto = 1
# lxc.group = onboot

# # Configures the default LXC network
# lxc.network.type=veth
# lxc.network.name=eth0
# lxc.network.link=lxcbr0
# lxc.network.flags=up

# # Creates a veth pair within the container
# lxc.network.type = veth
# lxc.network.link = br-mgmt
# lxc.network.name = eth1
# lxc.network.flags = up
# EOF

# networking
brctl addbr br-mgmt
cat << EOF > /etc/network/interfaces.d/eth2.cfg
auto eth2
iface eth2 inet manual
auto br-mgmt
iface br-mgmt inet static
        address 10.1.0.11
        netmask 255.255.255.0
        bridge_ports eth2
        bridge_stp off
        bridge_fd 0
        bridge_maxwait 0
        dns-nameservers 8.8.8.8 8.8.4.4
EOF
ifdown eth2
ifup eth2
ifdown br-mgmt
ifup br-mgmt



rm -rf /opt/ansible-lxc-rpc
mkdir -p /opt
git clone $GIT_URL -b $GIT_BRANCH /opt/ansible-lxc-rpc

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
cidr: 10.1.0.0/24

infra_hosts:
  infra1:
    ip: 10.1.0.11

compute_hosts:
  infra1:
    ip: 10.1.0.11

storage_hosts:
  infra1:
    ip: 10.1.0.11

log_hosts:
  infra1:
    ip: 10.1.0.11

network_hosts:
  infra1:
    ip: 10.1.0.11

haproxy_hosts:
  infra1:
    ip: 10.1.0.11
EOF

cd /opt/ansible-lxc-rpc/rpc_deployment/
find . -name "*.yml" -exec sed -i "s/container_lvm_fssize: 5G/container_lvm_fssize: 2G/g" '{}' \;
sed -i "s/^lb_vip_address:.*/lb_vip_address: 10.1.0.11/" /opt/ansible-lxc-rpc/rpc_deployment/vars/user_variables.yml


/bin/bash /vagrant/install_openstack.bash
