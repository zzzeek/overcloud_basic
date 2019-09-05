#!/bin/bash

DIRNAME=`dirname $0`
SCRIPT_HOME=`realpath $DIRNAME`
DISK_POOL=/home/infrared_images

COMPUTE_SCALE="1"

NAMESERVERS="10.16.36.29,10.11.5.19,10.5.30.160"
NTP_SERVER="clock.corp.redhat.com"

DOCKER_MIRROR="brew-pulp-docker01.web.prod.ext.phx2.redhat.com:8888"

CHECKOUTS=${SCRIPT_HOME}/checkouts
OVERCLOUD_IMAGES=${SCRIPT_HOME}/downloaded_overcloud_images
INFRARED_CHECKOUT=${CHECKOUTS}/infrared

INFRARED_REVISION="master"
#INFRARED_REVISION="31370846e54bec15d816cf3f3e923f0d74fa16a5"

INFRARED_WORKSPACE_NAME=stack
INFRARED_WORKSPACE=${INFRARED_CHECKOUT}/.workspaces/${INFRARED_WORKSPACE_NAME}
ANSIBLE_PLAYBOOK=${INFRARED_CHECKOUT}/.venv/bin/ansible-playbook

UNDERCLOUD_HOSTS=${INFRARED_WORKSPACE}/hosts_undercloud
OVERCLOUD_HOSTS=${INFRARED_WORKSPACE}/hosts_overcloud

# RHEL_OR_RDO='rdo'
# RELEASE=stein

RHEL_OR_RDO='rhel'
#RELEASE="15-trunk"
RELEASE="13"


# this token goes into the URL as follows:
RELEASE_OR_MASTER_DLRN=stein
BUILD=current-tripleo-rdo
DLRN="https://trunk.rdoproject.org/centos7-${RELEASE_OR_MASTER_DLRN}/${BUILD}/delorean.repo"
DLRN_DEPS="https://trunk.rdoproject.org/centos7-${RELEASE_OR_MASTER_DLRN}/delorean-deps.repo"

# options here:
#BUILD=current-tripleo-rdo-internal    most tested / oldest
#BUILD=current-tripleo-rdo
#BUILD=current-tripleo
#BUILD=current                         least tested / newest



# this token is for the images.rdoproject.org link
RDO_RELEASE_OR_MASTER_IMAGES=${RELEASE}/rdo_trunk
# RDO_RELEASE_OR_MASTER_IMAGES=queens/delorean
# RDO_RELEASE_OR_MASTER_IMAGES=master/delorean
# etc
RDO_OVERCLOUD_IMAGES="https://images.rdoproject.org/${RDO_RELEASE_OR_MASTER_IMAGES}/"



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


install_infrared() {
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

        setup_infrared_env

        infrared plugin add all

        popd
    fi
}

setup_infrared_env() {
    if [[ "${_INFRARED_SETUP}" == "" ]]; then
        if [[ -d $INFRARED_CHECKOUT ]] ; then
            . ${INFRARED_CHECKOUT}/.venv/bin/activate

            # checkout -c doesn't work, still errors out if the workspace exists.
            infrared_cmd workspace create ${INFRARED_WORKSPACE_NAME} && true

            infrared_cmd workspace checkout ${INFRARED_WORKSPACE_NAME}
        fi

        _INFRARED_SETUP="1"
    fi
}


download_images() {
    if [ "${RHEL_OR_RDO}" == 'rhel' ]; then
        return
    fi

    mkdir -p ${OVERCLOUD_IMAGES}/${RELEASE}
    pushd ${OVERCLOUD_IMAGES}/${RELEASE}

    DLRN_HASH=$( curl -s "${DLRN}" | grep baseurl | awk -F'/' '{print $NF}' )

    do_curl_w_md5 "${RDO_OVERCLOUD_IMAGES}/${DLRN_HASH}" ironic-python-agent.tar
    do_curl_w_md5 "${RDO_OVERCLOUD_IMAGES}/${DLRN_HASH}" overcloud-full.tar
    popd
}

do_curl_w_md5() {
    CACHE="${HOME}/mikes_curl_cache"
    URL=$1
    FILENAME=$2

    if [[ ! -d "${CACHE}" ]]; then
        mkdir -p "${CACHE}"
    fi

    MD5=$( curl -s "${URL}/${FILENAME}.md5" | awk '{print $1}' )

    if [[ -f "${CACHE}/${FILENAME}_${MD5}" ]]; then
        cp "${CACHE}/${FILENAME}_${MD5}" "${FILENAME}"
    else
        curl -O "${URL}/${FILENAME}"
        cp "${FILENAME}" "${CACHE}/${FILENAME}_${MD5}"
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

    if [ "${RHEL_OR_RDO}" == 'rdo' ]; then
        QCOW_URL="https://cloud.centos.org/centos/7/images/CentOS-7-x86_64-GenericCloud.qcow2"
    else
	# OSP15
	# QCOW_URL="http://download-node-02.eng.bos.redhat.com/rel-eng/latest-RHEL-8.0/compose/BaseOS/x86_64/images/rhel-guest-image-8.0-1854.x86_64.qcow2"

	# OSP13
	QCOW_URL="http://download-node-02.eng.bos.redhat.com/rel-eng/latest-RHEL-7.5/compose/Server/x86_64/images/rhel-guest-image-7.5-146.x86_64.qcow2"
	#QCOW_URL="http://download-node-02.eng.bos.redhat.com/rel-eng/latest-RHEL-7.6/compose/Server/x86_64/images/rhel-guest-image-7.6-210.x86_64.qcow2"
        #QCOW_URL="http://download-node-02.eng.bos.redhat.com/rel-eng/latest-RHEL-8/compose/BaseOS/x86_64/images/rhel-guest-image-8.1-43.x86_64.qcow2"
    fi

    infrared_cmd virsh -vv \
        --disk-pool="${DISK_POOL}" \
        --topology-nodes="${NODES}" \
        --topology-network=zzzeek_networks \
        --topology-extend=yes \
        --host-key $HOME/.ssh/id_rsa  --host-address=127.0.0.2 \
        --image-url "${QCOW_URL}"

}

write_overcloud_hosts() {
   cp ${INFRARED_WORKSPACE}/hosts-prov ${OVERCLOUD_HOSTS}

   sed -i -E 's/(controller.*)ansible_user=[[:alpha:]-]+(.*)/\1ansible_user=heat-admin\2/' ${OVERCLOUD_HOSTS}
   sed -i -E 's/(compute.*)ansible_user=[[:alpha:]-]+(.*)/\1ansible_user=heat-admin\2/' ${OVERCLOUD_HOSTS}
   sed -i -E 's/(undercloud.*)ansible_user=[[:alpha:]-]+(.*)/\1ansible_user=stack\2/' ${OVERCLOUD_HOSTS}


}


upload_images() {
    if [ "${RHEL_OR_RDO}" == "rhel" ]; then
        return
    fi

    pushd ${INFRARED_CHECKOUT}
    scp -F ${INFRARED_WORKSPACE}/ansible.ssh.config ${OVERCLOUD_IMAGES}/${RELEASE}/* undercloud-0:/tmp/
    popd
}

deploy_undercloud() {

    PROVISIONING_IP_PREFIX=192.168.24
    LIMIT_HOSTFILE=${INFRARED_WORKSPACE}/hosts-prov
    WRITE_HOSTFILE=${UNDERCLOUD_HOSTS}

    UNDERCLOUD_OPTS=""

    if [ "${DOCKER_MIRROR}" != "" ]; then
        UNDERCLOUD_OPTS="${UNDERCLOUD_OPTS} --registry-mirror=brew-pulp-docker01.web.prod.ext.phx2.redhat.com:8888"
    fi

    # in Stein / OSP15, we don't have a local "podman" registry, it's a blank do-nothing
	# httpd host.  so please don't use --local-push-destination even with
	# undercloud.
	UNDERCLOUD_OPTS="${UNDERCLOUD_OPTS} --registry-undercloud-skip=true"

    if [ "${RHEL_OR_RDO}" == "rhel" ]; then
        UNDERCLOUD_OPTS="${UNDERCLOUD_OPTS} --images-task rpm"
        UNDERCLOUD_OPTS="${UNDERCLOUD_OPTS} --enable-testing-repos all"
    else
        UNDERCLOUD_OPTS="${UNDERCLOUD_OPTS} -e rr_use_public_repos=true"
        UNDERCLOUD_OPTS="${UNDERCLOUD_OPTS} -e rr_release_name=${RELEASE_OR_MASTER_DLRN}"
        UNDERCLOUD_OPTS="${UNDERCLOUD_OPTS} --images-task import"
        UNDERCLOUD_OPTS="${UNDERCLOUD_OPTS} --image-url ${IMAGE_URL}"
    fi

    infrared_cmd tripleo-undercloud -vv --version ${RELEASE} \
        --inventory=${LIMIT_HOSTFILE} \
        ${UNDERCLOUD_OPTS} \
        --config-options DEFAULT.enable_telemetry=false \
        --config-options DEFAULT.undercloud_nameservers="${NAMESERVERS}" \
        --config-options DEFAULT.undercloud_ntp_servers="${NTP_SERVER}"

    cp ${INFRARED_WORKSPACE}/hosts ${WRITE_HOSTFILE}
    write_overcloud_hosts
}

deploy_overcloud() {
    pushd ${SCRIPT_HOME}
    ${ANSIBLE_PLAYBOOK} -vv \
        -i ${UNDERCLOUD_HOSTS} \
        --tags "${DEPLOY_OVERCLOUD_TAGS}" \
        -e release_name=${RELEASE} \
        -e rdo_container_namespace=${RDO_RELEASE_OR_MASTER_IMAGES} \
        -e container_tag=${BUILD} \
        -e working_dir=/home/stack  \
        -e compute_scale="${COMPUTE_SCALE}" \
        -e ntp_server="${NTP_SERVER}" \
        playbooks/deploy_overcloud.yml
    popd

}

simulate_compute_node() {
    pushd ${SCRIPT_HOME}
    ${ANSIBLE_PLAYBOOK} -vv \
        -i ${OVERCLOUD_HOSTS} \
        -e delorean_url=${DLRN} \
        -e delorean_deps_url=${DLRN_DEPS} \
        playbooks/simulate_compute_node.yml
    popd
}


install_vbmc() {
    pushd ${SCRIPT_HOME}
    ${ANSIBLE_PLAYBOOK} -vv \
        -i ${UNDERCLOUD_HOSTS}  \
        playbooks/deploy_vbmc.yml
    popd
}

pre_undercloud() {
    pushd ${SCRIPT_HOME}
    ${ANSIBLE_PLAYBOOK} -vv \
        -i ${UNDERCLOUD_HOSTS}  \
        playbooks/pre_undercloud.yml
    popd
}


main() {

    INFRARED_CMDS="cleanup_infrared install_infrared"
    VMS_CMDS="rebuild_vms build_hosts"
    UNDERCLOUD_CMDS="download_images install_vbmc pre_undercloud deploy_undercloud"
    OVERCLOUD_CMDS="deploy_overcloud"
    OVERCLOUD_TAGS="gen_ssh_key setup_vlan create_instackenv tune_undercloud introspect_nodes create_flavors build_heat_config prepare_containers run_deploy_overcloud"

    CMDS="$@"

    DEPLOY_OVERCLOUD_TAGS=""
    for tag in ${OVERCLOUD_TAGS}; do
        if [[ "${CMDS}" == *"${tag}"* ]]; then
            DEPLOY_OVERCLOUD_TAGS="${tag},${DEPLOY_OVERCLOUD_TAGS}"
        fi
    done

    if [[ "${DEPLOY_OVERCLOUD_TAGS}" != "" ]]; then
        CMDS="${CMDS} ${OVERCLOUD_CMDS}"
    else
        # no tags set up, so default to all of them
        DEPLOY_OVERCLOUD_TAGS="all"
    fi

    if [[ "${CMDS}" == *"setup_infrared"* ]]; then
        CMDS="${INFRARED_CMDS} ${CMDS}"
    fi

    if [[ "${CMDS}" == *"setup_vms"* ]]; then
        CMDS="${VMS_CMDS} ${CMDS}"
    fi

    if [[ "${CMDS}" == *"install_undercloud"* ]]; then
        CMDS="${UNDERCLOUD_CMDS} ${CMDS}"
    fi

    if [[ "${CMDS}" == "" ]]; then
        CMDS="help"
    fi

    if [[ "${CMDS}" == *"help"* ]]; then
        set +x
        echo -e "\nusage: $0 <commands>\n"
        echo -e "commands and/or subcommands can be specified in any order, and are run"
        echo -e "in their order of dependency.   The below sections illustrate "
        echo    "top level commands that each run a whole section of subcommands, "
        echo    "as well as the listing of individual subcommands.  All are in "
        echo    "order of dependency:"
        echo -e "\n- setup_infrared - ensures infrared is installed "
        echo    "in a virtual environment here in the current directory "
        echo    "and our own network / VM templates are added. Includes the "
        echo    "following subcommands:"
        for cmd in ${INFRARED_CMDS}; do
            echo "   - $cmd"
        done
        echo -e "\n- setup_vms - uses infrared to build the libvirt networks "
        echo    "and VMs for the undercloud / overcloud.  Includes the "
        echo    "following subcommands:"
        for cmd in ${VMS_CMDS}; do
            echo "   - $cmd"
        done
        echo -e "\ninstall_undercloud - runs some undercloud setup steps that "
        echo    "we've ported and modified from infrared, and then uses "
        echo    "infrared to run the final undercloud deploy. Includes the "
        echo    "following subcommands:"
        for cmd in ${UNDERCLOUD_CMDS}; do
            echo "   - $cmd"
        done
        echo -e "\ndeploy_overcloud - runs our own overcloud playbook to "
        echo    "install the overcloud. The subcommands here are actually "
        echo    "ansible tags that can also be specified to exclude the "
        echo    "others.   Sub-commands (tags) include:"
        for cmd in ${OVERCLOUD_TAGS}; do
            echo "   - $cmd"
        done
        echo -e "\nsimulate_compute_node - runs ansible playbook that will "
        echo    "run fake compute nodes from hypervisor-based docker containers"
        exit
    fi

    if [[ "${CMDS}" == *"cleanup_infrared"* ]]; then
        cleanup_infrared
    elif [[ "${CMDS}" == *"rebuild_vms"* ]]; then
        reset_workspace
    fi

    if [[ "${CMDS}" == *"install_infrared"* ]]; then
        install_infrared
    fi

    if [[ "${CMDS}" == *"download_images"* ]]; then
        download_images
    fi


    if [[ "${CMDS}" == *"rebuild_vms"* || "${CMDS}" == *"cleanup_virt"* ]]; then
        cleanup_networks
        cleanup_vms
    fi

    if [[ "${CMDS}" == *"rebuild_vms"* ]]; then
        setup_infrared_env
        build_networks
        build_vms
        upload_images
    fi

    if [[ "${CMDS}" == *"pre_undercloud"* ]]; then
        pre_undercloud
    fi

    if [[ "${CMDS}" == *"deploy_undercloud"* ]]; then
        setup_infrared_env
        deploy_undercloud
    fi


    if [[ "${CMDS}" == *"install_vbmc"* ]]; then
        install_vbmc
    fi


    if [[ "${CMDS}" == *"deploy_overcloud"* ]]; then
     deploy_overcloud
    fi

    if [[ "${CMDS}" == *"simulate_compute_node"* ]]; then
      simulate_compute_node
    fi

}

main "$@"



