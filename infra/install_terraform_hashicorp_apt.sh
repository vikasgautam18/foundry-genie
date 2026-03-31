#!/usr/bin/env bash
# install_terraform_hashicorp_apt.sh
# Installs HashiCorp Terraform via the official APT repository on Debian

set -euo pipefail

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

echo "[*] Terraform version installed:"
terraform -version

echo "[*] Done."
