#!/bin/bash
set -uo pipefail
setenforce 1

# Fix sudo require tty
grep -q "# Defaults    requiretty" /etc/sudoers
if [ $? -ne 0 ] ; then
  sed -i 's/Defaults    requiretty/# Defaults    requiretty/' /etc/sudoers
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
               python-setuptools libffi-devel docker etcd

# Install gsutil through pip (for e2e tests)
pip install gsutil

# start docker
systemctl start docker

# Set GOPATH
mkdir go
export GOPATH=`pwd`/go
mkdir -p $GOPATH/src/k8s.io
mv kubernetes $GOPATH/src/k8s.io/


echo "--------------------------------------------------------------------------------"
echo "Building and testing kubernetes from hack directory:"

pushd $GOPATH/src/k8s.io/kubernetes

# Set the KUBE_GIT_VERSION
#export KUBE_GIT_VERSION=$(git describe --match "v*")
#echo "Setting KUBE_GIT_VERSION to $KUBE_GIT_VERSION"

# Install etcd and add it to PATH
#./hack/install-etcd.sh
#export PATH=third_party/etcd:${PATH}

# Then run tests
for cmd in e2e-node-test.sh; do
    echo -e "\n\nRunning hack/$cmd\n"
     make WHAT=vendor/github.com/onsi/ginkgo/ginkgo
    ./hack/$cmd
    err $? "ERROR: Test $cmd failed\nSTATUS: $?" 0 "failure"
done
popd

echo "--------------------------------------------------------------------------------"

exit $ERROR
