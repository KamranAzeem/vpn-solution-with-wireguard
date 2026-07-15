#!/usr/bin/env bash
set -euo pipefail

WG_DIR="/etc/wireguard"
CLIENTS_DIR="${WG_DIR}/clients"
DB="${WG_DIR}/ip-allocations.json"
ENDPOINT=$(jq -r '.endpoint' "$DB")
DNS=$(jq -r '.dns // "1.1.1.1"' "$DB")

echo "=== Rotating server key ==="
echo "This will regenerate all client configs. All clients must reimport."
echo ""

cd "$WG_DIR"

# Backup existing keys
cp server.key server.key.backup.$(date +%F_%H%M%S)
cp server.key.pub server.key.pub.backup.$(date +%F_%H%M%S)

# Generate new server keypair
umask 077
wg genkey | tee server.key | wg pubkey > server.key.pub
NEW_SERVER_PUB=$(cat server.key.pub)

echo "New server public key: ${NEW_SERVER_PUB}"

# Regenerate wg0.conf with new private key
INTERFACE=$(jq -r '.interface // "ens3"' "$DB")
cat > wg0.conf << WGEOF
[Interface]
Address = $(jq -r '.server' "$DB")/24
ListenPort = 51820
PrivateKey = $(cat server.key)

PostUp = iptables -A FORWARD -i wg0 -j ACCEPT
PostUp = iptables -A FORWARD -o wg0 -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -o ${INTERFACE} -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT
PostDown = iptables -D FORWARD -o wg0 -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o ${INTERFACE} -j MASQUERADE
WGEOF

# Regenerate all client configs and add peers
echo ""
echo "Regenerating client configs..."

while IFS= read -r client_dir; do
  name=$(basename "$client_dir")
  ip=$(jq -r --arg name "$name" '.allocations | to_entries[] | select(.value == $name) | .key' "$DB")

  if [[ -z "$ip" || "$ip" == "null" ]]; then
    echo "  Skipping ${name} — no IP found in DB"
    continue
  fi

  client_pub=$(cat "${client_dir}/client.key.pub")

  # Add peer to wg0.conf
  cat >> wg0.conf << WGEOF

[Peer]
PublicKey = ${client_pub}
AllowedIPs = ${ip}/32
WGEOF

  # Regenerate client config
  client_key=$(cat "${client_dir}/client.key")
  cat > "${client_dir}/${name}.conf" << WGEOF
[Interface]
Address = ${ip}/24
PrivateKey = ${client_key}
DNS = ${DNS}

[Peer]
PublicKey = ${NEW_SERVER_PUB}
Endpoint = ${ENDPOINT}:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
WGEOF

  echo "  Updated: ${name} (${ip})"
done < <(find "$CLIENTS_DIR" -mindepth 1 -maxdepth 1 -type d)

# Restart WireGuard
echo ""
echo "Restarting WireGuard..."
systemctl restart wg-quick@wg0

echo ""
echo "=== Server key rotation complete ==="
echo "New server public key: ${NEW_SERVER_PUB}"
echo "All client configs regenerated."
echo ""
echo "IMPORTANT: Distribute the new configs to all clients."
echo "Each client must update their [Peer] PublicKey to:"
echo "  ${NEW_SERVER_PUB}"
