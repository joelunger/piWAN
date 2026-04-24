#!/usr/bin/env bash

# PiWAN Installer & Dependency Checker

echo -e "\033[1;36m=== PiWAN Installation ===\033[0m"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo -e "\033[1;31mPlease run this script as Root (sudo ./install.sh)\033[0m"
  exit 1
fi

REQUIRED_PACKAGES=(
    "whiptail"
    "network-manager"
    "dnsmasq"
    "iptables"
    "vnstat"
    "rng-tools"
)

echo "Checking system dependencies..."
apt-get update >/dev/null 2>&1

for pkg in "${REQUIRED_PACKAGES[@]}"; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
        echo -e " [\033[1;32mOK\033[0m] $pkg is already installed."
    else
        echo -e " [\033[1;33mINSTALLING\033[0m] $pkg is missing. Installing..."
        apt-get install -y "$pkg" >/dev/null 2>&1
        if [ $? -eq 0 ]; then
             echo -e "   -> SUCCESS"
        else
             echo -e "   -> \033[1;31mINSTALLATION FAILED\033[0m"
        fi
    fi
done

echo "Creating PiWAN directory structure (e.g., for snapshots)..."
mkdir -p /etc/piwan/snapshots
chmod 700 /etc/piwan

echo -e "\033[1;32mPiWAN Requirements successfully checked and installed.\033[0m"
