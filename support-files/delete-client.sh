#!/usr/bin/env bash
set -euo pipefail

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

usage() {
  echo "Usage: $0 --name <client-name>"
  echo ""
  echo "  --name  Full client name (e.g. kamran-wbitt-com-laptop-office)"
  echo ""
  echo "To find the client name, run: ls ${CLIENTS_DIR}/"
  exit 0
}

CLIENT_NAME=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) CLIENT_NAME="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; usage ;;
  esac
done

if [[ -z "$CLIENT_NAME" ]]; then
  echo "Error: --name is required."
  usage
fi

CLIENT_DIR="${CLIENTS_DIR}/${CLIENT_NAME}"

if [[ ! -d "$CLIENT_DIR" ]]; then
  echo "Error: client '${CLIENT_NAME}' not found at ${CLIENT_DIR}"
  exit 1
fi

echo "=== Removing client: ${CLIENT_NAME} ==="

CLIENT_PUB=$(cat "${CLIENT_DIR}/client.key.pub")
ALLOCATED_IP=$(jq -r --arg name "$CLIENT_NAME" '.allocations | to_entries[] | select(.value == $name) | .key' "$DB")

wg set wg0 peer "${CLIENT_PUB}" remove
wg-quick save wg0

ARCHIVE_DIR="${WG_DIR}/archive"
mkdir -p "$ARCHIVE_DIR"
mv "$CLIENT_DIR" "${ARCHIVE_DIR}/${CLIENT_NAME}-$(date +%F_%H%M%S)"

if [[ -n "$ALLOCATED_IP" ]]; then
  jq --arg ip "$ALLOCATED_IP" '.allocations[$ip] = null' "$DB" > "${DB}.tmp" && mv "${DB}.tmp" "$DB"
  echo "Freed IP: ${ALLOCATED_IP}"
else
  echo "Warning: could not find allocated IP for ${CLIENT_NAME}"
fi

echo "=== Client ${CLIENT_NAME} removed ==="
echo "  Archived to: ${ARCHIVE_DIR}/"
