===================================
build an overcloud + then do things
===================================

Script / playbooks to deploy a libvirt based overcloud using Infrared for
the virsh + undercloud portion, then a playbook adapted from infrared +
tripleo quickstart to build out the overcloud.   From there, custom playbooks
can be invoked to modify the setup.

The first playbook I'm working on for that is a "simulate compute node"
playbook that spins up additional compute nodes as docker containers
on the hypervisor, using the Nova fake virt driver.

Invocation
==========

The "deploy.sh" script deploys the full system using commands that link
to infrared commands and ansible runs::

  usage: ./deploy.sh <commands>

  commands and/or subcommands can be specified in any order, and are run
  in their order of dependency.   The below sections illustrate
  top level commands that each run a whole section of subcommands,
  as well as the listing of individual subcommands.  All are in
  order of dependency:

  - setup_infrared - ensures infrared is installed
  in a virtual environment here in the current directory
  and our own network / VM templates are added. Includes the
  following subcommands:
     - cleanup_infrared
     - install_infrared

  - setup_vms - uses infrared to build the libvirt networks
  and VMs for the undercloud / overcloud.  Includes the
  following subcommands:
     - rebuild_vms
     - build_hosts

  install_undercloud - runs some undercloud setup steps that
  we've ported and modified from infrared, and then uses
  infrared to run the final undercloud deploy. Includes the
  following subcommands:
     - download_images
     - install_vbmc
     - pre_undercloud
     - deploy_undercloud

  deploy_overcloud - runs our own overcloud playbook to
  install the overcloud. The subcommands here are actually
  ansible tags that can also be specified to exclude the
  others.   Sub-commands (tags) include:
     - gen_ssh_key
     - setup_vlan
     - create_instackenv
     - tune_undercloud
     - introspect_nodes
     - create_flavors
     - build_heat_config
     - prepare_containers
     - run_deploy_overcloud

  simulate_compute_node - runs ansible playbook that will
  run fake compute nodes from hypervisor-based docker containers


