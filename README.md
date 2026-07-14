# WireGuard VPN — Step by Step HOWTO

A complete, reproducible guide to deploying a WireGuard VPN server on DigitalOcean (or any VPS) and connecting clients. Every command is copy-paste ready. Replace `<placeholders>` with your own values.

## Table of Contents

1. [Overview](#overview)
2. [Prerequisites](#prerequisites)
3. [Provision the VPS](#1-provision-the-vps)
4. [Server Setup](#2-server-setup)
5. [Add Your First Client](#3-add-your-first-client)
6. [Client Setup](#4-client-setup-by-platform)
7. [Verify It Works](#5-verify-it-works)
8. [Next Steps](#6-next-steps)

---

## Overview

```
┌──────────────────────┐    UDP 51820     ┌──────────────────────┐
│  Client Devices       │─────────────────│   VPS (VPN Server)    │
│  (Laptops, Phones)    │  encrypted tunnel │   WireGuard + NAT    │
│                        │                  │                      │
│  All traffic routed   │                  │   Public IP: X.X.X.X │
│  via tunnel (0.0.0.0)│                  │                      │
└──────────────────────┘                  └──────────────────────┘
```

**How it works**: WireGuard creates an encrypted tunnel between each client and the server. The server performs NAT (masquerading) so all client traffic appears to originate from the server's public IP. DNS is forced through the tunnel to prevent leaks.

## Prerequisites

| Item | Details |
|------|---------|
| VPS | Any cloud provider. 1 vCPU, 1 GB RAM, 25 GB storage is enough for 50+ users |
| OS | Fedora 40+ or Ubuntu 22.04+ (this guide uses Fedora) |
| Domain (optional) | A DNS A record pointing to your VPS IP (easier than remembering an IP) |
| SSH key | For server access. Password auth is disabled. |
| Port | UDP 51820 must be open on the VPS firewall |

---

## 1. Provision the VPS

### 1a. Create a Droplet (DigitalOcean)

1. Log into DigitalOcean → Create Droplet
2. Choose **Fedora 44 (Cloud Edition)** or **Ubuntu 24.04 LTS**
3. Plan: **Basic** — 1 vCPU, 1 GB RAM ($6/month)
4. Region: Choose a US region for US IP (nyc1, sfo3, etc.)
5. Authentication: **SSH Key** — add your public key
6. Create the droplet

### 1b. Set up DNS (optional but recommended)

Add an A record at your DNS provider:

```
vpn  IN  A  <your-droplet-public-ip>
```

### 1c. Configure Cloud Firewall

In DigitalOcean → Networking → Cloud Firewalls:

| Direction | Protocol | Port | Source |
|-----------|----------|------|--------|
| Inbound | UDP | 51820 | `0.0.0.0/0` (or your country's IP ranges) |
| Inbound | TCP | 22 | Your IP only |
| Inbound | ICMP | — | `0.0.0.0/0` (optional, for ping) |

Assign this firewall to your droplet.

---

## 2. Server Setup

Run these commands **on the VPS** (SSH in first).

### 2a. Connect

```bash
ssh root@<your-vps-ip-or-hostname>
```

### 2b. Identify your network interface

```bash
ip route show default
# Look for "dev <interface>" — typically ens3, eth0, or ens5
# Note it down: you will need it for the NAT rule.
```

### 2c. Install WireGuard

**Fedora:**
```bash
dnf install -y wireguard-tools iptables-nft
```

**Ubuntu/Debian:**
```bash
apt update && apt install -y wireguard iptables
```

### 2d. Generate server keys

```bash
cd /etc/wireguard
umask 077
wg genkey | tee server.key | wg pubkey > server.key.pub
```

Save your public key — you will need it for every client config:

```bash
cat server.key.pub
# Example output: x27U9wWI92F/wo7aIQLvrQ+i79FXTg4ekKqvcx1IWnM=
```

### 2e. Create the server config

Replace `<interface>` with your interface from step 2b.

```bash
cat > /etc/wireguard/wg0.conf << WGEOF
[Interface]
Address = 10.0.0.1/24
ListenPort = 51820
PrivateKey = $(cat /etc/wireguard/server.key)

PostUp = iptables -A FORWARD -i wg0 -j ACCEPT
PostUp = iptables -A FORWARD -o wg0 -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -o <interface> -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT
PostDown = iptables -D FORWARD -o wg0 -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o <interface> -j MASQUERADE
WGEOF
```

### 2f. Enable IP forwarding

```bash
echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-wireguard.conf
sysctl -p /etc/sysctl.d/99-wireguard.conf
```

### 2g. Open the firewall port

**If using firewalld (Fedora default):**
```bash
firewall-cmd --add-port=51820/udp --permanent
firewall-cmd --reload
```

**If using ufw (Ubuntu):**
```bash
ufw allow 51820/udp
```

**If using the cloud firewall only** (no host firewall): skip this step. Just ensure the cloud firewall allows UDP 51820.

### 2h. Start WireGuard

```bash
systemctl enable --now wg-quick@wg0
```

### 2i. Verify

```bash
wg show
```

Expected output:

```
interface: wg0
  public key: <your-server-public-key>
  private key: (hidden)
  listening port: 51820
```

No peers yet — that is normal. You will add them next.

---

## 3. Add Your First Client

### 3a. Generate a client keypair on the server

```bash
cd /etc/wireguard
umask 077
CLIENT_NAME="user01"
wg genkey | tee "${CLIENT_NAME}.key" | wg pubkey > "${CLIENT_NAME}.key.pub"
```

### 3b. Add the peer to the server

```bash
CLIENT_PUB=$(cat /etc/wireguard/"${CLIENT_NAME}.key.pub")
wg set wg0 peer "${CLIENT_PUB}" allowed-ips 10.0.0.2/32
wg-quick save wg0
```

(Next client gets `10.0.0.3/32`, then `10.0.0.4/32`, and so on.)

### 3c. Create the client config

```bash
cat > "/etc/wireguard/${CLIENT_NAME}.conf" << WGEOF
[Interface]
Address = 10.0.0.2/24
PrivateKey = $(cat /etc/wireguard/${CLIENT_NAME}.key)
DNS = 1.1.1.1

[Peer]
PublicKey = $(cat /etc/wireguard/server.key.pub)
Endpoint = <your-vps-ip-or-hostname>:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
WGEOF
```

### 3d. Transfer the config to the client machine

**Via SCP (download from server to your local machine):**
```bash
scp root@<your-vps>:/etc/wireguard/user01.conf .
```

**Via QR code (for mobile):**
```bash
qrencode -t ansiutf8 < /etc/wireguard/user01.conf
```

---

## 4. Client Setup (by Platform)

### Windows

1. Download from [wireguard.com/install](https://www.wireguard.com/install/)
2. Open WireGuard → **Import tunnel(s) from file**
3. Select the `.conf` file
4. Click **Activate**

### macOS

1. Download from [wireguard.com/install](https://www.wireguard.com/install/) or App Store
2. Open WireGuard → **Import tunnel(s) from file**
3. Select the `.conf` file
4. Click **Activate**

### iOS / Android

1. Install WireGuard from App Store / Play Store
2. Tap **+** → **Create from file or archive** (or **Scan from QR code**)
3. Select the `.conf` file or scan the QR code
4. Tap **Activate**

### Linux (command line)

```bash
# Copy the .conf file to /etc/wireguard/
sudo cp user01.conf /etc/wireguard/wg-client.conf

# Connect
sudo wg-quick up wg-client

# Disconnect
sudo wg-quick down wg-client
```

---

## 5. Verify It Works

While connected to the VPN:

```bash
curl ifconfig.me
# Should show your VPS public IP, NOT your local IP

nslookup google.com
# Should show 1.1.1.1 as the resolver (no DNS leak)

# Check for DNS leaks
curl https://ipleak.net
# All detected IPs should be from your VPS location
```

### Server-side verification

```bash
# Show active peers and traffic counters
wg show

# Show transfer stats per peer
wg show wg0 transfer

# View server logs
journalctl -u wg-quick@wg0 --no-pager -n 20
```

---

## 6. Next Steps

- [ ] Add more clients (repeat section 3 for each user)
- [ ] Restrict the cloud firewall to specific source IP ranges
- [ ] Set up server monitoring (ping, `wg show` cron job)
- [ ] Schedule regular OS updates
- [ ] Back up `/etc/wireguard/` off-server

For day-to-day operations (adding/removing clients, troubleshooting, key rotation), see [runbook.md](runbook.md).
