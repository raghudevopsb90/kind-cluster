#!/bin/bash
# Installs docker-ce, kind, kubectl, and k9s, then creates a kind cluster.
# Invoked by the null_resource remote-exec provisioner as ec2-user.
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

if command -v cloud-init >/dev/null 2>&1; then
  sudo cloud-init status --wait || true
fi

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

for _ in $(seq 1 30); do
  if sg docker -c "docker info" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
sg docker -c "docker info" >/dev/null

case "$(uname -m)" in
  x86_64) arch_alias="amd64" ;;
  aarch64) arch_alias="arm64" ;;
  *)
    echo "unsupported architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

curl -fsSL -o /tmp/kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${arch_alias}"
sudo install -o root -g root -m 0755 /tmp/kind /usr/local/bin/kind
rm -f /tmp/kind

kubectl_version="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
curl -fsSL -o /tmp/kubectl "https://dl.k8s.io/release/${kubectl_version}/bin/linux/${arch_alias}/kubectl"
sudo install -o root -g root -m 0755 /tmp/kubectl /usr/local/bin/kubectl
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
sudo install -o root -g root -m 0755 /tmp/k9s /usr/local/bin/k9s
rm -f /tmp/k9s /tmp/k9s.tgz

kind version
kubectl version --client
k9s version

# usermod does not change the groups of this SSH session. sg starts kind
# with the docker group so the cluster kubeconfig stays in this user's home.
if ! sg docker -c "kind get clusters" | grep -qx "${KIND_CLUSTER_NAME}"; then
  sg docker -c "kind create cluster --name ${KIND_CLUSTER_NAME}"
fi

kubectl cluster-info --context "kind-${KIND_CLUSTER_NAME}"
kubectl get nodes --context "kind-${KIND_CLUSTER_NAME}"
