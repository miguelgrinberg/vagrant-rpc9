#!/bin/bash
cd ~/

# base dependencies
apt-get update && apt-get dist-upgrade -y
apt-get purge -y nano
apt-get install -y aptitude bridge-utils build-essential git python-dev python-pip ssh sudo vim lsof tcpdump

# lvm
apt-get install -y lvm2
parted -s /dev/sdb mktable gpt
parted -s /dev/sdc mktable gpt
parted -s /dev/sdb mkpart lvm 0% 100%
parted -s /dev/sdc mkpart lvm 0% 100%
pvcreate /dev/sdb1
pvcreate /dev/sdc1
vgcreate lxc /dev/sdb1
vgcreate cinder-volumes /dev/sdc1

# LXC
add-apt-repository -y ppa:ubuntu-lxc/stable
apt-get update
apt-get install -y lxc python3-lxc lxc-templates liblxc1

git clone https://github.com/cloudnull/lxc_defiant
cp lxc_defiant/lxc-defiant.py /usr/share/lxc/templates/lxc-defiant
chmod +x /usr/share/lxc/templates/lxc-defiant
cp lxc_defiant/defiant.common.conf /usr/share/lxc/config/defiant.common.conf

echo net.ipv4.ip_forward=1 >> /etc/sysctl.conf
sysctl -w net.ipv4.ip_forward=1

cat > /etc/lxc/lxc-defiant.conf <<EOF
lxc.start.auto = 1
lxc.group = onboot

# Configures the default LXC network
lxc.network.type=veth
lxc.network.name=eth0
lxc.network.link=lxcbr0
lxc.network.flags=up

# Creates a veth pair within the container
lxc.network.type = veth
lxc.network.link = br-mgmt
lxc.network.name = eth1
lxc.network.flags = up
EOF

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

# ssh keys
ssh-keygen -f ~/.ssh/id_rsa -N ""
cat ~/.ssh/id_rsa.pub >> /root/.ssh/authorized_keys
chown vagrant:vagrant ~/.ssh/id_rsa*
cp ~/.ssh/id_rsa* /root/.ssh/
service ssh restart

# ansible playbooks setup
git clone https://github.com/rcbops/ansible-lxc-rpc.git
pip install -r ansible-lxc-rpc/requirements.txt
cp -R ansible-lxc-rpc/etc/rpc_deploy/ /etc/rpc_deploy
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
cd ansible-lxc-rpc/rpc_deployment/
find . -name "*.yml" -exec sed -i "s/container_lvm_fssize: 5G/container_lvm_fssize: 2G/g" '{}' \;
sed -i "s/lb_vip_address: 127.0.0.1/lb_vip_address: 10.1.0.11/" vars/user_variables.yml

# setup playbooks
ansible-playbook -e @vars/user_variables.yml playbooks/setup/all-the-setup-things.yml

# infrastructure playbooks
ansible-playbook -e @vars/user_variables.yml playbooks/infrastructure/all-the-infrastructure-things.yml

# openstack playbooks
ansible-playbook -e @vars/user_variables.yml playbooks/openstack/all-the-openstack-things.yml
