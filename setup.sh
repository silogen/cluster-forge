wget https://github.com/silogen/cluster-forge/releases/download/1.0.8-core/release-core-1.0.8.tar.gz
tar xfz release-core-1.0.8.tar.gz
cd clusterforge-core-1.0.8
sudo setup-forge.sh
cd 1.0.6-core
KUBECONFIG=/etc/rancher/rke2/rke2.yaml deploy.sh