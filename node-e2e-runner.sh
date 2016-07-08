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

mkdir -p $WORKSPACE/artifacts

echo "--------------------------------------------------------------------------------"
echo "Test Environment:"
# TODO(jchaloup): Filter out some envs with internal IPs and sensitive data
# use whitelist instead?
printenv | sort
echo "--------------------------------------------------------------------------------"


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

# Then run tests
for cmd in e2e-node-test.sh; do
    echo -e "\n\nRunning hack/$cmd\n"
     make WHAT=vendor/github.com/onsi/ginkgo/ginkgo
    ./hack/$cmd
    err $? "ERROR: Test $cmd failed\nSTATUS: $?" 0 "failure"
done
popd

echo "--------------------------------------------------------------------------------"

echo "--------------------------------------------------------------------------------"
echo "Collecting logs:"

# Get build.log
echo "Retrieving build.log:"
wget $BUILD_URL/consoleText -O $WORKSPACE/build.log

echo "Retrieving test logs:"
cp $GOPATH/src/k8s.io/kubernetes/test/e2e_node/*.log $WORKSPACE/artifacts/

echo "--------------------------------------------------------------------------------"

exit $ERROR
