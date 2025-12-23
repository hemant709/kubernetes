#!/bin/bash

#!/bin/bash
set -e

# Configuration
KUBE_VERSION="1.27.0"
KIND_VERSION="v0.22.0"
KUBECTL_VERSION="v1.27.0"
CLUSTER_NAME="kind-cluster"

print_header() {
    echo "================================="
    echo "$1"
    echo "================================="
}

print_success() {
    echo "[✓] $1"
}

print_info() {
    echo "[ℹ] $1"
}

print_error() {
    echo "[✗] $1"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

check_system_requirements() {
    print_header "Checking System Requirements"
    
    if [[ "$OSTYPE" != "linux-gnu"* ]] && [[ "$OSTYPE" != "darwin"* ]]; then
        print_error "This script only supports Linux and macOS"
        exit 1
    fi
    
    if ! command_exists docker; then
        print_error "Docker is not installed. Please install Docker first."
        exit 1
    fi
    print_success "Docker is installed"
    
    if ! docker ps >/dev/null 2>&1; then
        print_error "Docker daemon is not running. Please start Docker."
        exit 1
    fi
    print_success "Docker daemon is running"
    
    if ! ping -c 1 8.8.8.8 >/dev/null 2>&1; then
        print_info "No internet connectivity detected. Some downloads may fail."
    else
        print_success "Internet connectivity confirmed"
    fi
}

install_kind() {
    print_header "Installing Kind"
    
    if command_exists kind; then
        INSTALLED_KIND_VERSION=$(kind version 2>/dev/null | cut -d' ' -f2)
        print_info "Kind is already installed (version: $INSTALLED_KIND_VERSION)"
        return 0
    fi
    
    print_info "Downloading Kind $KIND_VERSION..."
    
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        OS="linux"
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        OS="darwin"
    fi
    
    ARCH=$(uname -m)
    if [[ "$ARCH" == "x86_64" ]]; then
        ARCH="amd64"
    elif [[ "$ARCH" == "aarch64" ]]; then
        ARCH="arm64"
    fi
    
    KIND_URL="https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-${OS}-${ARCH}"
    
    if ! curl -sSL "$KIND_URL" -o /tmp/kind; then
        print_error "Failed to download Kind"
        exit 1
    fi
    
    chmod +x /tmp/kind
    
    if [[ -w /usr/local/bin ]]; then
        sudo mv /tmp/kind /usr/local/bin/kind
    else
        mkdir -p ~/.local/bin
        mv /tmp/kind ~/.local/bin/kind
        if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
            export PATH="$HOME/.local/bin:$PATH"
            echo "export PATH=\"\$HOME/.local/bin:\$PATH\"" >> ~/.bashrc
        fi
    fi
    
    print_success "Kind installed successfully ($(kind version))"
}

install_kubectl() {
    print_header "Installing Kubectl"
    
    if command_exists kubectl; then
        INSTALLED_KUBECTL_VERSION=$(kubectl version --client --short 2>/dev/null | grep 'Client' | awk '{print $3}')
        print_info "Kubectl is already installed (version: $INSTALLED_KUBECTL_VERSION)"
        return 0
    fi
    
    print_info "Downloading Kubectl $KUBECTL_VERSION..."
    
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        OS="linux"
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        OS="darwin"
    fi
    
    ARCH=$(uname -m)
    if [[ "$ARCH" == "x86_64" ]]; then
        ARCH="amd64"
    elif [[ "$ARCH" == "aarch64" ]]; then
        ARCH="arm64"
    fi
    
    KUBECTL_URL="https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/${OS}/${ARCH}/kubectl"
    
    if ! curl -sSL "$KUBECTL_URL" -o /tmp/kubectl; then
        print_error "Failed to download Kubectl"
        exit 1
    fi
    
    chmod +x /tmp/kubectl
    
    if [[ -w /usr/local/bin ]]; then
        sudo mv /tmp/kubectl /usr/local/bin/kubectl
    else
        mkdir -p ~/.local/bin
        mv /tmp/kubectl ~/.local/bin/kubectl
        if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
            export PATH="$HOME/.local/bin:$PATH"
            echo "export PATH=\"\$HOME/.local/bin:\$PATH\"" >> ~/.bashrc
        fi
    fi
    
    print_success "Kubectl installed successfully ($(kubectl version --client --short 2>/dev/null))"
}

setup_permissions() {
    print_header "Setting Up Permissions"
    
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        if ! groups "$USER" | grep -q docker; then
            print_info "Adding $USER to docker group..."
            sudo usermod -aG docker "$USER"
            print_info "You may need to log out and log back in for group changes to take effect"
            print_info "Alternatively, run: newgrp docker"
        else
            print_info "User is already in docker group"
        fi
    fi
    
    mkdir -p ~/.kube
    chmod 700 ~/.kube
    print_success "Permissions configured"
}

create_kind_cluster() {
    print_header "Creating Kind Cluster"
    
    if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
        print_info "Cluster '$CLUSTER_NAME' already exists"
        read -p "Do you want to delete and recreate it? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            print_info "Deleting existing cluster..."
            kind delete cluster --name "$CLUSTER_NAME"
        else
            print_info "Skipping cluster creation"
            return 0
        fi
    fi
    
    print_info "Creating kind cluster configuration..."
    
    cat > /tmp/kind-config.yaml <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${CLUSTER_NAME}
nodes:
  - role: control-plane
    image: kindest/node:v${KUBE_VERSION}
  - role: worker
    image: kindest/node:v${KUBE_VERSION}
EOF
    
    print_info "Creating cluster with 1 control plane and 1 worker node..."
    print_info "This may take a few minutes..."
    
    if kind create cluster --config /tmp/kind-config.yaml; then
        print_success "Cluster created successfully"
    else
        print_error "Failed to create cluster"
        rm /tmp/kind-config.yaml
        exit 1
    fi
    
    rm /tmp/kind-config.yaml
    
    print_info "Verifying cluster..."
    if kubectl cluster-info; then
        print_success "Cluster is accessible"
    else
        print_error "Failed to verify cluster"
        exit 1
    fi
}

display_cluster_info() {
    print_header "Cluster Information"
    
    print_info "Cluster Name: $CLUSTER_NAME"
    print_info "Kubernetes Version: $KUBE_VERSION"
    
    echo ""
    echo "Nodes:"
    kubectl get nodes -o wide
    
    echo ""
    echo "Cluster Info:"
    kubectl cluster-info
    
    echo ""
    echo "Setup Complete!"
    echo "You can interact with your cluster using: kubectl"
    echo "To view all commands: kubectl --help"
    echo "To load local images: kind load docker-image <IMAGE_NAME> --name ${CLUSTER_NAME}"
}

main() {
    print_header "Kind Cluster Setup Script"
    print_info "This script will install kind, kubectl, and create a Kubernetes cluster"
    echo ""
    
    check_system_requirements
    echo ""
    
    install_kind
    echo ""
    
    install_kubectl
    echo ""
    
    setup_permissions
    echo ""
    
    create_kind_cluster
    echo ""
    
    display_cluster_info
}

main "$@"
