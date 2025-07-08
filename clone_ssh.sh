#!/usr/bin/env bash

# 1) Confirm
whiptail --title "SSH Clone Script" \
  --yesno "This will install your Ed25519 SSH key on another host.\nProceed?" \
  10 60 || exit

# 2) Prompt for creds
exec 3>&1
u=$(whiptail --title "SSH Clone" --inputbox  "Username on remote" 8 40 3>&1 1>&2 2>&3)
p=$(whiptail --title "SSH Clone" --passwordbox "Password on remote" 8 40 3>&1 1>&2 2>&3)
h=$(whiptail --title "SSH Clone" --inputbox  "Remote Host or IP" 8 40 3>&1 1>&2 2>&3)
exec 3>&-

# 3) Trim all whitespace
u=${u//[[:space:]]/}
h=${h//[[:space:]]/}

# 4) Sanity checks
if [[ -z "$u" || -z "$p" || -z "$h" ]]; then
  echo "ERROR: username, password and host must all be non-empty." >&2
  exit 1
fi
if [[ ! -f "$HOME/.ssh/id_ed25519" || ! -f "$HOME/.ssh/id_ed25519.pub" ]]; then
  echo "ERROR: you need a local ~/.ssh/id_ed25519 and id_ed25519.pub first." >&2
  exit 1
fi

# 5) Prepare remote ~/.ssh
sshpass -p "$p" ssh -o StrictHostKeyChecking=no "$u@$h" \
  'mkdir -p ~/.ssh && chmod 700 ~/.ssh'

# 6) Copy private+public Ed25519 key
sshpass -p "$p" scp -o StrictHostKeyChecking=no \
  "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_ed25519.pub" \
  "$u@$h":~/.ssh/

# 7) Fix permissions & add GitHub to known_hosts remotely
sshpass -p "$p" ssh -o StrictHostKeyChecking=no "$u@$h" <<'EOF'
chmod 600 ~/.ssh/id_ed25519
chmod 644 ~/.ssh/id_ed25519.pub
ssh-keyscan github.com >> ~/.ssh/known_hosts
chmod 644 ~/.ssh/known_hosts
EOF

echo "??  Ed25519 key installed on $h. You can now SSH there and run:"
echo "    git clone git@github.com:<your-user>/<your-repo>.git"
