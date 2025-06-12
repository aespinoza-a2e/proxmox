#!/usr/bin/env bash
whiptail --title "SSH Clone Script" --yesno "This script will copy your SSH key to another host.\n\nContinue?" 10 60 || exit
u=$(whiptail --title "SSH Clone Script" --inputbox "Username" 8 40 3>&1 1>&2 2>&3)
p=$(whiptail --title "SSH Clone Script" --passwordbox "Password" 8 40 3>&1 1>&2 2>&3)
h=$(whiptail --title "SSH Clone Script" --inputbox "Host/IP" 8 40 3>&1 1>&2 2>&3)
sshpass -p "$p" ssh -o StrictHostKeyChecking=no "$u@$h" 'mkdir -p ~/.ssh && chmod 700 ~/.ssh'
sshpass -p "$p" scp -o StrictHostKeyChecking=no ~/.ssh/id_* "$u@$h":~/.ssh/
sshpass -p "$p" ssh -o StrictHostKeyChecking=no "$u@$h" 'chmod 600 ~/.ssh/id_*'
