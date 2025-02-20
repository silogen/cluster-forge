wget https://github.com/silogen/cluster-forge/releases/download/1.0.8-core/release-core-1.0.8.tar.gz
tar xfz release-core-1.0.8.tar.gz
sudo bash setup-forge.sh
cd clusterforge-core-1.0.8
INFO=$(gum style --padding "1 4" --border double --border-foreground 57 'Kubernetes has been installed and configured' 'Now ClusterForge will install the stack to enable running workloads')
gum join --align center --vertical $INFO
cd 1.0.8-core
KUBECONFIG=/etc/rancher/rke2/rke2.yaml && bash deploy.sh

