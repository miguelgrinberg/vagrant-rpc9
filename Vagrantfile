# -*- mode: ruby -*-
# vi: set ft=ruby :

$proxyconfig = <<SCRIPT
echo 'Acquire::http::Proxy "http://10.5.5.5:3142";' > /etc/apt/apt.conf.d/01proxy
SCRIPT


# Script requires that https://github.com/johnmarkschofield/vagrant-apt-cacher be installed and running.


VAGRANTFILE_API_VERSION = "2"

Vagrant.configure(VAGRANTFILE_API_VERSION) do |config|
    config.vm.provision "shell", inline: $proxyconfig
    config.vm.box_url = "https://cloud-images.ubuntu.com/vagrant/trusty/current/trusty-server-cloudimg-amd64-vagrant-disk1.box"
    config.vm.box = "trusty64"
    config.vm.hostname = "infra1"
    config.ssh.forward_agent = true
    config.vm.network "private_network", ip: "10.0.0.11"
    config.vm.network "private_network", ip: "10.1.0.11", auto_config: false
    config.vm.network "private_network", ip: "10.5.5.16" # required for vagrant-apt-cacher
    config.vm.provider "virtualbox" do |vb|
        vb.customize ["modifyvm", :id, "--memory", "4096"]
        vb.customize ["modifyvm", :id, "--nicpromisc3", "allow-all"]

        unless File.exist?('./sdb.vdi')
            vb.customize ['createhd', '--filename', './sdb.vdi', '--size', 50 * 1024]
            vb.customize ['storageattach', :id, '--storagectl', 'SATAController', '--port', 1, '--device', 0, '--type', 'hdd', '--medium', './sdb.vdi']
        end
        unless File.exist?('./sdc.vdi')
            vb.customize ['createhd', '--filename', './sdc.vdi', '--size', 5 * 1024]
            vb.customize ['storageattach', :id, '--storagectl', 'SATAController', '--port', 2, '--device', 0, '--type', 'hdd', '--medium', './sdc.vdi']
        end
    end
    #config.vm.provision "shell", path: "install.sh"
end
