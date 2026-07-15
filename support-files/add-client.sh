#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG="${REPO_DIR}/vpn.conf"

if [[ -f "$CONFIG" ]]; then
  source "$CONFIG"
else
  echo "Error: ${CONFIG} not found. Run from the vpn-solution repo."
  exit 1
fi

WG_DIR="${WG_DIR:-/etc/wireguard}"
CLIENTS_DIR="${WG_DIR}/clients"
DB="${WG_DIR}/ip-allocations.json"
SERVER_PUB=$(cat "${WG_DIR}/server.key.pub")

email_to_name() {
  echo "$1" | tr '@.' '-' | tr -s '-'
}

usage() {
  echo "Usage: $0 --email <email> --device <type> --alias <alias>"
  echo ""
  echo "  --email   End-user's email address"
  echo "  --device  Device type: laptop, desktop, phone, tablet, server"
  echo "  --alias   Device alias: e.g. office, personal, linux, home"
  exit 1
}

EMAIL=""; DEVICE=""; ALIAS=""
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

case "$DEVICE" in
  laptop|desktop|phone|tablet|server) ;;
  *) echo "Error: invalid device type '${DEVICE}'."; exit 1 ;;
esac

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
  echo "Error: no available IP addresses."
  exit 1
fi

echo "Allocated IP: ${AVAILABLE_IP}"

mkdir -p "$CLIENT_DIR"
cd "$CLIENT_DIR"
umask 077
wg genkey | tee client.key | wg pubkey > client.key.pub
CLIENT_PUB=$(cat client.key.pub)

ALLOWED_IPS="${ALLOWED_IPS:-0.0.0.0/0}"

cat > "${CLIENT_NAME}.conf" << WGEOF
[Interface]
Address = ${AVAILABLE_IP}/24
PrivateKey = $(cat client.key)
DNS = ${WG_DNS:-1.1.1.1}

[Peer]
PublicKey = ${SERVER_PUB}
Endpoint = ${WG_ENDPOINT:-vpn.do.wbitt.com}:${WG_PORT:-51820}
AllowedIPs = ${ALLOWED_IPS}
PersistentKeepalive = 25
WGEOF

wg set wg0 peer "${CLIENT_PUB}" allowed-ips "${AVAILABLE_IP}/32"
wg-quick save wg0

jq --arg ip "$AVAILABLE_IP" --arg name "$CLIENT_NAME" \
  '.allocations[$ip] = $name' "$DB" > "${DB}.tmp" && mv "${DB}.tmp" "$DB"

echo ""
echo "=== Client ${CLIENT_NAME} added ==="
echo "  IP:         ${AVAILABLE_IP}"
echo "  Config:     ${CLIENT_DIR}/${CLIENT_NAME}.conf"
echo "  Public key: ${CLIENT_PUB}"
echo ""
echo "Deliver via:"
echo "  SCP:  scp root@<vps>:${CLIENT_DIR}/${CLIENT_NAME}.conf ."
echo "  QR:   qrencode -t ansiutf8 < ${CLIENT_DIR}/${CLIENT_NAME}.conf"
echo "  Mail: ${SCRIPT_DIR}/email-config.sh --name ${CLIENT_NAME} --email ${EMAIL}"
