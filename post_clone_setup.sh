#!/bin/bash

# Script to configure LDAP client and related settings
# This script installs necessary packages, configures LDAP, PAM, and NSS, and enables SSH and XRDP services.

# Colors
RD=$(echo "\033[01;31m")
YW=$(echo "\033[33m")
BL=$(echo "\033[36m")
GN=$(echo "\033[1;92m")
CL=$(echo "\033[m")
CM="${GN}✓${CL}"
CROSS="${RD}✗${CL}"

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

start_routines() {
   header_info

   # Confirm with the user before proceeding
   if (whiptail --title "Confirmation" --yesno "This script will configure the host name and modify system settings. Do you want to continue?" 10 60); then
      echo "User confirmed. Proceeding..."
   else
      echo "User cancelled. Exiting."
      exit 1
   fi

   # Check if running as root
   if [ "$EUID" -eq 0 ]; then
      echo "This script should not be run as root. Please run it as a non-root user."
      exit 1
   fi

   # Get new hostname from user
   NEW_HOSTNAME=$(whiptail --inputbox "Enter the new hostname for this PC:" 8 78 --title "Hostname Configuration" 3>&1 1>&2 2>&3)
   if [ $? -ne 0 ]; then
      echo "User cancelled the input. Exiting."
      exit 1
   fi
   echo -e "${BL}Setting hostname to $NEW_HOSTNAME...${CL} \n"
   sudo hostnamectl set-hostname "$NEW_HOSTNAME"

   # Update avahi configuration
   echo -e "${BL}Configuring avahi-publishing settings...${CL} \n"
   avhi_conf_path="/etc/avahi/avahi-daemon.conf"
   if [[ -f "$avhi_conf_path" ]]; then
      sudo sed -i 's/publish-workstation=no/publish-workstation=yes/' "$avhi_conf_path"
      echo "The configuration has been updated."
   else
      echo "Error: The file does not exist."
   fi

   # Confirm if XRDP should be installed
   if (whiptail --title "XRDP Installation" --yesno "Would you like to install XRDP?" 10 60); then
      echo -e "${BL}Installing XRDP with custom script...${CL} \n"
      bash -c "$(wget -qLO - https://raw.githubusercontent.com/aespinoza-a2e/proxmox/refs/heads/develop/xrdp-installer-1.5.2.sh)" -- -l
   else
      echo "XRDP installation skipped."
   fi

   # Display IP address and hostname
   source ~/.bashrc
   IP_ADDR=$(hostname -I | awk '{print $1}')  
   echo "$NEW_HOSTNAME" | toilet -f term -F border | lolcat
   echo "IP Address: $IP_ADDR" | toilet -f term -F border | lolcat
   echo "Guest configuration completed, restarting VM"
   sudo reboot
}
start_routines
