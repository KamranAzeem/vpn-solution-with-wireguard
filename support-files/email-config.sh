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
  echo "  2. Configure /root/.msmtprc with your SMTP relay settings:"
  echo "       account default"
  echo "       host <smtp.your-provider.com>"
  echo "       port 587             (or 465 for SSL/TLS)"
  echo "       auth on"
  echo "       from ${FROM_EMAIL}"
  echo "       user ${FROM_EMAIL}"
  echo "       password <smtp-password>"
  echo "       tls on"
  echo "       tls_starttls on     (use 'off' for port 465)"
  echo "       logfile /var/log/msmtp.log"
  echo ""
  echo "     For Gmail, generate an App Password at:"
  echo "     https://myaccount.google.com/apppasswords"
  exit 1
}

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

# Build email body from template if available, otherwise use inline default
CLIENT_IP=$(jq -r --arg n "$CLIENT_NAME" '.allocations | to_entries[] | select(.value == $n) | .key' "$DB" 2>/dev/null || echo "unknown")

if [[ -f "$TEMPLATE" ]]; then
  BODY=$(cat "$TEMPLATE")
else
  BODY="Hi,

Your WireGuard VPN config is attached.

To import:
  1. Install WireGuard from https://www.wireguard.com/install/
  2. Open the app and import the attached config file
  3. Activate the tunnel

Server endpoint: ${WG_ENDPOINT:-vpn.do.wbitt.com}:${WG_PORT:-51820}
Your IP: ${CLIENT_IP}"
fi

# Attach and send
if [[ "$ENCRYPT_CONFIG" == "true" && "$PLAIN" == "false" ]]; then
  echo -n "Encryption password (share out of band): "
  read -s ENC_PASS
  echo ""
  gpg --batch --yes --passphrase "$ENC_PASS" --symmetric --cipher-algo AES256 "$CONFIG_FILE"

  ATTACHMENT="${CONFIG_FILE}.gpg"
  ATTACH_FILENAME="${CLIENT_NAME}.conf.gpg"
  echo "  Config encrypted: ${ATTACH_FILENAME}"
else
  ATTACHMENT="$CONFIG_FILE"
  ATTACH_FILENAME="${CLIENT_NAME}.conf"
  echo "  Config attached as plaintext"
fi

{
  echo "From: WireGuard VPN <${FROM_EMAIL}>"
  echo "To: ${RECIPIENT}"
  echo "Subject: ${SUBJECT}"
  echo "MIME-Version: 1.0"
  echo "Content-Type: multipart/mixed; boundary=\"==BOUND_$(date +%s)\""
  echo ""
  echo "--==BOUND_$(date +%s)"
  echo "Content-Type: text/plain; charset=utf-8"
  echo ""
  echo "${BODY}"
  echo ""
  echo "--==BOUND_$(date +%s)"
  echo "Content-Type: application/octet-stream; name=\"${ATTACH_FILENAME}\""
  echo "Content-Disposition: attachment; filename=\"${ATTACH_FILENAME}\""
  echo "Content-Transfer-Encoding: base64"
  echo ""
  base64 "$ATTACHMENT"
  echo ""
  echo "--==BOUND_$(date +%s)--"
} | msmtp --account=gmail -t

echo ""
echo "=== Email sent to ${RECIPIENT} ==="
echo "  Attachment: ${ATTACH_FILENAME}"
