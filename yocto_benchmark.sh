#!/bin/bash

# Configuration / Vars
YOCTO_BRANCH="kirkstone"
YOCTO_DIR="$HOME/yocto-qemu"
BUILD_DIR="qemu-build"

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
  set -e
  
  echo "==> Cleaning previous build directory..."
  rm -rf "$YOCTO_DIR"
  
  echo "==> Cloning Poky (Yocto core)..."
  git clone -b "$YOCTO_BRANCH" https://git.yoctoproject.org/poky "$YOCTO_DIR"
  
  cd "$YOCTO_DIR"
  
  echo "==> Setting up build environment..."
  source oe-init-build-env "$BUILD_DIR"
  
  echo 'MACHINE = "qemuarm64"' >> conf/local.conf
  echo 'INHERIT += "buildstats"' >> conf/local.conf
  
  echo "==> Forcing cleansstate..."
  bitbake -c cleansstate core-image-minimal || true
  bitbake -c cleanall core-image-minimal || true
}

benchmark() {
  echo "==> Starting timed clean build..."
  /usr/bin/time -v bitbake core-image-minimal
  
  echo "==> Build complete."
}

header_info
start_routines


