#!/bin/bash

MY_IP=$( hostname -i )
MY_HOSTNAME=$( hostname )

WRITE_CONF="/write_config.py -e container_ip=${MY_IP} -e container_hostname=${MY_HOSTNAME}"

if [ ! -f /etc/hosts.docker ]; then
    cp /etc/hosts /etc/hosts.docker
fi

cp /etc/hosts.docker /etc/hosts
cat /etc/hosts_compute >> /etc/hosts

pushd /etc/nova
${WRITE_CONF} nova.conf.fragment original/nova.conf nova.conf
popd

pushd /etc/neutron
${WRITE_CONF} neutron.conf.fragment original/neutron.conf neutron.conf
popd

nova-compute &

# run other services here

while [ 1 ] ; do
  sleep 1
done


