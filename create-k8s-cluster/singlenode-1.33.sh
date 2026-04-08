#!/bin/bash
set -e

echo "==== Updating system ===="
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl apt-transport-https ca-certificates gnupg lsb-release

echo "==== Disabling swap ===="
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab

echo "==== Installing containerd ===="
sudo apt install -y containerd
sudo systemctl enable containerd --now

sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml >/dev/null

echo "==== Enabling SystemdCgroup ===="
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

echo "==== Adding private registry mirror ===="
sudo sed -i '/\[plugins."io.containerd.grpc.v1.cri".registry\]/a \
  [plugins."io.containerd.grpc.v1.cri".registry.mirrors."10.0.0.219:5000"]\n    endpoint = ["http://10.0.0.219:5000"]' /etc/containerd/config.toml

sed -i '/\[plugins."io.containerd.grpc.v1.cri".registry\]/a \
  [plugins."io.containerd.grpc.v1.cri".registry.mirrors."192.168.2.243:5000"]\n    endpoint = ["http://192.168.2.243:5000"]' /etc/containerd/config.toml

sudo systemctl restart containerd

echo "==== Adding Kubernetes apt repo ===="
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.33/deb/Release.key | \
  sudo gpg --dearmor -o /usr/share/keyrings/kubernetes-archive-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.33/deb/ /" | \
  sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt update

echo "==== Installing Kubernetes binaries ===="
sudo apt install -y kubelet=1.33.5-1.1 kubeadm=1.33.5-1.1 kubectl=1.33.5-1.1
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
  --cri-socket /run/containerd/containerd.sock

echo "==== Setting up kubeconfig ===="
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

echo "==== Installing Calico CNI ===="
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.26.0/manifests/calico.yaml

echo "==== Removing control-plane taint ===="
kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true

echo "==== Reinstalling containerd (hold/unhold cycle) ===="
sudo apt-mark unhold containerd
sudo apt update
sudo apt install -y containerd
sudo apt-mark hold containerd

echo "==== Current held packages ===="
apt-mark showhold

echo "==== Kubernetes master setup completed successfully ===="
sleep 10
kubectl get nodes 
sleep 30 
kubectl get pods -A
echo "Single node Kubernetes cluster is up and running!"
