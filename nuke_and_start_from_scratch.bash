#!/bin/bash

vagrant destroy -f
sleep 20
vagrant up
sleep 5
vagrant ssh
sleep 20
vagrant up
sleep 5
vagrant ssh
