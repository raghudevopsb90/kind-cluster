#!/bin/bash
# First stage, before Docker is installed.
#
# The AMI boots an older kernel than the one in the repos. When dnf installs
# docker-ce it pulls kernel-modules-extra for the newest kernel only, so the
# running kernel has no br_netfilter or xt_addrtype and dockerd fails with
# "Extension addrtype revision 0 not supported". Install the newest kernel with
# its extra modules and reboot into it.
set -euo pipefail

# The EBS volume is bigger than the AMI disk. Grow the last partition and give
# /var 10 GiB more, because the kind node image and container layers live there.
grow_var() {
  local pv disk part
  pv="$(sudo pvs --noheadings -o pv_name,vg_name | awk '$2=="RootVG" {print $1; exit}')"
  if [[ -z "${pv}" ]]; then
    echo "no RootVG on this image, skipping disk resize"
    return
  fi
  disk="$(lsblk -ndo PKNAME "${pv}")"
  part="$(cat "/sys/class/block/$(basename "${pv}")/partition")"

  sudo dnf install -y cloud-utils-growpart
  sudo growpart "/dev/${disk}" "${part}" || true   # exits 1 with NOCHANGE on a rerun
  sudo pvresize "${pv}"

  if [[ ! -f /var/lib/kind-bootstrap/varvol-extended ]]; then
    sudo lvextend -r -L +10G /dev/RootVG/varVol
    sudo mkdir -p /var/lib/kind-bootstrap
    sudo touch /var/lib/kind-bootstrap/varvol-extended
  fi
}

if command -v cloud-init >/dev/null 2>&1; then
  sudo cloud-init status --wait >/dev/null || true
fi

grow_var

sudo dnf install -y kernel kernel-modules-extra "kernel-modules-extra-$(uname -r)" \
  || sudo dnf install -y kernel kernel-modules-extra

if [[ "$(sudo grubby --default-kernel)" != "/boot/vmlinuz-$(uname -r)" ]]; then
  echo "rebooting into $(sudo grubby --default-kernel)"
  # systemd-run, not "reboot &": a background job dies with the SSH session.
  sudo systemd-run --on-active=5 /usr/bin/systemctl reboot
else
  echo "running kernel already has its extra modules, no reboot needed"
fi
