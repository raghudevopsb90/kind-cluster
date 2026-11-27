#!/bin/bash
# Second stage, after prepare.sh and the reboot.
# Installs docker-ce, kind, kubectl, and k9s, then creates a kind cluster.
set -euo pipefail

if [[ -z "${SSH_PASSWORD:-}" ]]; then
  echo "SSH_PASSWORD is required" >&2
  exit 1
fi

KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-kind}"
KIND_VERSION="v0.33.0"
K9S_FALLBACK_VERSION="v0.51.0"

need_sudo() {
  if sudo -n true 2>/dev/null; then
    return 0
  fi
  echo "${SSH_PASSWORD}" | sudo -S -p '' -v
}

need_sudo

if command -v dnf >/dev/null 2>&1; then
  sudo dnf install -y ca-certificates curl tar gzip
else
  sudo yum install -y ca-certificates curl tar gzip
fi

install_docker_ce() {
  local el_version=""

  sudo rpm --import https://download.docker.com/linux/centos/gpg

  if command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y dnf-plugins-core
    if [[ ! -f /etc/yum.repos.d/docker-ce.repo ]]; then
      sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo \
        || sudo dnf config-manager addrepo --from-repofile=https://download.docker.com/linux/centos/docker-ce.repo
    fi
  else
    sudo yum install -y yum-utils
    if [[ ! -f /etc/yum.repos.d/docker-ce.repo ]]; then
      sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    fi
  fi

  # Amazon Linux reports releasever 2 or 2023, which Docker's CentOS repo does not publish.
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "${ID:-}" == "amzn" && -f /etc/yum.repos.d/docker-ce.repo ]]; then
      if [[ "${VERSION_ID:-}" == 2* ]]; then
        el_version="7"
      else
        el_version="9"
      fi
      sudo sed -i "s/\\\$releasever/${el_version}/g" /etc/yum.repos.d/docker-ce.repo
    fi
  fi

  if command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y --allowerasing docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  else
    sudo yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi
}

if ! install_docker_ce; then
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  sudo sh /tmp/get-docker.sh
fi

rpm -q docker-ce

sudo systemctl enable --now docker
sudo usermod -aG docker "$(id -un)"

prepare_kind_host() {
  if ! sudo modprobe -a overlay br_netfilter xt_addrtype; then
    echo "kernel $(uname -r) is missing modules. Run prepare.sh and reboot first." >&2
    exit 1
  fi

  sudo tee /etc/modules-load.d/kind.conf >/dev/null <<'EOF'
overlay
br_netfilter
xt_addrtype
EOF

  {
    echo "net.ipv4.ip_forward = 1"
    echo "fs.inotify.max_user_watches = 524288"
    echo "fs.inotify.max_user_instances = 512"
    if [[ -e /proc/sys/net/bridge/bridge-nf-call-iptables ]]; then
      echo "net.bridge.bridge-nf-call-iptables = 1"
      echo "net.bridge.bridge-nf-call-ip6tables = 1"
    fi
  } | sudo tee /etc/sysctl.d/kind.conf >/dev/null
  sudo sysctl -w net.ipv4.ip_forward=1
  sudo sysctl -w fs.inotify.max_user_watches=524288
  sudo sysctl -w fs.inotify.max_user_instances=512
  if [[ -e /proc/sys/net/bridge/bridge-nf-call-iptables ]]; then
    sudo sysctl -w net.bridge.bridge-nf-call-iptables=1
    sudo sysctl -w net.bridge.bridge-nf-call-ip6tables=1
  fi

  # RHEL firewalld's nftables backend drops Docker bridge traffic that kind needs.
  if systemctl is-active --quiet firewalld; then
    sudo systemctl disable --now firewalld
  fi

  if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" == "Enforcing" ]]; then
    sudo setenforce 0
    sudo sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
  fi

  sudo mkdir -p /etc/docker
  sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "storage-driver": "overlay2",
  "features": {
    "containerd-snapshotter": false
  }
}
EOF
  sudo systemctl restart docker
}

prepare_kind_host

run_with_docker() {
  if docker info >/dev/null 2>&1; then
    bash -c "$1"
  else
    sg docker -c "$1"
  fi
}

for _ in $(seq 1 30); do
  if run_with_docker "docker info" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
run_with_docker "docker info" >/dev/null

case "$(uname -m)" in
  x86_64) arch_alias="amd64" ;;
  aarch64) arch_alias="arm64" ;;
  *)
    echo "unsupported architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

curl -fsSL -o /tmp/kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${arch_alias}"
sudo install -o root -g root -m 0755 /tmp/kind /bin/kind
rm -f /tmp/kind

kubectl_version="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
curl -fsSL -o /tmp/kubectl "https://dl.k8s.io/release/${kubectl_version}/bin/linux/${arch_alias}/kubectl"
sudo install -o root -g root -m 0755 /tmp/kubectl /bin/kubectl
rm -f /tmp/kubectl

k9s_version="$(
  curl -fsSL https://api.github.com/repos/derailed/k9s/releases/latest \
    | sed -n 's/.*"tag_name": *"\(v[^"]*\)".*/\1/p' \
    | head -1 || true
)"
if [[ -z "${k9s_version}" ]]; then
  k9s_version="${K9S_FALLBACK_VERSION}"
fi

curl -fsSL -o /tmp/k9s.tgz "https://github.com/derailed/k9s/releases/download/${k9s_version}/k9s_Linux_${arch_alias}.tar.gz"
tar -xzf /tmp/k9s.tgz -C /tmp k9s
sudo install -o root -g root -m 0755 /tmp/k9s /bin/k9s
rm -f /tmp/k9s /tmp/k9s.tgz

kind version
kubectl version --client
k9s version

# Nitro instances expose the root filesystem through an NVMe device that is
# absent inside the kind node. kubelet then never starts the API server, and
# kubeadm fails with "connection refused" on port 6443.
root_source="$(findmnt -n -o SOURCE /)"
root_dev="$(readlink -f "${root_source}")"
kind_config="$(mktemp)"
{
  echo "kind: Cluster"
  echo "apiVersion: kind.x-k8s.io/v1alpha4"
  echo "name: ${KIND_CLUSTER_NAME}"
  echo "nodes:"
  echo "  - role: control-plane"
  if [[ -b "${root_dev}" ]]; then
    echo "    extraMounts:"
    echo "      - hostPath: ${root_dev}"
    echo "        containerPath: ${root_dev}"
    echo "        propagation: HostToContainer"
  fi
} > "${kind_config}"

if ! run_with_docker "kind get clusters" | grep -qx "${KIND_CLUSTER_NAME}"; then
  run_with_docker "kind create cluster --name ${KIND_CLUSTER_NAME} --config ${kind_config}"
fi
rm -f "${kind_config}"

kubectl wait --for=condition=Ready nodes --all --context "kind-${KIND_CLUSTER_NAME}" --timeout=300s
kubectl cluster-info --context "kind-${KIND_CLUSTER_NAME}"
kubectl get nodes --context "kind-${KIND_CLUSTER_NAME}"
