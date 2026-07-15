#!/usr/bin/env bash
set -euo pipefail

WG_DIR="/etc/wireguard"
CLIENTS_DIR="${WG_DIR}/clients"
DB="${WG_DIR}/ip-allocations.json"
SERVER_PUB=$(cat "${WG_DIR}/server.key.pub")

email_to_name() {
  echo "$1" | tr '@.' '-' | tr -s '-'
}

usage() {
  echo "Usage: $0 --email <email> --device <type> --alias <alias>"
  echo ""
  echo "  --email   End-user's email address (e.g. user@example.com)"
  echo "  --device  Device type: laptop, desktop, phone, tablet, server"
  echo "  --alias   Device alias: e.g. office, personal, linux, home"
  exit 1
}

# Parse args
EMAIL=""
DEVICE=""
ALIAS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --email)  EMAIL="$2";  shift 2 ;;
    --device) DEVICE="$2"; shift 2 ;;
    --alias)  ALIAS="$2";  shift 2 ;;
    *) echo "Unknown arg: $1"; usage ;;
  esac
done

if [[ -z "$EMAIL" || -z "$DEVICE" || -z "$ALIAS" ]]; then
  echo "Error: --email, --device, and --alias are required."
  usage
fi

CLIENT_NAME="$(email_to_name "${EMAIL}")-${DEVICE}-${ALIAS}"
CLIENT_DIR="${CLIENTS_DIR}/${CLIENT_NAME}"

echo "=== Adding client: ${CLIENT_NAME} ==="

# Validate device type
case "$DEVICE" in
  laptop|desktop|phone|tablet|server) ;;
  *) echo "Error: invalid device type '${DEVICE}'. Use: laptop, desktop, phone, tablet, server"; exit 1 ;;
esac

# Load IP DB and find first available IP
if [[ ! -f "$DB" ]]; then
  echo "Error: IP allocation DB not found at ${DB}"
  exit 1
fi

AVAILABLE_IP=""
while IFS= read -r ip; do
  ip_clean=$(echo "$ip" | tr -d ' ",')
  value=$(jq -r --arg ip "$ip_clean" '.allocations[$ip] // "error"' "$DB")
  if [[ "$value" == "null" ]]; then
    AVAILABLE_IP="$ip_clean"
    break
  fi
done < <(jq -r '.allocations | keys[]' "$DB")

if [[ -z "$AVAILABLE_IP" ]]; then
  echo "Error: no available IP addresses in the pool."
  exit 1
fi

echo "Allocated IP: ${AVAILABLE_IP}"

# Create client directory
mkdir -p "$CLIENT_DIR"
cd "$CLIENT_DIR"

# Generate keypair
umask 077
wg genkey | tee client.key | wg pubkey > client.key.pub
CLIENT_PUB=$(cat client.key.pub)

# Create client config
cat > "${CLIENT_NAME}.conf" << WGEOF
[Interface]
Address = ${AVAILABLE_IP}/24
PrivateKey = $(cat client.key)
DNS = 1.1.1.1

[Peer]
PublicKey = ${SERVER_PUB}
Endpoint = $(jq -r '.endpoint' "$DB"):51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
WGEOF

# Add peer to WireGuard
wg set wg0 peer "${CLIENT_PUB}" allowed-ips "${AVAILABLE_IP}/32"
wg-quick save wg0

# Update IP DB
jq --arg ip "$AVAILABLE_IP" --arg name "$CLIENT_NAME" \
  '.allocations[$ip] = $name' "$DB" > "${DB}.tmp" && mv "${DB}.tmp" "$DB"

echo ""
echo "=== Client ${CLIENT_NAME} added ==="
echo "  IP:         ${AVAILABLE_IP}"
echo "  Config:     ${CLIENT_DIR}/${CLIENT_NAME}.conf"
echo "  Public key: ${CLIENT_PUB}"
echo ""
echo "To deliver the config:"
echo "  1. SCP:  scp root@<vps>:${CLIENT_DIR}/${CLIENT_NAME}.conf ."
echo "  2. QR:   qrencode -t ansiutf8 < ${CLIENT_DIR}/${CLIENT_NAME}.conf"
echo "  3. Mail:  ./email-config.sh --name ${CLIENT_NAME} --email ${EMAIL}"
