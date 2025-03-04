#!/bin/bash

ensure_gum_installed() {
    if ! command -v gum &>/dev/null; then
        sudo mkdir -p /etc/apt/keyrings
        curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/charm.gpg
        echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | sudo tee /etc/apt/sources.list.d/charm.list
        sudo apt update && sudo apt install gum
    fi
}

ensure_dependancies_installed() {
    sudo apt install -y jq nfs-common open-iscsi
}

open_ports() {
  local ports=(
    "22;tcp"
    "80;tcp"
    "443;tcp"
    "2376;tcp"
    "2379;tcp"
    "2380;tcp"
    "6443;tcp"
    "8472;udp"
    "9099;tcp"
    "10250;tcp"
    "10254;tcp"
    "30000:32767;tcp"
    "30000:32767;udp"
  )

  for entry in "${ports[@]}"; do
    IFS=';' read -r port protocol <<< "$entry"
    gum log --structured --level debug "Opening port ${port}/${protocol}"
    sudo iptables -A INPUT -p "$protocol" \
             -m state --state NEW \
             -m "$protocol" --dport "$port" \
             -j ACCEPT
  done

  echo "All iptables rules have been added."
}

install_k8s_tools() {
    sudo snap install kubectl --classic
    sudo snap install k9s
}



mount_disks() {
    local available_disks
    local mount_point
    local i=1
    lsblk
    gum log --structured --level info "Check for unmounted disks which can be used."
    gum log --structured --level info "Select disks to mount."
    available_disks=$(lsblk -nd -o NAME | gum choose --no-limit)

    if [[ -z "$available_disks" ]]; then
        gum log --structured --level info "No disks selected. Continuing."
        return
    fi

    gum log --structured --level debug "Selected Disks: $available_disks"

    for disk in $available_disks; do
        while [[ -d "/mnt/disk$i" ]]; do
            ((i++))
        done
        
        mount_point="/mnt/disk$i"
        sudo mkdir -p "$mount_point"
        sudo chmod 755 "$mount_point"
        
        if ! lsblk -no PARTTYPE "/dev/$disk" | grep -q .; then
            echo "Disk /dev/$disk is not partitioned. Formatting with ext4..."
            sudo mkfs.ext4 -F "/dev/$disk"
        fi
        
        sudo mount "/dev/$disk" "$mount_point"
        gum log --structured --level debug "Mounted /dev/$disk at $mount_point"
        ((i++))
        
    done


    gum log --structured --level info "Mounted Disks:"
    lsblk -o NAME,MOUNTPOINT

    persist_mnt_disks
}

verify_inotify_instances() {
    local current_value
    local target_value=512
    local sysctl_file="/etc/sysctl.conf"
    current_value=$(sysctl -n fs.inotify.max_user_instances)
    if [[ "$current_value" -lt "$target_value" ]]; then
        sudo sysctl -w fs.inotify.max_user_instances=$target_value
        if grep -q "^fs.inotify.max_user_instances=" "$sysctl_file"; then
            sudo sed -i "s/^fs.inotify.max_user_instances=.*/fs.inotify.max_user_instances=$target_value/" "$sysctl_file"
        else
            echo "fs.inotify.max_user_instances=$target_value" | sudo tee -a "$sysctl_file" > /dev/null
        fi
    fi
}

persist_mnt_disks() {
    local mounted_disks
    mounted_disks=$(mount | awk '/\/mnt\/disk[0-9]+/ {print $1, $3}')

    if [[ -z "$mounted_disks" ]]; then
        return
    fi
    local fstab_file="/etc/fstab"
    local backup_file="/etc/fstab.bak"
    sudo cp "$fstab_file" "$backup_file"
    while read -r device mount_point; do
        local uuid
        uuid=$(blkid -s UUID -o value "$device")

        if [[ -z "$uuid" ]]; then
            gum log --structured --level info "Could not retrieve UUID for $device. Skipping..."
            continue
        fi
        if grep -q "UUID=$uuid" "$fstab_file"; then
            gum log --structured --level debug "$mount_point is already in /etc/fstab."
        else
            echo "UUID=$uuid $mount_point ext4 defaults,nofail 0 2" | sudo tee -a "$fstab_file" > /dev/null
            gum log --structured --level debug "Added $mount_point to /etc/fstab."
        fi
    done <<< "$mounted_disks"
    sudo mount -a
}

count_rocm_devices() {
    rocm-smi -i --json | jq -r '.[] | .["Device Name"]' | sort | uniq -c || {
        echo "Error: Failed to execute rocm-smi" >&2
        exit 1
    }
}

rocm_installed() {
    if ! command -v rocm-smi &>/dev/null; then
        gum log "warning: rocm-smi not found" >&2
        UBUNTU_CODENAME=$(grep VERSION_CODENAME /etc/os-release | cut -d= -f2)
        sudo apt update
        sudo apt install "linux-headers-$(uname -r)" "linux-modules-extra-$(uname -r)"
        sudo apt install python3-setuptools python3-wheel
        wget https://repo.radeon.com/amdgpu-install/6.3.2/$UBUNTU_CODENAME/jammy/amdgpu-install_6.3.60302-1_all.deb
        sudo apt install ./amdgpu-install_6.3.60302-1_all.deb
        sudo apt update
        sudo amdgpu-install --usecase=rocm,dkms
    fi
    cat /opt/rocm/.info/version
}


setup_rocm() {
    rocm_installed
}

setup_rke2_first() {
  RKE2_SERVER_URL="https://get.rke2.io"
  RKE2_CONFIG_PATH="/etc/rancher/rke2/config.yaml"
  modprobe iscsi_tcp
  modprobe dm_mod
  /usr/local/bin/rke2-uninstall.sh || true
  mkdir -p /etc/rancher/rke2
  chmod 0755 /etc/rancher/rke2
  curl -sfL $RKE2_SERVER_URL | sh -
  systemctl enable rke2-server.service
  systemctl start rke2-server.service
}

wait_for_api_server() {
    gum log --structured --level info "Waiting for Kubernetes API server to be ready..."
    local max_attempts=30
    local attempt=1
    
    while ! KUBECONFIG=$HOME/.kube/config kubectl get --raw "/healthz" &>/dev/null; do
        if [ $attempt -ge $max_attempts ]; then
            gum log --structured --level error "Timeout waiting for API server to become ready"
            exit 1
        fi
        gum log --structured --level debug "Waiting for API server (attempt $attempt/$max_attempts)..."
        sleep 10
        ((attempt++))
    done
    
    gum log --structured --level info "Kubernetes API server is ready"
}

setup_rke2_additional() {
  RKE2_SERVER_URL="https://get.rke2.io"
  RKE2_CONFIG_PATH="/etc/rancher/rke2/config.yaml"
  SERVER_IP=$(gum input --placeholder "Enter the RKE2 server IP" --value "192.168.x.x")
  JOIN_TOKEN=$(gum input --password --placeholder "Enter the RKE2 join token")
  mkdir -p /etc/rancher/rke2 && chmod 0755 /etc/rancher/rke2
  cat > $RKE2_CONFIG_PATH <<EOF
server: https://$SERVER_IP:9345
token: $JOIN_TOKEN
EOF
  modprobe iscsi_tcp
  modprobe dm_mod
  /usr/local/bin/rke2-uninstall.sh || true
  curl -sfL $RKE2_SERVER_URL | INSTALL_RKE2_TYPE="agent" sh -
  systemctl enable rke2-agent.service
  systemctl start rke2-agent.service
}


select_mounted_disks() {
    local disks=($(mount | grep -oP '/mnt/disk\d+'))
    [[ ${#disks[@]} -eq 0 ]] && echo "No /mnt/disk{x} drives found." >&2 && return 1
    gum log --structured --level info 'Select which mounts should be auto-configured into kubernetes storage.'
    gum log --structured --level info 'Practically this means they will be longhorn volumes available in the storage classes.'
    mapfile -t selected_disks < <(printf "%s\n" "${disks[@]}" | gum choose --no-limit)
    [[ ${#selected_disks[@]} -eq 0 ]] && echo "No disks selected." >&2 && return 1
    echo "${selected_disks[@]}"
}


generate_longhorn_disk_string() {
    local selected_disks=($(select_mounted_disks))
    [[ ${#selected_disks[@]} -eq 0 ]] && echo "No disks provided." >&2 && return 1

    local json="["
    for disk in "${selected_disks[@]}"; do
        json+="{\\\"path\\\":\\\"$disk\\\",\\\"allowScheduling\\\":true},"
    done
    json="${json%,}]"
    if [[ "$NODE_TYPE" == "First" ]]; then
    KUBECONFIG=/etc/rancher/rke2/rke2.yaml kubectl patch node $HOSTNAME --type='merge' -p "{\"metadata\": {\"labels\": {\"node.longhorn.io/create-default-disk\": \"config\", \"node.longhorn.io/instance-manager\": \"true\"}, \"annotations\": {\"node.longhorn.io/default-disks-config\": \"${json}\"}}}"
    else
    gum log --structured --level info 'This command must be run on controller node!'
    echo KUBECONFIG=/etc/rancher/rke2/rke2.yaml kubectl patch node $HOSTNAME --type='merge' -p "{\"metadata\": {\"labels\": {\"node.longhorn.io/create-default-disk\": \"config\", \"node.longhorn.io/instance-manager\": \"true\"}, \"annotations\": {\"node.longhorn.io/default-disks-config\": \"${json}\"}}}"

    fi
}

main() {
    ensure_gum_installed
    [[ -n "$SERVER_IP" && -n "$JOIN_TOKEN" ]] && NODE_TYPE="additional" || NODE_TYPE="First"
    gum log --structured --level info "Setting up server..."
    ensure_dependancies_installed
    open_ports
    install_k8s_tools
    verify_inotify_instances
    rocmversion=$(rocm_installed)
    gum log --structured --level info "ROCm version: $rocmversion"
    gpucount=$(count_rocm_devices)
    gum log --structured --level debug "GPU count: $gpucount"
    if [[ "$NODE_TYPE" == "First" ]]; then
        gum log --structured --level info "Configuring as the first node..."
        setup_rke2_first
    else
        gum log --structured --level info "Configuring as an additional node..."
        setup_rke2_additional
    fi
    mount_disks
    generate_longhorn_disk_string
    if [[ "$NODE_TYPE" == "First" ]]; then
        KUBECONFIG=/etc/rancher/rke2/rke2.yaml kubectl apply -f longhorn/namespace.yaml
        KUBECONFIG=/etc/rancher/rke2/rke2.yaml kubectl apply -f longhorn/longhorn.yaml
        cd cluster*
        cd "$(ls --color=never -d */ | head -n 1)"
        gum log --structured --level info 'Kubernetes has been installed and configured' 
        gum log --structured --level info 'Now ClusterForge will install the stack to enable running workloads'
        echo ---
        MAIN_IP=$(ip route get 1.1.1.1 | awk '{print $7; exit}')
        sudo sed "s/127\.0\.0\.1/$MAIN_IP/g" /etc/rancher/rke2/rke2.yaml
        echo ---
        mkdir -p $HOME/.kube
        sudo sed "s/127\.0\.0\.1/$MAIN_IP/g" /etc/rancher/rke2/rke2.yaml | tee $HOME/.kube/config
        chmod 600 $HOME/.kube/config
		sudo sed -i "s/{{CONTROL_IP}}/$MAIN_IP/g" ingress/ingress.yaml
		KUBECONFIG=/etc/rancher/rke2/rke2.yaml kubectl apply -f ingress/ingress.yaml
        wait_for_api_server 
        KUBECONFIG=$HOME/.kube/config && bash deploy.sh
        gum log --structured --level info 'ClusterForge installed'
        
        gum log --structured --level info 'Here is the KUBECONFIG file.' 
        gum log --structured --level info 'For reference it was taken from /etc/rancher/rke2/rke2.yaml and IP changed from 127.0.0.1 the servers IP.'
        gum log --structured --level info 'To setup additional nodes to join the cluster, run the following:' 
        echo ---
        TOKEN=$(< /var/lib/rancher/rke2/server/node-token)
        echo "export TOKEN=$TOKEN; export SERVER_IP=$MAIN_IP; curl https://silogen.github.io/cluster-forge/deploy.sh | sudo bash"
        echo ---
    fi
    gum log --structured --level info "Server setup successfully!"

}

main
