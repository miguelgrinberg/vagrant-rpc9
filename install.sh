#!/bin/bash

# All-In-One RPC installer script
# Example for cloud server:
# $ ./install.sh -m eth2,192.168.21.1,192.168.21.0/24 -t eth3,192.168.22.2,192.168.22.0/24 -e eth4,192.168.25.1,192.168.25.0/24 --lxc xvde --cinder xvdb all
#
# Example for vagrant:
# ./install.sh -m eth1,10.0.0.11,10.0.0.0/24 -t eth2,10.1.0.11,10.1.0.0/24 -e eth3,10.2.0.11,10.2.0.0/24 --cinder sdb --no-log all

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
    mkdir -p /opt
    cd /opt
    git clone -b $RPC_BRANCH $RPC_REPO
    pip install -r /opt/os-ansible-deployment/requirements.txt
    cd /opt/os-ansible-deployment
    scripts/bootstrap-ansible.sh
    cp -R /opt/os-ansible-deployment/etc/openstack_deploy/ /etc/openstack_deploy
    rm /etc/openstack_deploy/conf.d/swift.yml
    /opt/os-ansible-deployment/scripts/pw-token-gen.py --file /etc/openstack_deploy/user_secrets.yml
    /opt/os-ansible-deployment/scripts/pw-token-gen.py --file /etc/openstack_deploy/user_variables.yml
    cat <<EOF >/etc/openstack_deploy/openstack_user_config.yml
---
environment_version: 58339ffafde4614abb7021482cc6604b

cidr_networks:
  container: 192.168.21.0/24
  snet: 192.168.21.0/24
  tunnel: 192.168.22.0/24
  storage: 192.168.22.0/24

global_overrides:
  internal_lb_vip_address: 192.168.21.1
  external_lb_vip_address: 192.168.25.1
  lb_name: "lb"
  tunnel_bridge: "br-vmnet"
  management_bridge: "br-mgmt"
  provider_networks:
    - network:
        container_bridge: "br-mgmt"
        container_type: "veth"
        container_interface: "eth1"
        ip_from_q: "container"
        type: "raw"
        group_binds:
          - all_containers
          - hosts
        is_container_address: true
        is_ssh_address: true
    - network:
        container_bridge: "br-vmnet"
        container_type: "veth"
        container_interface: "eth10"
        ip_from_q: "tunnel"
        type: "vxlan"
        range: "1:1000"
        net_name: "vxlan"
        group_binds:
          - neutron_linuxbridge_agent
    - network:
        container_bridge: "br-ext"
        container_type: "veth"
        container_interface: "eth11"
        type: "flat"
        net_name: "extnet"
        group_binds:
          - neutron_linuxbridge_agent
    - network:
        container_bridge: "br-ext"
        container_type: "veth"
        container_interface: "eth11"
        type: "vlan"
        range: "1:1"
        net_name: "extnet"
        group_binds:
          - neutron_linuxbridge_agent

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
    cd /opt/os-ansible-deployment/playbooks/
    sed -i "s/^openstack_host_required_kernel:.*\$/openstack_host_required_kernel: $KERNEL/" inventory/group_vars/all.yml
    sed -i "s/pip_no_index:.*\$/pip_no_index: false/" roles/pip_lock_down/defaults/main.yml
}

run_playbook()
{
    ATTEMPT=1
    RETRIES=3
    VERBOSE=""
    RETRY=""
    cd /opt/os-ansible-deployment/playbooks
    while ! ansible-playbook $VERBOSE -e @/etc/openstack_deploy/user_secrets.yml -e @/etc/openstack_deploy/user_variables.yml $1.yml $RETRY ; do 
        if [ $ATTEMPT -ge $RETRIES ]; then
            exit 1
        fi
        ATTEMPT=$((ATTEMPT+1))
        sleep 10
        VERBOSE=-vvv
        RETRY="--limit @/root/$1.retry"
    done
}

do_playbooks()
{
    run_playbook setup-hosts

    run_playbook memcached-install
    #run_playbook repo-install
    if [[ $SKIP_GALERA == "" ]]; then
        run_playbook galera-install
    fi
    run_playbook rabbitmq-install
    if [[ $SKIP_LOGGING == "" ]]; then
        run_playbook rsyslog-install
    fi
    run_playbook utility-install
    if [[ $SKIP_HAPROXY == "" ]]; then
        run_playbook haproxy-install
    fi

    run_playbook setup-openstack
}

usage()
{
    echo "Usage: install.sh [options] module ..."
    echo "Options:"
    echo "  --branch(-b): RPC branch to install (default master)"
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
        --repo|-r)
            RPC_REPO=$2
            shift;
            ;;
        --branch|-b)
            RPC_BRANCH=$2
            shift
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

if [[ $RPC_REPO == "" ]]; then
    RPC_REPO="https://github.com/stackforge/os-ansible-deployment.git"
fi

if [[ $RPC_BRANCH == "" ]]; then
    RPC_BRANCH="master"
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

echo "RPC Repo: $RPC_REPO"
echo "RPC Branch: $RPC_BRANCH"
echo " "
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

