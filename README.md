vagrant-rpc9
============

Requirements
------------

- 8GB of RAM or more in your system (the VM will take 4GB).
- At least 60GB of free disk space. 
- Install [Vagrant](http://www.vagrantup.com/) and [VirtualBox](https://www.virtualbox.org) if you don't have them yet.

Installation
------------

Create the VM and run the RPC 9.0 install script with the following commands:

    [host]  $ vagrant up
    [host]  $ vagrant ssh
    [guest] $ sudo /vagrant/install.sh

Wait until the script asks you to enter your GitHub credentials. This is to download the ansible scripts from the private repo. After that you have a very long wait, and then hopefully you will have a nice RPC 9.0 installation to play with.
