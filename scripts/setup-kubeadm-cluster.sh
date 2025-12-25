#!/usr/bin/env bash
set -euo pipefail

# setup-kubeadm-cluster.sh
# -----------------------
# Creates EC2 instances and bootstraps a Kubernetes cluster using kubeadm.
#
# Prerequisites:
# - AWS CLI v2 installed and configured with credentials that can create EC2/Security Groups/Tags.
#   (https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
# - jq installed locally (https://stedolan.github.io/jq/)
# - An existing EC2 Key Pair in the target region (name provided with -k) and the corresponding
#   private key (.pem) available locally for SSH access.
# - Your account must have a default VPC and subnet with Internet access, or provide a subnet id.
# - Recommended AMI: Ubuntu 22.04/24.04 LTS AMI in your region and matching SSH user (default: ubuntu).
# - Ports allowed in Security Group: 22 (SSH), 6443 (kube-apiserver), 2379-2380 (etcd), 10250-10252 (kubelet & controllers), 30000-32767 (NodePort range)
#
# Usage:
#   chmod +x scripts/setup-kubeadm-cluster.sh
#   ./scripts/setup-kubeadm-cluster.sh -n 3 -k MyKeyPair -p ~/.ssh/MyKeyPair.pem -i ami-0abcdef1234567890 -r us-east-1
#
# Flags:
#   -n N             Number of total nodes (1 => one control-plane only) [default: 3]
#   -k KEY_NAME      Existing EC2 KeyPair name to attach to instances (required)
#   -p PEM_PATH      Path to the private key for SSH access (required)
#   -i AMI_ID        AMI ID to use for instances (required)
#   -t INSTANCE_TYPE EC2 instance type [default: t3.medium]
#   -r REGION        AWS region [default: us-east-1]
#   -u SSH_USER      SSH user for the AMI (default: ubuntu)
#   -s SUBNET_ID     (optional) Subnet ID to launch instances in (default: default subnet)
#   -g SG_ID         (optional) Reuse an existing Security Group ID instead of creating a new one
#   -c CLUSTER_NAME  Cluster name tag prefix [default: kubeadm-cluster]
#   -y               Auto-approve (no interactive confirmation)
#
# Notes:


NUM_NODES=3
KEY_NAME=""kubeadm-key-1766669309""
PEM_PATH="keys/${KEY_NAME}.pem"
AMI_ID="ami-0030e4319cbf4dbf2"
INSTANCE_TYPE="t3.medium"
REGION="us-east-1"
SSH_USER="ubuntu"
SUBNET_ID=""
SG_ID=""
CLUSTER_NAME="kubeadm-cluster"
AUTO_APPROVE=0

usage() {
  sed -n '1,120p' "$0" | sed -n '1,70p'
}

while getopts ":n:k:p:i:t:r:u:s:g:c:hy" opt; do
  case $opt in
    n) NUM_NODES="$OPTARG" ;;
    k) KEY_NAME="$OPTARG" ;;
    p) PEM_PATH="$OPTARG" ;;
    i) AMI_ID="$OPTARG" ;;
    t) INSTANCE_TYPE="$OPTARG" ;;
    r) REGION="$OPTARG" ;;
    u) SSH_USER="$OPTARG" ;;
    s) SUBNET_ID="$OPTARG" ;;
    g) SG_ID="$OPTARG" ;;
    c) CLUSTER_NAME="$OPTARG" ;;
    h) usage; exit 0 ;;
    y) AUTO_APPROVE=1 ;;
    \?) echo "Invalid option: -$OPTARG" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$KEY_NAME" || -z "$PEM_PATH" || -z "$AMI_ID" ]]; then
  echo "ERROR: -k (KeyPair name), -p (path to PEM) and -i (AMI ID) are required." >&2
  usage
  exit 1
fi

if ! command -v aws >/dev/null 2>&1; then
  echo "ERROR: aws CLI not found. Install and configure AWS CLI before running." >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq not found. Install jq (e.g., apt install -y jq)." >&2
  exit 1
fi

if [[ ! -f "$PEM_PATH" ]]; then
  echo "ERROR: PEM file not found at $PEM_PATH" >&2
  exit 1
fi

if ! [[ "$NUM_NODES" =~ ^[0-9]+$ ]] || [[ "$NUM_NODES" -lt 1 ]]; then
  echo "ERROR: -n must be an integer >= 1" >&2
  exit 1
fi

read -r -p "About to create $NUM_NODES node(s) in $REGION using AMI $AMI_ID. Continue? [y/N] " answer
if [[ $AUTO_APPROVE -eq 1 ]]; then
  answer=y
fi

if [[ "${answer,,}" != "y" && "${answer,,}" != "yes" ]]; then
  echo "Aborted by user."
  exit 0
fi

export AWS_DEFAULT_REGION="$REGION"

# Helper: determine default VPC's default subnet if none supplied
if [[ -z "$SUBNET_ID" ]]; then
  SUBNET_ID=$(aws ec2 describe-subnets --filters "Name=defaultForAz,Values=true" --query 'Subnets[0].SubnetId' --output text || true)
  if [[ -z "$SUBNET_ID" || "$SUBNET_ID" == "None" ]]; then
    # fallback to first subnet of default vpc
    DEFAULT_VPC=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text || true)
    if [[ -n "$DEFAULT_VPC" && "$DEFAULT_VPC" != "None" ]]; then
      SUBNET_ID=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$DEFAULT_VPC" --query 'Subnets[0].SubnetId' --output text)
    fi
  fi
  if [[ -z "$SUBNET_ID" || "$SUBNET_ID" == "None" ]]; then
    echo "ERROR: Could not determine a subnet. Please provide -s SUBNET_ID." >&2
    exit 1
  fi
  echo "Using subnet: $SUBNET_ID"
fi

# Create security group if none supplied
if [[ -z "$SG_ID" ]]; then
  SG_NAME="${CLUSTER_NAME}-sg-$(date +%s)"
  echo "Creating security group $SG_NAME..."
  SG_ID=$(aws ec2 create-security-group --group-name "$SG_NAME" --description "Security group for $CLUSTER_NAME" --vpc-id "$(aws ec2 describe-subnets --subnet-ids $SUBNET_ID --query 'Subnets[0].VpcId' --output text)" --query 'GroupId' --output text)
  echo "Created SG: $SG_ID"
  echo "Authorizing ingress rules..."
  aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 22 --cidr 0.0.0.0/0
  aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 6443 --cidr 0.0.0.0/0
  aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 2379-2380 --cidr 0.0.0.0/0
  aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 10250-10252 --cidr 0.0.0.0/0
  aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 30000-32767 --cidr 0.0.0.0/0
else
  echo "Reusing provided Security Group: $SG_ID"
fi

# Launch instances: 1 master + (NUM_NODES-1) workers
MASTER_COUNT=1
WORKER_COUNT=$((NUM_NODES - MASTER_COUNT))

echo "Launching EC2 instances..."
MASTER_NAME="${CLUSTER_NAME}-master"
WORKER_NAME_PREFIX="${CLUSTER_NAME}-worker"

# Launch master
MASTER_INSTANCE_ID=$(aws ec2 run-instances --image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE" --count 1 --key-name "$KEY_NAME" --security-group-ids "$SG_ID" --subnet-id "$SUBNET_ID" --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$MASTER_NAME},{Key=Cluster,Value=$CLUSTER_NAME},{Key=Role,Value=master}]" --query 'Instances[0].InstanceId' --output text)

if [[ $WORKER_COUNT -gt 0 ]]; then
  WORKER_INSTANCE_IDS=$(aws ec2 run-instances --image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE" --count $WORKER_COUNT --key-name "$KEY_NAME" --security-group-ids "$SG_ID" --subnet-id "$SUBNET_ID" --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$WORKER_NAME_PREFIX},{Key=Cluster,Value=$CLUSTER_NAME},{Key=Role,Value=worker}]" --query 'Instances[*].InstanceId' --output text)
else
  WORKER_INSTANCE_IDS=""
fi

echo "Master Instance ID: $MASTER_INSTANCE_ID"
echo "Worker Instance IDs: $WORKER_INSTANCE_IDS"

echo "Waiting for instances to be in 'running' state..."
ALL_IDS="$MASTER_INSTANCE_ID $WORKER_INSTANCE_IDS"
aws ec2 wait instance-running --instance-ids $ALL_IDS

# Fetch public IPs and private IPs
MASTER_PUBLIC_IP=$(aws ec2 describe-instances --instance-ids $MASTER_INSTANCE_ID --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
MASTER_PRIVATE_IP=$(aws ec2 describe-instances --instance-ids $MASTER_INSTANCE_ID --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)

WORKER_PUBLIC_IPS=""
WORKER_PRIVATE_IPS=""
if [[ -n "$WORKER_INSTANCE_IDS" ]]; then
  for id in $WORKER_INSTANCE_IDS; do
    ip_pub=$(aws ec2 describe-instances --instance-ids $id --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
    ip_priv=$(aws ec2 describe-instances --instance-ids $id --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)
    WORKER_PUBLIC_IPS+="$ip_pub "
    WORKER_PRIVATE_IPS+="$ip_priv "
  done
fi

echo "Master public IP: $MASTER_PUBLIC_IP (private: $MASTER_PRIVATE_IP)"
if [[ -n "$WORKER_PUBLIC_IPS" ]]; then
  echo "Worker public IPs: $WORKER_PUBLIC_IPS"
fi

# Wait for SSH to become available
wait_for_ssh() {
  local ip=$1
  local -i tries=0
  echo -n "Waiting for SSH on $ip "
  until ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no -i "$PEM_PATH" "$SSH_USER@$ip" "echo 2>&1" >/dev/null; do
    tries=$((tries+1))
    if [[ $tries -gt 60 ]]; then
      echo "\nERROR: SSH to $ip failed after several tries." >&2
      return 1
    fi
    echo -n '.'
    sleep 5
  done
  echo " OK"
}

wait_for_ssh "$MASTER_PUBLIC_IP"
for ip in $WORKER_PUBLIC_IPS; do
  wait_for_ssh "$ip"
done

# remote bootstrap: install containerd, kubeadm, kubelet, kubectl and prepare node
remote_prepare_node() {
  local ip=$1
  echo "Preparing node $ip"
  ssh -o StrictHostKeyChecking=no -i "$PEM_PATH" "$SSH_USER@$ip" "sudo bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release

# Install containerd
sudo apt-get install -y containerd
sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml
sudo systemctl restart containerd

# sysctl
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
sudo sysctl --system

# disable swap
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab || true

# Add Kubernetes apt repo
sudo curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo gpg --dearmor -o /usr/share/keyrings/kubernetes-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://apt.kubernetes.io/ kubernetes-xenial main" | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

# ensure kubelet not running kubeadm yet
sudo systemctl enable --now kubelet || true
REMOTE
}

# prepare master and workers
remote_prepare_node "$MASTER_PUBLIC_IP"
for ip in $WORKER_PUBLIC_IPS; do
  remote_prepare_node "$ip"
done

# Initialize control plane on master
echo "Initializing control plane on master ($MASTER_PUBLIC_IP)..."
ssh -o StrictHostKeyChecking=no -i "$PEM_PATH" "$SSH_USER@$MASTER_PUBLIC_IP" "sudo kubeadm init --pod-network-cidr=10.244.0.0/16 --apiserver-advertise-address=$MASTER_PRIVATE_IP --ignore-preflight-errors=Swap" || {
  echo "ERROR: kubeadm init failed on master" >&2
  exit 1
}

# Set kubeconfig for ubuntu user on master
ssh -i "$PEM_PATH" -o StrictHostKeyChecking=no "$SSH_USER@$MASTER_PUBLIC_IP" "mkdir -p ~/.kube && sudo cp -i /etc/kubernetes/admin.conf ~/.kube/config && sudo chown \\$(id -u):\\$(id -g) ~/.kube/config"

# Install Flannel CNI
echo "Installing Flannel CNI..."
ssh -i "$PEM_PATH" -o StrictHostKeyChecking=no "$SSH_USER@$MASTER_PUBLIC_IP" "kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml"

# Get join command
JOIN_CMD=$(ssh -i "$PEM_PATH" -o StrictHostKeyChecking=no "$SSH_USER@$MASTER_PUBLIC_IP" "sudo kubeadm token create --print-join-command")
if [[ -z "$JOIN_CMD" ]]; then
  echo "ERROR: Could not obtain join command from master" >&2
  exit 1
fi

echo "Worker join command: $JOIN_CMD"

# Run join on workers
for ip in $WORKER_PUBLIC_IPS; do
  echo "Joining worker $ip to cluster..."
  ssh -o StrictHostKeyChecking=no -i "$PEM_PATH" "$SSH_USER@$ip" "sudo $JOIN_CMD" || {
    echo "ERROR: Worker $ip failed to join" >&2
  }
done

# Summary
echo "---"
echo "Setup complete. Master: $MASTER_PUBLIC_IP"
echo "To interact with the cluster from your workstation run:" 
echo "  scp -i $PEM_PATH $SSH_USER@$MASTER_PUBLIC_IP:~/.kube/config ./config && export KUBECONFIG=./config && kubectl get nodes"
exit 0
