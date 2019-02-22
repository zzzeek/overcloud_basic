#!/bin/bash

DIRNAME=`dirname $0`
SCRIPT_HOME=`realpath $DIRNAME`
DISK_POOL=/home/infrared_images

COMPUTE_SCALE="3"

NAMESERVERS="10.16.36.29,10.11.5.19,10.5.30.160"
NTP_SERVER="clock.corp.redhat.com"

CHECKOUTS=${SCRIPT_HOME}/checkouts
OVERCLOUD_IMAGES=${SCRIPT_HOME}/downloaded_overcloud_images
INFRARED_CHECKOUT=${CHECKOUTS}/infrared

INFRARED_REVISION="master"
#INFRARED_REVISION="31370846e54bec15d816cf3f3e923f0d74fa16a5"

INFRARED_WORKSPACE_NAME=stack
INFRARED_WORKSPACE=${INFRARED_CHECKOUT}/.workspaces/${INFRARED_WORKSPACE_NAME}
ANSIBLE_PLAYBOOK=${INFRARED_CHECKOUT}/.venv/bin/ansible-playbook

ANSIBLE_HOSTS=${INFRARED_WORKSPACE}/hosts_undercloud

SETUP_CMDS="cleanup_infrared setup_infrared download_images"
BUILD_ENVIRONMENT_CMDS="rebuild_vms build_hosts install_vbmc pre_undercloud deploy_undercloud"

: ${CMDS:="${SETUP_CMDS} ${BUILD_ENVIRONMENT_CMDS} deploy_overcloud"}

: ${DEPLOY_OVERCLOUD_TAGS:="gen_ssh_key,setup_vlan,create_instackenv,tune_undercloud,introspect_nodes,create_flavors,build_heat_config,prepare_containers,run_deploy_overcloud"}


RELEASE=rocky

# this token goes into the URL as follows:
# https://trunk.rdoproject.org/centos7-{{ RELEASE_OR_MASTER_DLRN }}/{{ BUILD }}/delorean.repo
RELEASE_OR_MASTER_DLRN=rocky
BUILD=current-tripleo-rdo

# options here:
#BUILD=current-tripleo-rdo-internal    most tested / oldest
#BUILD=current-tripleo-rdo
#BUILD=current-tripleo
#BUILD=current                         least tested / newest



# this token is for the images.rdoproject.org link
RELEASE_OR_MASTER_IMAGES=master
RDO_OVERCLOUD_IMAGES="https://images.rdoproject.org/${RELEASE_OR_MASTER_IMAGES}/delorean/${BUILD}/"



IMAGE_URL="file:///tmp/"

set -e
set -x


getinput() {
  local prompt="$1"
  local input=''

  set +x
  echo "${prompt}"
  while [ "1" ];  do
  read -rsn1 input
  case "$input" in
      Y) set -x; YESNO=1; return;;
      n) set -x; YESNO=0; return;;
      *) echo "please answer Y or n"
  esac
  done
}


cleanup_infrared() {
    getinput "WARNING!  Will wipe out the entire infrared checkout, including all infrared hostfiles, ansible will no longer be able to run against current VMs, (Y)es/(n)o"

    # note this implies cleaning up the workspace
    # also
    if [ "$YESNO" = "1" ]; then
        rm -fr ${INFRARED_CHECKOUT}
    else
        exit -1
    fi
}

reset_workspace() {
    getinput "WARNING!  Will wipe out the infrared workspace, which erases all infrared hostfiles, ansible will no longer be able to run against current VMs, (Y)es/(n)o "

    if [ "$YESNO" == "1" ]; then
        rm -fr ${INFRARED_WORKSPACE}
    else
       exit -1
    fi
}


setup_infrared() {
    SYSTEM_PYTHON_2=/usr/bin/python2

    # sudo yum install git gcc libffi-devel openssl-devel python-virtualenv libselinux-python

    mkdir -p ${CHECKOUTS}

    if [ ! -d ${INFRARED_CHECKOUT} ]; then
        git clone https://github.com/redhat-openstack/infrared.git ${INFRARED_CHECKOUT}
        pushd ${INFRARED_CHECKOUT}
        git checkout ${INFRARED_REVISION}
        for patchfile in `ls ${SCRIPT_HOME}/infrared/patches/*.patch`
        do
            patch -p1 < ${patchfile}
        done
        popd
    fi

    cp -uR ${SCRIPT_HOME}/infrared/virsh_topology/* ${INFRARED_CHECKOUT}/plugins/virsh/vars/topology/

    if [[ ! -d ${INFRARED_CHECKOUT}/.venv ]]; then
        pushd ${INFRARED_CHECKOUT}

        ${SYSTEM_PYTHON_2} -m virtualenv .venv
        . .venv/bin/activate
        pip install --upgrade pip
        pip install --upgrade setuptools
        pip install .

        .venv/bin/infrared plugin add all

        popd
    fi
}

download_images() {
    mkdir -p ${OVERCLOUD_IMAGES}/${RELEASE}
    pushd ${OVERCLOUD_IMAGES}/${RELEASE}
    curl -O ${RDO_OVERCLOUD_IMAGES}/ironic-python-agent.tar
    curl -O ${RDO_OVERCLOUD_IMAGES}/overcloud-full.tar
    popd
}


setup_infrared_env() {
    if [[ -d $INFRARED_CHECKOUT ]] ; then
        . ${INFRARED_CHECKOUT}/.venv/bin/activate

        # checkout -c doesn't work, still errors out if the workspace exists.
        infrared_cmd workspace create ${INFRARED_WORKSPACE_NAME} && true
        infrared_cmd workspace checkout ${INFRARED_WORKSPACE_NAME}
    fi
}

cleanup_networks() {
    set +e

    NETWORK_NAMES=$( sudo virsh net-list --all | awk '{print $1}' | grep -v Name )

    for name in ${NETWORK_NAMES} ; do
        sudo virsh net-destroy $name;
        sudo virsh net-undefine $name;
    done

    set -e

    rm -f ${INFRARED_WORKSPACE}/stack?_hosts_* \
       ${INFRARED_WORKSPACE}/hosts \
       ${INFRARED_WORKSPACE}/hosts-prov \
       ${INFRARED_WORKSPACE}/hosts-install \
       ${INFRARED_WORKSPACE}/ansible.ssh.config

}

cleanup_vms() {
    set +e

    VM_NAMES=""

    NAMES=$( sudo virsh list --all | awk '{print $2}' | grep -vi "name" )
    VM_NAMES="${VM_NAMES} ${NAMES}"

    for name in ${VM_NAMES} ; do
        sudo virsh destroy $name;
        sudo virsh undefine $name --remove-all-storage;
    done

    set -e

}


infrared_cmd() {
    IR_HOME=${INFRARED_CHECKOUT} ANSIBLE_CONFIG=${INFRARED_CHECKOUT}/ansible.cfg infrared $@
}


build_networks() {
    # use virsh with zero machines so the networks build
    # TODO: propose --networks-only flag for infrared
    infrared_cmd virsh -vv \
        --topology-nodes="undercloud:0" \
        --topology-network=zzzeek_networks \
        --ansible-args="skip-tags=vms" \
        --host-key $HOME/.ssh/id_rsa  --host-address=127.0.0.2
}

build_vms() {

    NODES=""

    NODES="${NODES}undercloud:1,controller:3,compute:${COMPUTE_SCALE},"

    # trim trailing comma
    NODES=${NODES:0:-1}

    # problem?  make sure to use public-images with undercloud
    #    --image-url https://cloud.centos.org/centos/7/images/CentOS-7-x86_64-GenericCloud.qcow2 \

    infrared_cmd virsh -vv \
        --disk-pool="${DISK_POOL}" \
        --topology-nodes="${NODES}" \
        --topology-network=zzzeek_networks \
        --topology-extend=yes \
        --host-key $HOME/.ssh/id_rsa  --host-address=127.0.0.2 \
        --image-url https://cloud.centos.org/centos/7/images/CentOS-7-x86_64-GenericCloud.qcow2 \

}


upload_images() {
    pushd ${INFRARED_CHECKOUT}
    scp -F ${INFRARED_WORKSPACE}/ansible.ssh.config ${OVERCLOUD_IMAGES}/${RELEASE}/* undercloud-0:/tmp/
    popd
}

deploy_undercloud() {

    PROVISIONING_IP_PREFIX=192.168.24
    LIMIT_HOSTFILE=${INFRARED_WORKSPACE}/hosts-prov
    WRITE_HOSTFILE=${ANSIBLE_HOSTS}

    infrared_cmd tripleo-undercloud -vv --version ${RELEASE} \
        --inventory=${LIMIT_HOSTFILE} \
        --build ${BUILD} \
        -e rr_use_public_repos=true \
        -e rr_release_name=${RELEASE_OR_MASTER_DLRN} \
        --config-options DEFAULT.enable_telemetry=false \
        --config-options DEFAULT.undercloud_nameservers="${NAMESERVERS}" \
        --config-options DEFAULT.undercloud_ntp_servers="${NTP_SERVER}" \
        --images-task import --images-url ${IMAGE_URL}

    cp ${INFRARED_WORKSPACE}/hosts ${WRITE_HOSTFILE}
}

deploy_overcloud() {
    pushd ${SCRIPT_HOME}
    ${ANSIBLE_PLAYBOOK} -vv \
        -i ${ANSIBLE_HOSTS} \
        --tags "${DEPLOY_OVERCLOUD_TAGS}" \
        -e release_name=${RELEASE} \
        -e container_namespace=${RELEASE_OR_MASTER_IMAGES} \
        -e container_tag=${BUILD} \
        -e working_dir=/home/stack  \
        -e compute_scale="${COMPUTE_SCALE}" \
        -e ntp_server="${NTP_SERVER}" \
        playbooks/deploy_overcloud.yml
    popd

}

install_vbmc() {
    pushd ${SCRIPT_HOME}
    ${ANSIBLE_PLAYBOOK} -vv \
        -i ${ANSIBLE_HOSTS}  \
        playbooks/deploy_vbmc.yml
    popd
}

pre_undercloud() {
    pushd ${SCRIPT_HOME}
    ${ANSIBLE_PLAYBOOK} -vv \
        -i ${ANSIBLE_HOSTS}  \
        playbooks/pre_undercloud.yml
    popd
}


if [[ "${CMDS}" == *"cleanup_infrared"* ]]; then
    cleanup_infrared
elif [[ "${CMDS}" == *"rebuild_vms"* ]]; then
    reset_workspace
fi

if [[ "${CMDS}" == *"setup_infrared"* ]]; then
    setup_infrared
fi

if [[ "${CMDS}" == *"download_images"* ]]; then
    download_images
fi


setup_infrared_env

if [[ "${CMDS}" == *"rebuild_vms"* || "${CMDS}" == *"cleanup_virt"* ]]; then
    cleanup_networks
    cleanup_vms
fi

if [[ "${CMDS}" == *"rebuild_vms"* ]]; then
    build_networks
    build_vms
    upload_images
fi

if [[ "${CMDS}" == *"pre_undercloud"* ]]; then
    pre_undercloud
fi

if [[ "${CMDS}" == *"deploy_undercloud"* ]]; then
    deploy_undercloud
fi


if [[ "${CMDS}" == *"install_vbmc"* ]]; then
    install_vbmc
fi


if [[ "${CMDS}" == *"deploy_overcloud"* ]]; then
 deploy_overcloud
fi


