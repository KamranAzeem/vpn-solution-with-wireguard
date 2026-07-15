#!/usr/bin/env bash
# initial-setup.sh — Bootstrap a WireGuard VPN server from scratch
# Runs from the repo directory. Creates runtime data in WG_DIR only.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG="${REPO_DIR}/vpn.conf"

if [[ ! -f "$CONFIG" ]]; then
  echo "Error: ${CONFIG} not found. Edit vpn.conf first."
  exit 1
fi
source "$CONFIG"

WG_DIR="${WG_DIR:-/etc/wireguard}"

echo "=== WireGuard VPN Initial Setup ==="
echo "Repo:        ${REPO_DIR}"
echo "Config:      ${CONFIG}"
echo "Target dir:  ${WG_DIR}"
echo "Subnet:      ${WG_SUBNET}"
echo "Server IP:   ${WG_SERVER_IP}"
echo "Interface:   ${WG_INTERFACE}"
echo "Endpoint:    ${WG_ENDPOINT}:${WG_PORT}"
echo ""

if [[ -z "$WG_SUBNET" || -z "$WG_SERVER_IP" || -z "$WG_INTERFACE" || -z "$WG_ENDPOINT" ]]; then
  echo "Error: Required config variables are missing. Check vpn.conf."
  exit 1
fi

if [[ -f "${WG_DIR}/server.key" ]]; then
  echo "Warning: ${WG_DIR}/server.key already exists."
  echo "Run rotate-server-key.sh to regenerate."
  echo ""
  read -rp "Continue anyway? (y/N): " CONFIRM
  if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Aborted."
    exit 1
  fi
fi

# Install dependencies
echo "=== Installing dependencies ==="
if command -v dnf &>/dev/null; then
  dnf install -y wireguard-tools iptables-nft jq
elif command -v apt &>/dev/null; then
  apt update && apt install -y wireguard iptables jq
else
  echo "Error: unsupported package manager."
  exit 1
fi

# Create target directories (no scripts copied — repo stays outside WG_DIR)
mkdir -p "${WG_DIR}"/{clients,archive}

# Generate IP allocation DB
echo "=== Generating IP allocation database ==="
python3 -c "
import ipaddress, json

subnet = ipaddress.ip_network('${WG_SUBNET}', strict=False)
server_ip = '${WG_SERVER_IP}'
hosts = list(subnet.hosts())

allocations = {}
for host in hosts:
    ip = str(host)
    allocations[ip] = 'server' if ip == server_ip else None

db = {
    'pool': '${WG_SUBNET}',
    'server': '${WG_SERVER_IP}',
    'allocations': allocations
}

with open('${WG_DIR}/ip-allocations.json', 'w') as f:
    json.dump(db, f, indent=2)
    f.write('\n')

total = sum(1 for v in allocations.values() if v is None)
print(f'Generated DB: {total} client IPs available')
"

# Generate server keys
echo "=== Generating server keys ==="
cd "$WG_DIR"
umask 077
wg genkey | tee server.key | wg pubkey > server.key.pub
SERVER_PUB=$(cat server.key.pub)
echo "Server public key: ${SERVER_PUB}"

# Write wg0.conf
echo "=== Writing wg0.conf ==="
cat > wg0.conf << WGEOF
[Interface]
Address = ${WG_SERVER_IP}/24
ListenPort = ${WG_PORT}
PrivateKey = $(cat server.key)

PostUp = iptables -A FORWARD -i wg0 -j ACCEPT
PostUp = iptables -A FORWARD -o wg0 -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -o ${WG_INTERFACE} -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT
PostDown = iptables -D FORWARD -o wg0 -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o ${WG_INTERFACE} -j MASQUERADE
WGEOF

# Enable IP forwarding
echo "=== Enabling IP forwarding ==="
echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-wireguard.conf
sysctl -p /etc/sysctl.d/99-wireguard.conf

# Open firewall port if firewalld is active
if command -v firewall-cmd &>/dev/null && firewall-cmd --state &>/dev/null; then
  echo "=== Opening UDP ${WG_PORT} in firewalld ==="
  firewall-cmd --add-port="${WG_PORT}/udp" --permanent
  firewall-cmd --reload
fi

# Start WireGuard
echo "=== Starting WireGuard ==="
systemctl enable --now wg-quick@wg0

# Verify
echo ""
echo "=== Verification ==="
wg show

echo ""
echo "=== Initial setup complete ==="
echo "Server public key: ${SERVER_PUB}"
echo ""
echo "Next steps:"
echo "  1. Configure DigitalOcean Cloud Firewall (UDP ${WG_PORT})"
echo "  2. Add clients: ${SCRIPT_DIR}/add-client.sh"
echo "  3. See runbook.md in ${REPO_DIR} for operations"
