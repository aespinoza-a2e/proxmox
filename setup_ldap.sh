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
  if (whiptail --title "Confirmation" --yesno "This script will configure the LDAP client and modify system settings. Do you want to continue?" 10 60); then
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
  
  # Get password from user
  PASSWORD=$(whiptail --passwordbox "Enter the LDAP bind password:" 8 78 --title "LDAP Configuration" 3>&1 1>&2 2>&3)
  
  if [ $? -ne 0 ]; then
    echo "User cancelled the input. Exiting."
    exit 1
  fi
  
  # Variables
  LDAP_SERVER="ldap://10.10.20.66"
  BASE_DN="dc=a2e,dc=test"
  BIND_DN="cn=admin,dc=example,dc=com"
  BIND_PASSWORD="$PASSWORD"
  
  # Install necessary packages
  echo "Installing necessary packages..."
  sudo apt update && sudo apt install -y ldap-utils libnss-ldapd libpam-ldapd openssh-server xrdp
  
  # Add all users to sudo group
  echo "Adding all users to sudo group..."
  for user in $(getent passwd | awk -F: '$3 >= 1000 {print $1}'); do
    usermod -aG sudo "$user"
  done
  
  # Configure LDAP client
  echo "Configuring LDAP client..."
  sudo bash -c "echo 'URI $LDAP_SERVER' >> /etc/ldap/ldap.conf"
  sudo bash -c "echo 'BASE $BASE_DN' >> /etc/ldap/ldap.conf"

  # Configure NSS
  echo "Configuring NSS..."
  sudo bash -c 'cat <<EOF >> /etc/nsswitch.conf
passwd:     files ldap
shadow:     files ldap
group:      files ldap
EOF'
  
  # Configure PAM for LDAP
  echo "Configuring PAM for LDAP..."
  sudo bash -c 'cat <<EOF >> /etc/pam.d/common-auth
auth        required      pam_env.so
auth        sufficient    pam_unix.so try_first_pass
auth        requisite     pam_succeed_if.so uid >= 1000 quiet_success
auth        sufficient    pam_ldap.so use_first_pass
auth        required      pam_deny.so
EOF'
  
  sudo bash -c 'cat <<EOF >> /etc/pam.d/common-account
account     required      pam_unix.so
account     sufficient    pam_localuser.so
account     sufficient    pam_succeed_if.so uid < 1000 quiet
account     [default=bad success=ok user_unknown=ignore] pam_ldap.so
account     required      pam_permit.so
EOF'
  
  sudo bash -c 'cat <<EOF >> /etc/pam.d/common-password
password    requisite     pam_pwquality.so try_first_pass local_users_only retry=3 authtok_type=
password    sufficient    pam_unix.so sha512 shadow try_first_pass use_authtok
password    sufficient    pam_ldap.so use_authtok
password    required      pam_deny.so
EOF'
  
  sudo bash -c 'cat <<EOF >> /etc/pam.d/common-session
session     optional      pam_keyinit.so revoke
session     required      pam_limits.so
session     [success=1 default=ignore] pam_succeed_if.so service in crond quiet use_uid
session     required      pam_unix.so
session     optional      pam_ldap.so
session     optional      pam_mkhomedir.so skel=/etc/skel umask=077
EOF'
  
  # Restart necessary services
  echo "Restarting services..."
  systemctl restart nslcd || echo "nslcd service not found, skipping..."
  systemctl enable --now ssh xrdp || echo "Failed to enable SSH or XRDP services."
  
  echo "LDAP client configuration completed."
}
start_routines
