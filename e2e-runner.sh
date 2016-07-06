#!/bin/bash
set -uo pipefail
setenforce 1

# Fix sudo require tty
sudo grep -q "# Defaults    requiretty" /etc/sudoers
if [ $? -ne 0 ] ; then
  sudo sed -i 's/Defaults    requiretty/# Defaults    requiretty/' /etc/sudoers
fi

# Holds the exit code and is updated if an error that should not stop
# the run occurs
ERROR=0

# Convenience function for handling exit codes
err() {
    exit_code=$1; shift
    err_msg=$1; shift
    should_exit=$1; shift

    if [ $exit_code -ne 0 ]; then
        ERROR=1

        if [ "$should_exit" -eq 1 ]; then
            wget $BUILD_URL/consoleText -O build.log
            exit 1
        fi
    fi
}

mkdir -p $WORKSPACE/artifacts




echo "--------------------------------------------------------------------------------"
echo "Test Environment:"
# TODO(jchaloup): Filter out some envs with internal IPs and sensitive data
# use whitelist instead?
printenv | sort
echo "--------------------------------------------------------------------------------"

# Private envs
#EXISTING_NODES=`grep "EXISTING_NODES" $WORKSPACE/RESOURCES.txt | cut -d= -f2`
#CLUSTER_IP_MASTERS=`grep "CLUSTER_IP_MASTERS" $WORKSPACE/RESOURCES.txt | cut -d= -f2`





echo "--------------------------------------------------------------------------------"
echo "Installing packages:"

# We need these packages added at a minimum to build and test
yum install -y golang tar

# openssl-devel through libffi-devel are extras required for
# installing gsutil
yum install -y python-pip python-devel python-netaddr \
               gcc ansible \
               openssl-devel python-devel \
               python-setuptools libffi-devel

# Install gsutil through pip (for e2e tests)
pip install gsutil




echo "--------------------------------------------------------------------------------"
echo "Building and testing kubernetes from hack directory:"

pushd kubernetes

# Set the KUBE_GIT_VERSION
export KUBE_GIT_VERSION=$(git describe --match "v*")
echo "Setting KUBE_GIT_VERSION to $KUBE_GIT_VERSION"

# Install etcd and add it to PATH
./hack/install-etcd.sh
export PATH=third_party/etcd:${PATH}

# First build kubernetes
echo -e "\n\nRunning hack/build-go.sh\n"
./hack/build-go.sh
err $? "ERROR: build-go.sh failed\nSTATUS: $?" 1 "error"

# Then run tests
for cmd in e2e-node-test.sh test-go.sh test-cmd.sh "test-integration.sh --use_go_build"; do
    echo -e "\n\nRunning hack/$cmd\n"
    ./hack/$cmd
    err $? "ERROR: Test $cmd failed\nSTATUS: $?" 0 "failure"
done
popd

echo "--------------------------------------------------------------------------------"





echo "--------------------------------------------------------------------------------"
echo "Pinging test resources:"
echo $EXISTING_NODES | xargs -I{} -d , ping -c 5 {}
err $? "ERROR: At least one existing node failed to respond\nSTATUS: $?\nEXISTING_NODES: $EXISTING_NODES" 0 "error"
echo "--------------------------------------------------------------------------------"





echo "--------------------------------------------------------------------------------"
echo "Setting kubernetes config files"
pushd contrib/init/systemd/environ
echo "Removing SecurityContextDeny from admission-control"
sed -i "s/SecurityContextDeny,//" apiserver
popd


echo "Setting and running ansible playbooks:"

# Set ansible preferences
export ANSIBLE_HOST_KEY_CHECKING=False
chmod 600 ${WORKSPACE}/ci-factory/targets/keys/ci-factory

pushd contrib/ansible

echo "Tuning ansible script knobs before running..."
# Convenience function to update variables
set_yml_var() {
    file=$1; shift
    varname=$1; shift
    varval=$1; shift

    echo -n "old $file: "; grep "^$varname" $file #"
    sed -i "/^$varname / s/ .*/ $varval/" $file
    echo -n "new $file: "; grep "^$varname" $file #"
}

# This is required because the default flannel_subnet suggested will
# overlap with the QEOS subnet.
set_yml_var group_vars/all.yml flannel_subnet: '10.253.0.0'
set_yml_var group_vars/all.yml flannel_prefix: '16'

set_yml_var group_vars/all.yml source_type: 'localBuild'

# We need to use a non-privileged port number so that the kube user
# will be able to bind to it when launching the apiserver
set_yml_var roles/kubernetes/defaults/main.yml \
    kube_master_api_port: '6443'

set_yml_var group_vars/all.yml \
    kube_master_api_port: '6443'

# We want the certificate to be valid for the public IP of the
# master, which will be retrieved from the OS metadata server
set_yml_var roles/kubernetes/defaults/main.yml \
    kube_cert_ip: '_use_aws_external_ip_'

set_yml_var roles/master/defaults/main.yml \
    localBuildOutput: "..\/..\/kubernetes\/_output\/local\/go\/bin"

set_yml_var roles/node/defaults/main.yml \
    localBuildOutput: "..\/..\/kubernetes\/_output\/local\/go\/bin"

# We also have to make the apiserver listen unsafely on all
# interfaces so that we don't have to set up authentication for
# testing (alternatively, set up authentication)
file=roles/master/templates/apiserver.j2
echo -n "old $file: "; grep "^KUBE_API_ADDRESS" $file #"
sed -i '/^KUBE_API_ADDRESS/ s/127.0.0.1/0.0.0.0/' $file
echo -n "new $file: "; grep "^KUBE_API_ADDRESS" $file #"

echo -n "old $file: "; grep "^KUBE_ADMISSION_CONTROL" $file #"
sed -i '/^KUBE_ADMISSION_CONTROL/ s/SecurityContextDeny,//' $file
echo -n "new $file: "; grep "^KUBE_ADMISSION_CONTROL" $file #"

echo "Running install prerequirements playbook..."
ansible-playbook -i $WORKSPACE/ci-factory/utils/central_ci_dynamic_hosts.py ${WORKSPACE}/atomic-ci-jobs/project/playbooks/kube_github_preload/main.yml
err $? "ERROR: kubernetes cluster playbook failed" 1 "error"

# hack tasks/docker/... playbook to install the latest docker from brew
echo "Updating docker task for install latest docker from brew"
cp $WORKSPACE/atomic-ci-jobs/project/playbooks/docker_custom_install/custom-docker-install.ansible roles/docker/tasks/custom-docker-install.yml
sed -i "s/^- include: generic-install.yml/- include: custom-docker-install.yml/" roles/docker/tasks/main.yml

# setup.sh is part of the kubernetes/contrib repository
echo "Running kubernetes playbook..."
INVENTORY=$WORKSPACE/ci-factory/utils/central_ci_dynamic_hosts.py \
ANSIBLE_SSH_ARGS='-o ControlMaster=no' \
    ./setup.sh --extra-vars="workspace=$WORKSPACE"
err $? "ERROR: kubernetes cluster playbook failed" 1 "failure"

# Retrieve the kubeconfig file for use with upcoming e2e run
echo "Retrieve kubeconfig from the master..."
ansible-playbook -i $WORKSPACE/ci-factory/utils/central_ci_dynamic_hosts.py ${WORKSPACE}/atomic-ci-jobs/project/playbooks/kube_github_preload/kubeconfig.yml --extra-vars="workspace=$WORKSPACE"
# no kubeconfig => no e2e tests
err $? "ERROR: kubernetes cluster playbook failed" 1 "error"

# Go back to original working directory
popd

echo "--------------------------------------------------------------------------------"





echo "--------------------------------------------------------------------------------"
echo "Executing e2e:"

# NOTE: Using a whitelist rather than blacklist to avoid having unknown tests execute on our infrastructure.
# See https://trello.com/c/eOeH4KGq/18-5-integrate-the-red-hat-stack-into-the-upstream-kubernetes-github-workflow
# Testing with secrets and dns from the above list
export NETWORKING_E2E=".*Internet\sconnection\sfor\scontainers.*|.*static\sURL\spaths\sfor\skubernetes\sapi.*|.*function\sfor intra-pod\scommunication.*|new\sfiles\sshould\sbe\screated\swith\sFSGroup.*|volume\son\sdefault\smedium\sshould\shave\sthe\scorrect\smode.*|volume\son\stmpfs\sshould\shave\sthe\scorrect\smode.*|should \ssupport\s\(root.*|should \ssupport\s\(non-root.*"
export KUBECTL_E2E="should\screate\sand\sstop\sa.*|should\sscale\sa\sreplication\scontroller.*|should\sdo\sa\srolling\supdate\sof\sa\sreplication.*|should\ssupport\sexec.*|should\ssupport\sinline\sexecution\sand\sattach.*|should\ssupport\sport-forward.*|should\scheck\sif\sv1\sis\sin\savailable.*|should\sapply\sa\snew\sconfiguration\sto\san\sexisting\sRC.*|should\scheck\sif\sKubernetes\smaster\sservices\sis\sincluded.*|should\scheck\sif\skubectl\sdescribe\sprints\srelevant\sinfo.*|should\screate\s.*\sfor\src.*|should\supdate\sthe\slabel\son\sa\sresource.*|should\sbe\sable\sto.*logs.*|should\sadd\sannotations\sfor\spods\sin\src.*|should\scheck\sis\sall\sdata\sis\sprinted.*|should\screate\san\src\sfrom\san\simage.*|should\screate\sa\spod\sfrom\san\simage\swhen.*|should\ssupport\sproxy\swith.*|should\ssupport\s--unix-socket.*"
export PODS_E2E="should\sget\sa\shost\sIP.*|should\sbe\sschedule\swith\scpu\sand\smemory.*|should\sbe\ssubmitted\sand\sremoved.*|should\sbe\supdated.*|should\scontain\senvironment\svariables.*|should.*be\srestarted\swith\sa\s.*|should\sbe\srestarted\swith\sa.*|should\shave\s.*\srestart\scount.*|should\ssupport\sremote\scommand\sexecution\sover\swebsockets|should\ssupport\sretrieving\slogs.*websockets|should\shave\stheir\sauto-restart\sback-off|should\snot\sback-off\srestarting|should\scap\sback-off\sa\sMaxContainerBackOff|should\ssupport\sremote\scommand\sexecution|should\ssupport\sport\sforwarding"
export SERVICEACCOUNTS_E2E="should\smount\san\sAPI\stoken\sinto\spods.*"
export VOLUMES_E2E="should\sbe\smountable"
export PERSISTENTVOLUME_E2E="PersistentVolume"
export E2E_FOCUS="should\sbe\sconsumable\sfrom\spods.*|should\sprovid\DNS\for.*"

export SKIPPED_E2E="should create and scale hazelcast|should set initial resources based on historical data"

export EMPTY_DIR_E2E="new files should be created with FSGroup ownership when container is non-root|new files should be created with FSGroup ownership when container is root|should support \(non-root,0644,default\)|should support \(non-root,0644,tmpfs\)|should support \(non-root,0666,default\)|should support \(non-root,0666,tmpfs\)|should support \(non-root,0777,tmpfs\)|should support \(root,0644,tmpfs\)|should support \(root,0666,default\)|should support \(root,0666,tmpfs\)|should support \(root,0777,default\)|should support \(root,0777,tmpfs\)|volume on default medium should have the correct mode|volume on default medium should have the correct mode using FSGroup|volume on tmpfs should have the correct mode|volume on tmpfs should have the correct mode using FSGroup"

# Naming plural even though ansible scripts support only one master.
# Use the first master ip
export FIRST_MASTER_IP=`echo $CLUSTER_IP_MASTERS | cut -d, -f1`
export PATH=bin/linux/amd64:${PATH}

# Run e2e from the slave against the master
pushd kubernetes/_output/local
$WORKSPACE/kubernetes/_output/local/go/bin/e2e.test -host="https://$FIRST_MASTER_IP:6443" -provider="local" -ginkgo.v=true -ginkgo.focus="Conformance" -alsologtostderr -kubeconfig="$WORKSPACE/kubeconfig" -report-dir="$WORKSPACE/artifacts"




err $? "ERROR: e2e test returned non zero\nSTATUS: $?" 0 "failure"
popd

echo "--------------------------------------------------------------------------------"





echo "--------------------------------------------------------------------------------"
echo "Collecting logs:"

# Get build.log
echo "Retrieving build.log:"
wget $BUILD_URL/consoleText -O $WORKSPACE/build.log

# Get logs from master and nodes (all logs fetched to $WORKSPACE/artifact directory
echo "Retrieving logs from master and nodes:"
ansible-playbook -i $WORKSPACE/ci-factory/utils/central_ci_dynamic_hosts.py ${WORKSPACE}/atomic-ci-jobs/project/playbooks/kube_github_preload/collect-logs.yml --extra-vars="workspace=$WORKSPACE"

echo "--------------------------------------------------------------------------------"

exit $ERROR
