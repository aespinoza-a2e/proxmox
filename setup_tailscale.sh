#!/usr/bin/env bash
set -euo pipefail

# ====================== EDITABLE VARS ======================
LAN_IF="eth1"
WAN_IF="eth0"

LAN_CIDR="172.16.1.0/24"
LAN_IP="172.16.1.1"

# DHCP pool
DHCP_START="172.16.1.50"
DHCP_END="172.16.1.200"
LEASE_TIME="12h"

# Upstream DNS for dnsmasq (set 100.100.100.100 for Tailscale MagicDNS)
UPSTREAM_DNS_1="1.1.1.1"
UPSTREAM_DNS_2="9.9.9.9"

# Tailscale: site-to-site settings
TAILSCALE_ADVERTISE_ROUTES="$LAN_CIDR"
TAILSCALE_EXTRA_FLAGS="--ssh=true"   # optional; remove if undesired
# ===========================================================

# ---- Helpers ----
cidr_prefix() { awk -F'/' '{print $2}' <<<"$1"; }
cidr_network() { awk -F'/' '{print $1}' <<<"$1"; }
cidr_to_netmask() {
  # set -u safe
  local param="${1-24}" p="$1" mask="" n i
  for ((i=0, p=$param; i<4; i++)); do
    n=$(( p>8 ? 8 : (p<0 ? 0 : p) ))
    mask+="${mask:+.}$(( n==0 ? 0 : 256 - 2**(8-n) ))"
    p=$(( p - n ))
  done
  echo "$mask"
}
require_bin() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1"; exit 1; }; }

LAN_PREFIX="$(cidr_prefix "$LAN_CIDR")"
LAN_NETMASK="$(cidr_to_netmask "$LAN_PREFIX")"
LAN_NETWORK="$(cidr_network "$LAN_CIDR")"

echo "==> Using:"
echo "    LAN_IF=$LAN_IF  WAN_IF=$WAN_IF"
echo "    LAN_CIDR=$LAN_CIDR  LAN_IP=$LAN_IP  NETMASK=$LAN_NETMASK"

require_bin ip
require_bin systemctl
export DEBIAN_FRONTEND=noninteractive

echo "==> [1/8] apt update & base packages"
apt-get update -y
apt-get install -y dnsmasq nftables curl

# ---- [2/8] Assign static IP to eth1 WITHOUT touching NetworkManager ----
# Create a tiny helper script that just sets the address, then a oneshot unit to run it at boot.
echo "==> [2/8] Create persistent static IP assignment for ${LAN_IF} (no NM changes)"
install -d -m 0755 /usr/local/sbin
cat >/usr/local/sbin/configure-${LAN_IF}-ip.sh <<EOF
#!/usr/bin/env bash
set -euo pipefail
ip link set ${LAN_IF} up || true
# Ensure only one correct address is present
ip -4 addr flush dev ${LAN_IF} || true
ip -4 addr add ${LAN_IP}/${LAN_PREFIX} dev ${LAN_IF}
EOF
chmod +x /usr/local/sbin/configure-${LAN_IF}-ip.sh

cat >/etc/systemd/system/${LAN_IF}-static-ip.service <<EOF
[Unit]
Description=Configure static IPv4 on ${LAN_IF} safely (no NetworkManager changes)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/configure-${LAN_IF}-ip.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now ${LAN_IF}-static-ip.service

# ---- [3/8] dnsmasq for DHCP+DNS on LAN ----
echo "==> [3/8] Configure dnsmasq for ${LAN_IF}"
mkdir -p /etc/dnsmasq.d
cat >/etc/dnsmasq.d/lan-${LAN_IF}.conf <<EOF
# Listen only on LAN + localhost
interface=${LAN_IF}
bind-interfaces
listen-address=${LAN_IP},127.0.0.1

# DHCP range & options
dhcp-range=${DHCP_START},${DHCP_END},${LAN_NETMASK},${LEASE_TIME}
dhcp-option=option:router,${LAN_IP}
dhcp-option=option:dns-server,${LAN_IP}

# Upstream resolvers (comment these if you prefer Tailscale MagicDNS)
server=${UPSTREAM_DNS_1}
server=${UPSTREAM_DNS_2}

# No IPv6 DHCP from here
dhcp-option=option6:dns-server
EOF

systemctl enable dnsmasq
systemctl restart dnsmasq

# ---- [4/8] Enable IP forwarding (IPv4 + IPv6) ----
echo "==> [4/8] Enable IP forwarding"
cat >/etc/sysctl.d/99-ipforward.conf <<'EOF'
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF
sysctl --system >/dev/null

# ---- [5/8] nftables firewall + NAT (LAN -> WAN ONLY) ----
echo "==> [5/8] Configure nftables (allow SSH/DNS/DHCP; forward LAN<->WAN/tailscale; NAT only to WAN)"
cat >/etc/nftables.conf <<'EOF'
#!/usr/sbin/nft -f
flush ruleset

table inet filter {
  chain input {
    type filter hook input priority 0;
    ct state established,related accept
    iifname "lo" accept
    iifname "tailscale0" accept
    ip protocol icmp accept
    ip6 nexthdr icmpv6 accept
    tcp dport { 22, 53 } accept
    udp dport { 53, 67 } accept
    counter drop
  }

  chain forward {
    type filter hook forward priority 0;
    ct state established,related accept
    # Allow LAN <-> WAN and LAN <-> tailscale
    iifname { "LAN_IF_PLACEHOLDER" } oifname { "WAN_IF_PLACEHOLDER", "tailscale0" } accept
    iifname { "WAN_IF_PLACEHOLDER", "tailscale0" } oifname { "LAN_IF_PLACEHOLDER" } accept
    counter drop
  }
}

table inet nat {
  chain postrouting {
    type nat hook postrouting priority 100;
    # NAT LAN out to internet via WAN ONLY (never NAT to tailscale0)
    oifname "WAN_IF_PLACEHOLDER" ip saddr LAN_CIDR_PLACEHOLDER masquerade
  }
}
EOF
sed -i "s/LAN_IF_PLACEHOLDER/${LAN_IF}/g" /etc/nftables.conf
sed -i "s/WAN_IF_PLACEHOLDER/${WAN_IF}/g" /etc/nftables.conf
ESCAPED_CIDR="$(sed 's/[\/&]/\\&/g' <<<"$LAN_CIDR")"
sed -i "s/LAN_CIDR_PLACEHOLDER/${ESCAPED_CIDR}/g" /etc/nftables.conf

systemctl enable nftables
# Safer apply: load then show first lines (no network restarts)
nft -f /etc/nftables.conf
nft list ruleset | head -n 40 >/dev/null

# ---- [6/8] Install Tailscale ----
echo "==> [6/8] Install Tailscale"
if ! command -v tailscale >/dev/null 2>&1; then
  curl -fsSL https://tailscale.com/install.sh | sh
fi

# ---- [7/8] Bring up Tailscale as a site-to-site subnet router ----
echo "==> [7/8] tailscale up"
tailscale up \
  --advertise-routes="${TAILSCALE_ADVERTISE_ROUTES}" \
  --snat-subnet-routes=false \
  --accept-routes=true \
  ${TAILSCALE_EXTRA_FLAGS} || true

echo
echo ">>> Approve the advertised route ${TAILSCALE_ADVERTISE_ROUTES} in the Tailscale admin console."
echo ">>> Ensure ACLs allow traffic between ${LAN_CIDR} and your 10.x.x.x office networks."
echo

# ---- [8/8] Summary ----
echo "==> [8/8] Summary / checks"
ip -4 addr show "$LAN_IF" | sed 's/^/  /'
echo
echo "Routes:"
ip route | sed 's/^/  /'
echo
echo "tailscale status:"
tailscale status | sed 's/^/  /' || true
echo
echo "Done. Tests (from a LAN client on ${LAN_IF} side):"
echo "  ping ${LAN_IP}                # Pi on LAN"
echo "  ping 1.1.1.1                  # Internet via NAT on ${WAN_IF}"
echo "  ping <10.x.x.x at HQ>         # via Tailscale after route approval"
