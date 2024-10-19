#!/bin/bash

# Script to configure LDAP client and related settings
# This script installs necessary packages, configures LDAP, PAM, and NSS, and enables SSH and XRDP services.

# Header
header_info() {
  clear
  cat <<"EOF"
   _   ____        _____          _                 _             _           
  /_\ |___ \ ___  /__   \___  ___| |__  _ __   ___ | | ___   __ _(_) ___  ___ 
 //_\\  __) / _ \   / /\/ _ \/ __| '_ \| '_ \ / _ \| |/ _ \ / _` | |/ _ \/ __|
/  _  \/ __/  __/  / / |  __/ (__| | | | | | | (_) | | (_) | (_| | |  __/\__ \
\_/ \_/_____\___|  \/   \___|\___|_| |_|_| |_|\___/|_|\___/ \__, |_|\___||___/
                                                        |___/                
EOF
}

RD=$(echo "\033[01;31m")
YW=$(echo "\033[33m")
GN=$(echo "\033[1;92m")
CL=$(echo "\033[m")
BFR="\r\033[K"
HOLD="-"
CM="${GN}✓${CL}"
CROSS="${RD}✗${CL}"

start_routines() {
  header_info

  # Confirm with the user before proceeding
  if (whiptail --title "Confirmation" --yesno "This script will configure the host name and modify system settings. Do you want to continue?" 10 60); then
    echo "User confirmed. Proceeding..."
  else
    echo "User cancelled. Exiting."
    exit 1
  fi
  
  # Check for root privileges
  if [ "$EUID" -ne 0 ]; then 
    echo "Please run as root"
    exit
  fi

  # Get new hostname from user
  NEW_HOSTNAME=$(whiptail --inputbox "Enter the new hostname for this PC:" 8 78 --title "Hostname Configuration" 3>&1 1>&2 2>&3)
  if [ $? -ne 0 ]; then
    echo "User cancelled the input. Exiting."
    exit 1
  fi
  echo "Setting hostname to $NEW_HOSTNAME..."
  hostnamectl set-hostname "$NEW_HOSTNAME"

  echo "Fixing XRDP configuration"
  wget https://www.c-nergy.be/downloads/xrdp-installer-1.2.2.zip
  unzip xrdp-installer-1.2.2.zip 
  bash xrdp-installer-1.2.2.sh


  # Display IP address and hostname
  source ~/.bashrc
  IP_ADDR=$(hostname -I | awk '{print $1}')  
  #echo -e "\n${GN}Hostname:${CL} $NEW_HOSTNAME"
  #echo -e "${GN}IP Address:${CL} $IP_ADDR\n"
  echo "$NEW_HOSTNAME" | toilet -f term -F border | lolcat
  echo "IP Address: $IP_ADDR" | toilet -f term -F border | lolcat
  echo "LDAP client configuration completed."
}
start_routines
