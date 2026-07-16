#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0"
  echo ""
  echo "Regenerates the server WireGuard key and all client configs."
  echo "All clients must reimport their config after this operation."
  exit 1
}

if [[ $# -gt 0 ]]; then
  usage
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG="${REPO_DIR}/vpn.conf"

if [[ -f "$CONFIG" ]]; then
  source "$CONFIG"
else
  echo "Error: ${CONFIG} not found. Copy vpn.conf.example to vpn.conf and edit it."
  exit 1
fi

WG_DIR="${WG_DIR:-/etc/wireguard}"
CLIENTS_DIR="${WG_DIR}/clients"
DB="${WG_DIR}/ip-allocations.json"

echo "=== Rotating server key ==="
echo "All client configs will be regenerated. Clients must reimport."
echo ""

cd "$WG_DIR"

cp server.key server.key.backup.$(date +%F_%H%M%S)
cp server.key.pub server.key.pub.backup.$(date +%F_%H%M%S)

umask 077
wg genkey | tee server.key | wg pubkey > server.key.pub
NEW_SERVER_PUB=$(cat server.key.pub)

echo "New server public key: ${NEW_SERVER_PUB}"

cat > wg0.conf << WGEOF
[Interface]
Address = $(jq -r '.server' "$DB")/24
ListenPort = ${WG_PORT:-51820}
PrivateKey = $(cat server.key)

PostUp = iptables -A FORWARD -i wg0 -j ACCEPT
PostUp = iptables -A FORWARD -o wg0 -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -o ${WG_INTERFACE:-ens3} -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT
PostDown = iptables -D FORWARD -o wg0 -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o ${WG_INTERFACE:-ens3} -j MASQUERADE
WGEOF

echo ""
echo "Regenerating client configs..."

while IFS= read -r client_dir; do
  name=$(basename "$client_dir")
  ip=$(jq -r --arg name "$name" '.allocations | to_entries[] | select(.value == $name) | .key' "$DB")

  if [[ -z "$ip" || "$ip" == "null" ]]; then
    echo "  Skipping ${name} — no IP in DB"
    continue
  fi

  # Support both naming styles: client.key.pub (new) and <name>.key.pub (legacy)
  if [[ -f "${client_dir}/client.key.pub" ]]; then
    KEY_PREFIX="${client_dir}/client"
  elif [[ -f "${client_dir}/${name}.key.pub" ]]; then
    KEY_PREFIX="${client_dir}/${name}"
  else
    echo "  Skipping ${name} — no key files found"
    continue
  fi

  client_pub=$(cat "${KEY_PREFIX}.key.pub")

  cat >> wg0.conf << WGEOF

[Peer]
PublicKey = ${client_pub}
AllowedIPs = ${ip}/32
WGEOF

  client_key=$(cat "${KEY_PREFIX}.key")
  cat > "${client_dir}/${name}.conf" << WGEOF
[Interface]
Address = ${ip}/24
PrivateKey = ${client_key}
DNS = ${WG_DNS:-1.1.1.1}

[Peer]
PublicKey = ${NEW_SERVER_PUB}
Endpoint = ${WG_ENDPOINT:-vpn.do.wbitt.com}:${WG_PORT:-51820}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
WGEOF

  echo "  Updated: ${name} (${ip})"
  EMAIL_CMDS="${EMAIL_CMDS}  ${SCRIPT_DIR}/email-config.sh --name ${name} --email <${name}-email> --plain"$'\n'
done < <(find "$CLIENTS_DIR" -mindepth 1 -maxdepth 1 -type d)

systemctl restart wg-quick@wg0

echo ""
echo "=== Rotation complete ==="
echo "New server public key: ${NEW_SERVER_PUB}"
echo ""
echo "To email each client their updated config (replace <name-email> for each):"
echo "${EMAIL_CMDS}"
