#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG="${REPO_DIR}/vpn.conf"
TEMPLATE="${SCRIPT_DIR}/email-template.md"

if [[ -f "$CONFIG" ]]; then
  source "$CONFIG"
else
  echo "Error: ${CONFIG} not found. Copy vpn.conf.example to vpn.conf and edit it."
  exit 1
fi

WG_DIR="${WG_DIR:-/etc/wireguard}"
CLIENTS_DIR="${WG_DIR}/clients"
DB="${WG_DIR}/ip-allocations.json"
FROM_EMAIL="${FROM_EMAIL:-vpn-admin@example.com}"
FROM_EMAIL_NAME="${FROM_EMAIL_NAME:-VPN admin}"
SMTP_ACCOUNT="${SMTP_ACCOUNT:-default}"
ENCRYPT_CONFIG="${ENCRYPT_CONFIG:-true}"

usage() {
  echo "Usage: $0 --name <client-name> --email <recipient-email> [--plain]"
  echo ""
  echo "  --name   Full client name"
  echo "  --email  Recipient's email address"
  echo "  --plain  Send config as plaintext (no GPG encryption)"
  echo ""
  echo "Prerequisites:"
  echo "  1. Install msmtp:  dnf install -y msmtp"
  echo "  2. Copy and edit the example config:"
  echo "       cp support-files/msmtprc.example ~/.msmtprc"
  echo "       nano ~/.msmtprc"
  echo "     chmod 600 ~/.msmtprc"
  echo "  3. Set SMTP_ACCOUNT in vpn.conf to match the account name"
  echo "     in ~/.msmtprc (e.g. SMTP_ACCOUNT=\"a2hosting\")"
  exit 1
}

# Check msmtp is installed
if ! command -v msmtp &>/dev/null; then
  echo "Error: msmtp not found. Install it: dnf install -y msmtp"
  exit 1
fi

CLIENT_NAME=""; RECIPIENT=""; PLAIN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)  CLIENT_NAME="$2"; shift 2 ;;
    --email) RECIPIENT="$2";   shift 2 ;;
    --plain) PLAIN=true; shift ;;
    *) echo "Unknown arg: $1"; usage ;;
  esac
done

if [[ -z "$CLIENT_NAME" || -z "$RECIPIENT" ]]; then
  echo "Error: --name and --email are required."
  usage
fi

CONFIG_FILE="${CLIENTS_DIR}/${CLIENT_NAME}/${CLIENT_NAME}.conf"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Error: config not found at ${CONFIG_FILE}"
  exit 1
fi

# Build email subject
SUBJECT="WireGuard VPN Config — ${CLIENT_NAME}"

# Build email body
CLIENT_IP=$(jq -r --arg n "$CLIENT_NAME" '.allocations | to_entries[] | select(.value == $n) | .key' "$DB")
if [[ -z "$CLIENT_IP" ]]; then
  CLIENT_IP="unknown"
fi
SERVER="${WG_ENDPOINT:-vpn.do.wbitt.com}"
PORT="${WG_PORT:-51820}"

if [[ -f "$TEMPLATE" ]]; then
  BODY=$(sed -e "s|__SERVER_ENDPOINT__|${SERVER}|g" \
             -e "s|__SERVER_PORT__|${PORT}|g" \
             -e "s|__CLIENT_IP__|${CLIENT_IP}|g" "$TEMPLATE")
else
  BODY="Hi,

Your WireGuard VPN config is attached.

To import:
  1. Install WireGuard from https://www.wireguard.com/install/
  2. Open the app and import the attached config file
  3. Activate the tunnel

Server endpoint: ${SERVER}:${PORT}
Your IP: ${CLIENT_IP}"
fi

# Attach and send
if [[ "$ENCRYPT_CONFIG" == "true" && "$PLAIN" == "false" ]]; then
  echo -n "Encryption password (share out of band): "
  read -s ENC_PASS
  echo ""
  gpg --batch --yes --passphrase-fd 0 --symmetric --cipher-algo AES256 "$CONFIG_FILE" <<<"$ENC_PASS"

  ATTACHMENT="${CONFIG_FILE}.gpg"
  ATTACH_FILENAME="${CLIENT_NAME}.conf.gpg"
  echo "  Config encrypted: ${ATTACH_FILENAME}"
else
  ATTACHMENT="$CONFIG_FILE"
  ATTACH_FILENAME="${CLIENT_NAME}.conf"
  echo "  Config attached as plaintext"
fi

BOUNDARY=$(date +%s%N)
{
  echo "From: ${FROM_EMAIL_NAME} <${FROM_EMAIL}>"
  echo "To: ${RECIPIENT}"
  echo "Subject: ${SUBJECT}"
  echo "MIME-Version: 1.0"
  echo "Content-Type: multipart/mixed; boundary=\"==BOUND_${BOUNDARY}\""
  echo ""
  echo "--==BOUND_${BOUNDARY}"
  echo "Content-Type: text/plain; charset=utf-8"
  echo ""
  echo "${BODY}"
  echo ""
  echo "--==BOUND_${BOUNDARY}"
  echo "Content-Type: application/octet-stream; name=\"${ATTACH_FILENAME}\""
  echo "Content-Disposition: attachment; filename=\"${ATTACH_FILENAME}\""
  echo "Content-Transfer-Encoding: base64"
  echo ""
  base64 "$ATTACHMENT"
  echo ""
  echo "--==BOUND_${BOUNDARY}--"
} | msmtp --account="${SMTP_ACCOUNT}" -t

echo ""
echo "=== Email sent to ${RECIPIENT} ==="
echo "  Attachment: ${ATTACH_FILENAME}"
