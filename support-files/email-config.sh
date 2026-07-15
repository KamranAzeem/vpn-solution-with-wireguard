#!/usr/bin/env bash
set -euo pipefail

WG_DIR="/etc/wireguard"
CLIENTS_DIR="${WG_DIR}/clients"

usage() {
  echo "Usage: $0 --name <client-name> --email <recipient-email>"
  echo ""
  echo "  --name   Full client name (e.g. kamran-wbitt-com-laptop-office)"
  echo "  --email  Recipient's email address"
  echo ""
  echo "Prerequisites:"
  echo "  1. Install msmtp:  dnf install -y msmtp"
  echo "  2. Configure /root/.msmtprc:"
  echo "       account gmail"
  echo "       host smtp.gmail.com"
  echo "       port 587"
  echo "       auth on"
  echo "       from <your-email>@gmail.com"
  echo "       user <your-email>@gmail.com"
  echo "       password <app-password>"
  echo "       tls on"
  echo "       tls_starttls on"
  echo "       logfile /var/log/msmtp.log"
  echo "  3. Generate a Gmail App Password at:"
  echo "     https://myaccount.google.com/apppasswords"
  exit 1
}

CLIENT_NAME=""
RECIPIENT=""

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

CONFIG="${CLIENTS_DIR}/${CLIENT_NAME}/${CLIENT_NAME}.conf"

if [[ ! -f "$CONFIG" ]]; then
  echo "Error: config not found at ${CONFIG}"
  exit 1
fi

# Prompt for encryption password
echo -n "Enter encryption password (will be shared out of band): "
read -s ENC_PASS
echo ""

# Encrypt the config
gpg --batch --yes --passphrase "$ENC_PASS" --symmetric --cipher-algo AES256 "$CONFIG"

# Send email
ENCRYPTED_FILE="${CONFIG}.gpg"
SUBJECT="WireGuard VPN Config — ${CLIENT_NAME}"
BODY="Hi,

Your WireGuard VPN config is attached.

To import:
  1. Install WireGuard from https://www.wireguard.com/install/
  2. Open the app and import the attached .conf file
  3. Activate the tunnel

Server endpoint: $(jq -r '.endpoint // "vpn.do.wbitt.com"' /etc/wireguard/ip-allocations.json):51820
Your IP: $(jq -r --arg n "$CLIENT_NAME" '.allocations | to_entries[] | select(.value == $n) | .key' /etc/wireguard/ip-allocations.json)

The decryption password was shared with you separately.

This is an automated message from the VPN server."

{
  echo "From: WireGuard VPN <kamranazeem@gmail.com>"
  echo "To: ${RECIPIENT}"
  echo "Subject: ${SUBJECT}"
  echo "MIME-Version: 1.0"
  echo "Content-Type: multipart/mixed; boundary=\"==BOUNDARY_$(date +%s)\""
  echo ""
  echo "--==BOUNDARY_$(date +%s)"
  echo "Content-Type: text/plain; charset=utf-8"
  echo ""
  echo "${BODY}"
  echo ""
  echo "--==BOUNDARY_$(date +%s)"
  echo "Content-Type: application/octet-stream; name=\"${CLIENT_NAME}.conf.gpg\""
  echo "Content-Disposition: attachment; filename=\"${CLIENT_NAME}.conf.gpg\""
  echo "Content-Transfer-Encoding: base64"
  echo ""
  base64 "$ENCRYPTED_FILE"
  echo ""
  echo "--==BOUNDARY_$(date +%s)--"
} | msmtp --account=gmail -t

echo ""
echo "=== Email sent to ${RECIPIENT} ==="
echo "  Config: ${CLIENT_NAME}.conf (encrypted)"
echo ""
echo "Share the decryption password out of band (phone, Signal)."
