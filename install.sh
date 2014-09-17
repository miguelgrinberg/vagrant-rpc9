#!/bin/bash

# All-In-One RPC9 installer script
# Example for cloud server:
# $ ./install.sh -m eth2,192.168.21.1,192.168.21.0/24 -t eth3,192.168.22.2,192.168.22.0/24 -e eth4,192.168.25.1,192.168.25.0/24 --lxc xvde --cinder xvdb all
#
# Example for vagrant:
# ./install.sh -m eth1,10.0.0.11,10.0.0.0/24 -t eth2,10.1.0.11,10.1.0.0/24 -e eth3,10.2.0.11,10.2.0.0/24 --lxc xvde --cinder xvdb all

check_root()
{
    set -e
    if [ `id -u` -ne 0 ]; then
        echo "This script must be run as root."
        exit 1
    fi
    cd /root
}

do_base()
{
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" dist-upgrade
    KERNEL=`uname -r`
    apt-get -qy install linux-image-extra-$KERNEL aptitude bridge-utils lxc lvm2 build-essential git python-dev python-pip
}

do_lvm()
{
    if [[ $LVM_LXC_DEV != "" ]]; then
        parted -s /dev/$LVM_LXC_DEV mktable gpt
        parted -s /dev/$LVM_LXC_DEV mkpart lvm 0% 100%
        pvcreate -ff -y /dev/${LVM_LXC_DEV}1
        vgcreate lxc /dev/${LVM_LXC_DEV}1
    fi
    if [[ $LVM_CINDER_DEV != "" ]]; then
        parted -s /dev/$LVM_CINDER_DEV mktable gpt
        parted -s /dev/$LVM_CINDER_DEV mkpart lvm 0% 100%
        pvcreate -ff -y /dev/${LVM_CINDER_DEV}1
        vgcreate cinder-volumes /dev/${LVM_CINDER_DEV}1
    fi
}

do_net()
{
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
}

do_ssh()
{
    ssh-keygen -f /root/.ssh/id_rsa -N ""
    cat /root/.ssh/id_rsa.pub >> /root/.ssh/authorized_keys
}

do_ansible()
{
    git clone https://github.com/rcbops/ansible-lxc-rpc.git
    pip install -r ansible-lxc-rpc/requirements.txt
    cp -R ansible-lxc-rpc/etc/rpc_deploy/ /etc/rpc_deploy
    ansible-lxc-rpc/scripts/pw-token-gen.py --file /etc/rpc_deploy/user_variables.yml
    cat <<EOF >/etc/rpc_deploy/rpc_user_config.yml
---
environment_version: e0955a92a761d5845520a82dcca596af

cidr_networks:
  container: $MGMT_CIDR
  snet: $MGMT_CIDR
  tunnel: $TUNNEL_CIDR
  storage: $TUNNEL_CIDR

global_overrides:
  internal_lb_vip_address: $MGMT_IP
  external_lb_vip_address: $EXT_IP
  tunnel_bridge: "br-vmnet"
  management_bridge: "br-mgmt"
  provider_networks:
    - network:
        group_binds:
          - all_containers
          - hosts
        type: "raw"
        container_bridge: "br-mgmt"
        container_interface: "eth1"
        ip_from_q: "container"
    - network:
        group_binds:
          - neutron_linuxbridge_agent
        container_bridge: "br-vmnet"
        container_interface: "eth10"
        type: "vxlan"
        range: "1:1000"
        net_name: "vxlan"
        ip_from_q: "tunnel"
    - network:
        group_binds:
          - neutron_linuxbridge_agent
        container_bridge: "br-ext"
        container_interface: "eth11"
        type: "flat"
        net_name: "extnet"
    - network:
        group_binds:
          - neutron_linuxbridge_agent
        container_bridge: "br-ext"
        container_interface: "eth11"
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
}

run_playbook()
{
    ATTEMPT=1
    RETRIES=3
    VERBOSE=""
    RETRY=""
    cd ~/ansible-lxc-rpc/rpc_deployment
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

do_playbooks()
{
    run_playbook setup setup-common
    run_playbook setup build-containers
    run_playbook setup restart-containers
    run_playbook setup containers-common

    run_playbook infrastructure memcached-install
    if [[ $SKIP_GALERA == "" ]]; then
        run_playbook infrastructure galera-install
    fi
    run_playbook infrastructure rabbit-install
    if [[ $SKIP_LOGGING == "" ]]; then
        run_playbook infrastructure rsyslog-install
        run_playbook infrastructure elasticsearch-install
        run_playbook infrastructure logstash-install
        run_playbook infrastructure kibana-install
        run_playbook infrastructure es2unix-install
        run_playbook infrastructure rsyslog-config
    fi
    if [[ $SKIP_HAPROXY == "" ]]; then
        run_playbook infrastructure haproxy-install
    fi

    run_playbook openstack openstack-common
    run_playbook openstack keystone
    run_playbook openstack keystone-add-all-services
    run_playbook openstack keystone-add-users
    run_playbook openstack glance-all
    run_playbook openstack heat-all
    run_playbook openstack nova-all
    run_playbook openstack neutron-all
    run_playbook openstack cinder-all
    run_playbook openstack horizon-all
    run_playbook openstack utility
    run_playbook infrastructure rsyslog-config
}

usage()
{
    echo "Usage: install.sh [options] module ..."
    echo "Options:"
    echo "  --mgmt(-m):   management network interface, IP address and CIDR (e.g. eth3,192.168.22.1,192.168.22.0/24)"
    echo "  --tunnel(-t)  VM tunneling network interface, IP address and CIDR"
    echo "  --ext(-e)     external network interface, IP address and CIDR"
    echo "  --lxc(-l)     LVM device for LXC containers (e.g. xvde, do not define to disable LVM for containers)"
    echo "  --cinder(-c)  LVM device for cinder storage (e.g. xvdb)"
    echo "  --no-galera   Skip the galera playbook (needed for repeat installs)"
    echo "  --no-log      Skip the logging playbooks (useful for resource constrained hosts)"
    echo "  --no-haproxy  Skip the haproxy playbook"
    echo "Modules:"
    echo "  base       Install base packages"
    echo "  lvm        Configure LVM volumes"
    echo "  net        Configure networking"
    echo "  ssh        Install a SSH private key"
    echo "  ansible    Checkout and configure the ansible repository"
    echo "  playbooks  Run the ansible playbooks"
    echo "  all        Do all of the above"
    exit 1
}

while true; do
    if [[ ${1:0:1} != "-" ]]; then
        break
    fi
    case $1 in
        --help|-h)
            usage
            ;;
        --mgmt|-m)
            MGMT_ETH=$(echo $2 | cut -f1 -d,)
            MGMT_IP=$(echo $2 | cut -f2 -d,)
            MGMT_CIDR=$(echo $2 | cut -f3 -d,)
            shift
            ;;
        --tunnel|-t)
            TUNNEL_ETH=$(echo $2 | cut -f1 -d,)
            TUNNEL_IP=$(echo $2 | cut -f2 -d,)
            TUNNEL_CIDR=$(echo $2 | cut -f3 -d,)
            shift
            ;;
        --ext|-e)
            EXT_ETH=$(echo $2 | cut -f1 -d,)
            EXT_IP=$(echo $2 | cut -f2 -d,)
            EXT_CIDR=$(echo $2 | cut -f3 -d,)
            shift
            ;;
        --lxc|-l)
            LVM_LXC_DEV=$2
            shift
            ;;
        --cinder|-c)
            LVM_CINDER_DEV=$2
            shift
            ;;
        --no-galera)
            SKIP_GALERA=1
            ;;
        --no-log)
            SKIP_LOGGING=1
            ;;
        --no-haproxy)
            SKIP_HAPROXY=1
            ;;
        *)
            echo "Invalid option: $1" >&2
            usage
            ;;
    esac
    shift
done
MODULES=$1
if [[ $MODULES == "" ]] || [[ $MODULES == "all" ]]; then
    MODULES="base lvm net ssh ansible playbooks"
fi

if [[ $MGMT_ETH == "" ]] || [[ $MGMT_ETH == "" ]] || [[ $MGMT_CIDR == "" ]]; then
    echo "Error: management network is not configured" >&2
    exit 1
fi
if [[ $TUNNEL_ETH == "" ]] || [[ $TUNNEL_ETH == "" ]] || [[ $TUNNEL_CIDR == "" ]]; then
    echo "Error: tunnel network is not configured" >&2
    exit 1
fi
if [[ $EXT_ETH == "" ]] || [[ $EXT_ETH == "" ]] || [[ $EXT_CIDR == "" ]]; then
    echo "Error: external network is not configured" >&2
    exit 1
fi

echo "Networking setup:"
echo "  mgmt:   $MGMT_ETH at $MGMT_IP ($MGMT_CIDR)"
echo "  tunnel: $TUNNEL_ETH at $TUNNEL_IP ($TUNNEL_CIDR)"
echo "  ext:    $EXT_ETH at $EXT_IP ($EXT_CIDR)"
echo " "
echo "LVM volumes:"
if [[ $LVM_LXC_DEV == "" ]]; then
    echo "  lxc:    Not used"
else
    echo "  lxc: /dev/$LVM_LXC_DEV"
fi
if [[ $LVM_CINDER_DEV == "" ]]; then
    echo "  cinder: Not used"
else
    echo "  cinder: /dev/$LVM_CINDER_DEV"
fi
echo " "
echo "Installing: $MODULES"
if [[ $SKIP_LOGGING != "" ]]; then
    echo "Logging disabled"
fi
if [[ $SKIP_HAPROXY != "" ]]; then
    echo "haproxy disabled"
fi
echo " "
read -p "Press Enter to begin..."

KERNEL=`uname -r`
check_root
for MODULE in $MODULES; do
    case $MODULE in
        base)
            do_base
            ;;
        lvm)
            do_lvm
            ;;
        net)
            do_net
            ;;
        ssh)
            do_ssh
            ;;
        ansible)
            do_ansible
            ;;
        playbooks)
            do_playbooks
            ;;
        *)
            echo Unknown module $MODULE >&2
            exit 1
    esac
done

# cheat sheet

# neutron net-create public --router:external True --provider:network_type flat --provider:physical_network --shared extnet
# neutron subnet-create --name public-subnet --gateway 192.168.25.1 --disable-dhcp public 192.168.25.0/24

# neutron net-create test-vxlan --provider:network_type vxlan --provider:segmentation_id 1 --shared
# neutron subnet-create --name test-vxlan-subnet --gateway 10.0.0.1 --disable-dhcp test-vxlan 10.0.0.0/24

# neutron net-create test-vlan --provider:network_type vlan --provider:physical_network extnet --provider:segmentation_id 1 --shared
# neutron subnet-create --name test-vlan-subnet --gateway 10.1.0.1 --disable-dhcp test-vlan 10.1.0.0/24

# neutron router-create router
# neutron router-gateway-set router public
# neutron router-interface-add router test-vxlan-subnet

# wget http://cdn.download.cirros-cloud.net/0.3.2/cirros-0.3.2-x86_64-disk.img
# glance image-create --name "CirrOS 0.3.2" --disk-format qcow2 --container-format bare --is-public true < cirros-0.3.2-x86_64-disk.img

