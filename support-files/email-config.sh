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
FROM_EMAIL="${FROM_EMAIL:-vpn-admin@example.com}"

usage() {
  echo "Usage: $0 --name <client-name> --email <recipient-email>"
  echo ""
  echo "  --name   Full client name"
  echo "  --email  Recipient's email address"
  echo ""
  echo "Prerequisites:"
  echo "  1. Install msmtp:  dnf install -y msmtp"
  echo "  2. Configure /root/.msmtprc:"
  echo "       account gmail"
  echo "       host smtp.gmail.com"
  echo "       port 587"
  echo "       auth on"
  echo "       from ${FROM_EMAIL}"
  echo "       user ${FROM_EMAIL}"
  echo "       password <app-password>"
  echo "       tls on"
  echo "       tls_starttls on"
  echo "       logfile /var/log/msmtp.log"
  echo "  3. App Password: https://myaccount.google.com/apppasswords"
  exit 1
}

CLIENT_NAME=""; RECIPIENT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)  CLIENT_NAME="$2"; shift 2 ;;
    --email) RECIPIENT="$2";   shift 2 ;;
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

echo -n "Encryption password (share out of band): "
read -s ENC_PASS
echo ""

gpg --batch --yes --passphrase "$ENC_PASS" --symmetric --cipher-algo AES256 "$CONFIG_FILE"

ENCRYPTED_FILE="${CONFIG_FILE}.gpg"
SUBJECT="WireGuard VPN Config — ${CLIENT_NAME}"
BODY="Hi,

Your WireGuard VPN config is attached.

To import:
  1. Install WireGuard from https://www.wireguard.com/install/
  2. Open the app and import the attached .conf file
  3. Activate the tunnel

Server endpoint: ${WG_ENDPOINT:-vpn.do.wbitt.com}:${WG_PORT:-51820}
Your IP: $(jq -r --arg n "$CLIENT_NAME" '.allocations | to_entries[] | select(.value == $n) | .key' "$DB")

The decryption password was shared with you separately."

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
  echo "Content-Type: application/octet-stream; name=\"${CLIENT_NAME}.conf.gpg\""
  echo "Content-Disposition: attachment; filename=\"${CLIENT_NAME}.conf.gpg\""
  echo "Content-Transfer-Encoding: base64"
  echo ""
  base64 "$ENCRYPTED_FILE"
  echo ""
  echo "--==BOUND_$(date +%s)--"
} | msmtp --account=gmail -t

echo ""
echo "=== Email sent to ${RECIPIENT} ==="
echo "  Config: ${CLIENT_NAME}.conf.gpg"
echo "Share the password out of band."
