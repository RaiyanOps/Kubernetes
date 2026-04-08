#!/bin/bash
set -e

# Function to wait for apt lock
wait_for_apt() {
    while sudo fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || \
          sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
          sudo fuser /var/lib/dpkg/lock >/dev/null 2>&1; do
        echo "Waiting for other apt processes to finish..."
        sleep 2
    done
}

echo "==== Updating system ===="
wait_for_apt
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl apt-transport-https ca-certificates gnupg lsb-release

echo "==== Disabling swap ===="
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab

echo "==== Installing containerd 2.2.0 ===="
# Remove any existing containerd
wait_for_apt
sudo apt remove -y containerd || true

# Download and install containerd 2.2.0
wget https://github.com/containerd/containerd/releases/download/v2.2.0/containerd-2.2.0-linux-amd64.tar.gz
sudo tar Cxzvf /usr/local containerd-2.2.0-linux-amd64.tar.gz
rm containerd-2.2.0-linux-amd64.tar.gz

# Download and install runc
wget https://github.com/opencontainers/runc/releases/download/v1.2.3/runc.amd64
sudo install -m 755 runc.amd64 /usr/local/sbin/runc
rm runc.amd64

# Download and install CNI plugins (using v1.5.0)
wget https://github.com/containernetworking/plugins/releases/download/v1.5.0/cni-plugins-linux-amd64-v1.5.0.tgz
sudo mkdir -p /opt/cni/bin
sudo tar Cxzvf /opt/cni/bin cni-plugins-linux-amd64-v1.5.0.tgz
rm cni-plugins-linux-amd64-v1.5.0.tgz

# Create containerd systemd service
sudo mkdir -p /usr/local/lib/systemd/system
sudo tee /usr/local/lib/systemd/system/containerd.service > /dev/null <<EOF
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target local-fs.target

[Service]
ExecStartPre=-/sbin/modprobe overlay
ExecStart=/usr/local/bin/containerd
Type=notify
Delegate=yes
KillMode=process
Restart=always
RestartSec=5
LimitNPROC=infinity
LimitCORE=infinity
LimitNOFILE=infinity
TasksMax=infinity
OOMScoreAdjust=-999

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable containerd --now

sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml >/dev/null

echo "==== Enabling SystemdCgroup ===="
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

echo "==== Adding private registry mirror ===="
sudo sed -i '/\[plugins."io.containerd.grpc.v1.cri".registry\]/a \
  [plugins."io.containerd.grpc.v1.cri".registry.mirrors."10.0.0.219:5000"]\n    endpoint = ["http://10.0.0.219:5000"]' /etc/containerd/config.toml

sudo sed -i '/\[plugins."io.containerd.grpc.v1.cri".registry\]/a \
  [plugins."io.containerd.grpc.v1.cri".registry.mirrors."192.168.2.243:5000"]\n    endpoint = ["http://192.168.2.243:5000"]' /etc/containerd/config.toml

sudo systemctl restart containerd

echo "==== Adding Kubernetes apt repo for v1.31 ===="
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | \
  sudo gpg --dearmor -o /usr/share/keyrings/kubernetes-archive-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /" | \
  sudo tee /etc/apt/sources.list.d/kubernetes.list

echo "==== Waiting for apt lock before updating ===="
wait_for_apt
sudo apt update

echo "==== Installing Kubernetes 1.31.7 binaries ===="
wait_for_apt
sudo apt install -y kubelet=1.31.7-1.1 kubeadm=1.31.7-1.1 kubectl=1.31.7-1.1
sudo apt-mark hold kubelet kubeadm kubectl

echo "==== Enabling IPv4 forwarding ===="
sudo sysctl -w net.ipv4.ip_forward=1
sudo tee /etc/sysctl.d/k8s.conf <<EOF
net.ipv4.ip_forward = 1
EOF

sudo sysctl --system

echo "==== Initializing Kubernetes cluster ===="
sudo kubeadm init \
  --pod-network-cidr=10.244.0.0/16 \
  --cri-socket unix:///run/containerd/containerd.sock

echo "==== Setting up kubeconfig ===="
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

echo "==== Installing Calico CNI ===="
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.26.0/manifests/calico.yaml

echo "==== Removing control-plane taint ===="
kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true

echo "==== Current held packages ===="
apt-mark showhold

echo "==== Kubernetes master setup completed successfully ===="
sleep 10
kubectl get nodes 
sleep 30 
kubectl get pods -A
echo "Single node Kubernetes cluster is up and running!"
