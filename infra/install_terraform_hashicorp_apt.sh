#!/usr/bin/env bash
# install_terraform_hashicorp_apt.sh
# Installs HashiCorp Terraform on Ubuntu (APT) or Fedora (DNF).
# Other distributions are not supported.

set -euo pipefail

detect_os() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    echo "$ID"
  else
    echo "unknown"
  fi
}

install_terraform_ubuntu() {
  echo "[*] Detected Ubuntu"

  echo "[*] Updating package index..."
  sudo apt-get update -y

  echo "[*] Installing prerequisites (wget, gnupg, software-properties-common)..."
  sudo apt-get install -y wget gnupg software-properties-common

  echo "[*] Adding HashiCorp GPG key..."
  wget -O- https://apt.releases.hashicorp.com/gpg \
    | gpg --dearmor \
    | sudo tee /usr/share/keyrings/hashicorp-archive-keyring.gpg >/dev/null

  echo "[*] Adding HashiCorp APT repository..."
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
    | sudo tee /etc/apt/sources.list.d/hashicorp.list >/dev/null

  echo "[*] Updating package index with HashiCorp repo..."
  sudo apt-get update -y

  echo "[*] Installing Terraform..."
  sudo apt-get install -y terraform
}

install_terraform_fedora() {
  echo "[*] Detected Fedora"

  echo "[*] Adding HashiCorp DNF repository..."
  sudo tee /etc/yum.repos.d/hashicorp.repo >/dev/null <<'EOF'
[hashicorp]
name=HashiCorp Stable - $basearch
baseurl=https://rpm.releases.hashicorp.com/fedora/$releasever/$basearch/stable
enabled=1
gpgcheck=1
gpgkey=https://rpm.releases.hashicorp.com/gpg
EOF

  echo "[*] Installing Terraform..."
  sudo dnf install -y terraform
}

OS_ID=$(detect_os)

case "$OS_ID" in
  ubuntu)
    install_terraform_ubuntu
    ;;
  fedora)
    install_terraform_fedora
    ;;
  *)
    echo "[ERROR] Unsupported OS: '${OS_ID}'. This script only supports Ubuntu and Fedora." >&2
    exit 1
    ;;
esac

echo "[*] Terraform version installed:"
terraform -version

echo "[*] Done."
