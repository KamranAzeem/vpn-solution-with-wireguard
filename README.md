# WireGuard VPN — Quickstart

This is a one-page quickstart. For the full guide, see [runbook.md](runbook.md).

---

## One-Time Server Setup

```bash
# Provision a VPS (DO, AWS, etc.) with Fedora 44 or Ubuntu 24.04 LTS
# Open UDP 51820 in the cloud firewall

# Copy the repo to the server
scp -r vpn-solution-with-wireguard root@<your-vps>:/root/

# Configure
ssh root@<your-vps>
cd /root/vpn-solution-with-wireguard
cp vpn.conf.example vpn.conf
nano vpn.conf             # Set WG_INTERFACE, WG_ENDPOINT, FROM_EMAIL

# Bootstrap the server
./support-files/initial-setup.sh

# Verify
wg show
```

## Adding a Client

```bash
cd /root/vpn-solution-with-wireguard
./support-files/add-client.sh \
  --email user@example.com \
  --device laptop \
  --alias office
```

## Delivering the Config

```bash
# Email it
./support-files/email-config.sh --name user-example-com-laptop-office --email user@example.com

# Or download via SCP
scp root@<your-vps>:/etc/wireguard/clients/user-example-com-laptop-office/user-example-com-laptop-office.conf .
```

---

See [runbook.md](runbook.md) for: client setup by platform, verification, IPv6, kill switch, operations, troubleshooting.
