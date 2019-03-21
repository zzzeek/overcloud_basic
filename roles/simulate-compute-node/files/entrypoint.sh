#!/bin/bash

MY_IP=$( hostname -i )

pushd /etc/nova
/write_config.sh -e "my_ip=${MY_IP}" nova.conf.fragment original/nova.conf nova.conf
popd

pushd /etc/neutron
/write_config.sh -e "my_ip=${MY_IP}" neutron.conf.fragment original/neutron.conf neutron.conf
popd

nova_compute &

# run other services here