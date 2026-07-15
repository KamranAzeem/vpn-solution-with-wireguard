# WireGuard VPN — Step by Step HOWTO

A complete, reproducible guide to deploying a WireGuard VPN server on DigitalOcean (or any VPS) and connecting clients. Every command is copy-paste ready. Replace `<placeholders>` with your own values.

## Table of Contents

1. [Overview](#overview)
2. [Prerequisites](#prerequisites)
3. [Cloud Firewall / Security Group](#cloud-firewall--security-group-configuration)
4. [Provision the VPS](#1-provision-the-vps)
4. [Server Setup](#2-server-setup)
5. [Naming Convention](#3-naming-convention)
6. [Add Your First Client](#4-add-your-first-client)
7. [Client Setup](#5-client-setup-by-platform)
8. [Verify It Works](#6-verify-it-works)
9. [Disable IPv6](#7-disable-ipv6-on-the-client)
10. [Verify No Leaks](#8-verify-no-leaks)
11. [Targeted Kill Switch](#9-targeted-kill-switch-split-tunnel)
12. [Source IP Restriction](#10-source-ip-restriction-optional)
13. [Next Steps](#11-next-steps)
14. [Server IPv6 (Optional)](#12-server-ipv6-optional)

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
| Port | UDP 51820 must be open on the cloud firewall / security group |
| firewalld | Must be disabled (conflicts with iptables NAT rules used by WireGuard) |
| SELinux | Must be permissive or disabled (Enforcing can block PostUp/PostDown iptables calls) |

---

## Cloud Firewall / Security Group Configuration

Before the VPN can work, your cloud provider must allow UDP 51820 traffic to the VPS.

| Provider | Resource | Inbound Rules |
|----------|----------|---------------|
| DigitalOcean | Cloud Firewall | UDP 51820 from `0.0.0.0/0`, TCP 22 from your IP only |
| AWS | Security Group | Same — attach to the EC2 instance |
| Azure | NSG (Network Security Group) | Same — associate with the VM subnet or NIC |
| Hetzner | Firewall | Same — apply to the server |
| Any VPS | OS-level firewall | Not needed if using cloud firewall (see notes below) |

**Notes**:

- The cloud firewall is the **first line of defense**. It filters traffic before it reaches the OS.
- WireGuard uses iptables rules for NAT (masquerading) via PostUp/PostDown in wg0.conf.
- **firewalld** should be disabled — it manages nftables rules that can conflict with iptables.
- **SELinux Enforcing** can block PostUp/PostDown from executing iptables commands. Set it to permissive.
- If you rely solely on a cloud firewall, no host-level firewall is needed.

---

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

## 3. Naming Convention

Each client is identified by the user's email (flattened to kebab), device type, and a descriptive alias.

**Formula**: `<email-kebab>-<device-type>-<alias>`

| Email | Device | Alias | Result |
|-------|--------|-------|--------|
| kamran@wbitt.com | laptop | office | `kamran-wbitt-com-laptop-office` |
| kamran@wbitt.com | laptop | personal | `kamran-wbitt-com-laptop-personal` |
| kamran@wbitt.com | phone | personal | `kamran-wbitt-com-phone-personal` |

The alias lets you have multiple devices of the same type (office laptop, personal laptop, Linux laptop, etc.).

Use this helper to flatten an email on the server:

```bash
email_to_name() {
  echo "$1" | tr '@.' '-' | tr -s '-'
}

# Example
email_to_name "kamran@wbitt.com"
# Output: kamran-wbitt-com
```

Supported device types: `laptop`, `desktop`, `phone`, `tablet`, `server`.

---

## 4. Add Your First Client

### 4a. Collect user info

Before you start, get the end-user's **email**, **device type**, and a short **alias** describing the device (e.g. office, personal, linux, home). Each device gets its own keypair and tunnel IP — sharing a config between devices causes them to fight the connection.

**Example**: Kamran has an office laptop and a personal laptop → two entries: `kamran-wbitt-com-laptop-office` and `kamran-wbitt-com-laptop-personal`.

### 4b. Generate a client keypair on the server

```bash
cd /etc/wireguard
umask 077

email_to_name() {
  echo "$1" | tr '@.' '-' | tr -s '-'
}

EMAIL="kamran@wbitt.com"
DEVICE="laptop"
ALIAS="office"
CLIENT_NAME="$(email_to_name "${EMAIL}")-${DEVICE}-${ALIAS}"

wg genkey | tee "${CLIENT_NAME}.key" | wg pubkey > "${CLIENT_NAME}.key.pub"
```

### 4c. Add the peer to the server

```bash
CLIENT_PUB=$(cat /etc/wireguard/"${CLIENT_NAME}.key.pub")
wg set wg0 peer "${CLIENT_PUB}" allowed-ips 10.0.0.2/32
wg-quick save wg0
```

For the sensitive service approach, replace `AllowedIPs` in step 4d with the service's IP range instead of `0.0.0.0/0`. See section 9 for details.

(Next client gets `10.0.0.3/32`, then `10.0.0.4/32`, and so on.)

### 4d. Create the client config

```bash
SERVER_PUB=$(cat /etc/wireguard/server.key.pub)

cat > "/etc/wireguard/${CLIENT_NAME}.conf" << WGEOF
[Interface]
Address = 10.0.0.2/24
PrivateKey = $(cat /etc/wireguard/${CLIENT_NAME}.key)
DNS = 1.1.1.1

[Peer]
PublicKey = ${SERVER_PUB}
Endpoint = <your-vps-ip-or-hostname>:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
WGEOF
```

### 4e. Deliver the config

**Security warning**: The `.conf` file contains the private key in plaintext. Do NOT send it over unencrypted channels (plain email, Slack, WhatsApp).

Recommended delivery methods (in order of security):

**Option A — Encrypted email attachment:**
```bash
# Encrypt the config with a password (AES256)
gpg --symmetric --cipher-algo AES256 "/etc/wireguard/${CLIENT_NAME}.conf"

# Send the .gpg file via email
# Share the decryption password out of band (phone call, Signal, etc.)
```

**Option B — SCP (admin downloads, then passes to user directly):**
```bash
mkdir -p ~/vpn-clients
scp root@<your-vps>:"/etc/wireguard/${CLIENT_NAME}.conf" ~/vpn-clients/
```
Transfer the file to the user via a secure channel (USB, encrypted chat, direct transfer).

**Option C — QR code (for mobile apps only, does not expose the key to email):**
```bash
qrencode -t ansiutf8 < "/etc/wireguard/${CLIENT_NAME}.conf"
```
The user scans the QR code directly in the WireGuard mobile app.

---

## 5. Client Setup (by Platform)

### Windows

1. Download and install from [wireguard.com/install](https://www.wireguard.com/install/)
2. Open WireGuard → **Import tunnel(s) from file**
3. Select the `.conf` file
4. Click **Activate**

### macOS

1. Download and install from [wireguard.com/install](https://www.wireguard.com/install/) or App Store
2. Open WireGuard → **Import tunnel(s) from file**
3. Select the `.conf` file
4. Click **Activate**

### iOS / Android

1. Install WireGuard from App Store / Play Store
2. Tap **+** → **Create from file or archive** (or **Scan from QR code**)
3. Select the `.conf` file or scan the QR code
4. Tap **Activate**

### Linux (command line)

Install the client tools:

```bash
# Fedora / RHEL / CentOS
sudo dnf install -y wireguard-tools

# Ubuntu / Debian
sudo apt update && sudo apt install -y wireguard

# Arch
sudo pacman -S wireguard-tools
```

Import and connect:

```bash
# Copy the .conf file to /etc/wireguard/
sudo cp <client-name>.conf /etc/wireguard/wg-client.conf

# Connect
sudo wg-quick up wg-client

# Disconnect
sudo wg-quick down wg-client
```

---

## 6. Verify It Works

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

## 7. Disable IPv6 on the Client

The WireGuard config above routes **IPv4 only** (`AllowedIPs = 0.0.0.0/0`). Without disabling IPv6, your IPv6 traffic bypasses the tunnel and leaks your real IP and location.

Disable IPv6 system-wide **before** connecting to the VPN.

### Linux

Edit `/etc/sysctl.d/99-disable-ipv6.conf` (create if missing):

```ini
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
```

Apply immediately:

```bash
sudo sysctl -p /etc/sysctl.d/99-disable-ipv6.conf
```

Verify:

```bash
cat /proc/sys/net/ipv6/conf/all/disable_ipv6
# Should output: 1
```

### Windows

1. Open **Control Panel → Network and Sharing Center → Change adapter settings**
2. Right-click your active network adapter → **Properties**
3. Uncheck **Internet Protocol Version 6 (TCP/IPv6)**
4. Click **OK**

### macOS

```bash
# Disable IPv6 on Wi-Fi (replace en0 with your interface name)
networksetup -setv6off Wi-Fi

# Or find your interface name
ifconfig
```

---

## 8. Verify No Leaks

With the tunnel **active** and IPv6 disabled:

```bash
# IPv4 check — should show VPS IP
curl -4 ifconfig.me

# IPv6 check — should fail (no route)
curl -6 ifconfig.me
# Expected: curl: (7) Couldn't connect to server

# Confirm IPv6 is disabled on the client
ip -6 addr show scope global
# Should show no global IPv6 addresses

# Full leak test (opens in browser)
curl https://ipleak.net
# Scroll down — the "Your IP addresses" section should only show IPv4 from your VPS
```

### Expected performance impact

Real-world test (720p YouTube on a Fedora laptop):

| Metric | Without VPN | With VPN |
|--------|-------------|----------|
| CPU | ~5% | ~7% |
| Bandwidth | ~200 kbps | ~600 kbps |
| RAM | ~30% | ~30% |

Overhead is minimal — the VPN is suitable for browsing, streaming, and general use.

---

For day-to-day operations (adding/removing clients, troubleshooting, key rotation), see [runbook.md](runbook.md). Helper scripts are available in `support-files/` and can be deployed to the server — see the runbook for instructions.

---

## 9. Targeted Kill Switch (Split Tunnel)

A full kill switch blocks everything when the VPN drops. That is too aggressive when you still want regular internet (email, search, news) to work normally. The right approach is a **targeted kill switch**: only the sensitive US service is blocked outside the tunnel; everything else routes directly.

**Important**: This protects against **accidental exposure** — a brief tunnel drop that causes the browser to retry over the normal connection. It does not prevent a user from deliberately turning off the VPN and accessing the service. That is a policy matter, not something a VPN can solve on an unmanaged personal device.

The right approach depends on the service:

- **Static IP range** (known, fixed IPs): split tunnel via `AllowedIPs` + iptables block on those specific IPs.
- **Dynamic domain** (CDN-backed, IPs change): SOCKS5 proxy on the VPN server — only the proxy traffic uses the tunnel.

---

### Option A — Static IP Service

For a service with a known, fixed IP range (e.g. `198.51.100.0/24`):

**Step 1 — Client config**

Replace `AllowedIPs = 0.0.0.0/0` with the specific IP range, and add a targeted block rule:

```ini
[Interface]
Address = 192.168.111.2/24
PrivateKey = <private-key>
DNS = 1.1.1.1

# Only block the sensitive IPs outside the tunnel
PostUp = iptables -I OUTPUT -d 198.51.100.0/24 ! -o %i -j REJECT
PreDown = iptables -D OUTPUT -d 198.51.100.0/24 ! -o %i -j REJECT

[Peer]
PublicKey = <server-public-key>
Endpoint = vpn.do.wbitt.com:51820
AllowedIPs = 198.51.100.0/24
PersistentKeepalive = 25
```

**How it works**:
- Traffic to `198.51.100.x` is routed through the tunnel. If the tunnel drops, the iptables REJECT rule catches it — the service becomes unreachable.
- Traffic to any other IP (Google, email, etc.) goes through the normal network interface. The internet works normally regardless of VPN state.

**Verify**:
```bash
# Confirm the sensitive IPs are routed through the tunnel
traceroute 198.51.100.1
# Should show 192.168.111.1 (WG server) as the first hop

# Confirm normal traffic bypasses the tunnel
traceroute 8.8.8.8
# Should show your home router (192.168.x.1), NOT the WG server
```

---

### Option B — Dynamic / CDN-Backed Service

For services behind a CDN (Cloudflare, AWS, Akamai) where IPs change frequently, IP-based rules are unreliable. The cleanest solution is a **SOCKS5 proxy on the VPN server**.

**Step 1 — Install a SOCKS5 proxy on the VPS**

```bash
ssh root@<your-vps>

dnf install -y dante-server
```

Create `/etc/danted.conf`:

```
internal: 0.0.0.0 port = 1080
external: ens3

method: none

client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: error
}

socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: error
}
```

Start the proxy:

```bash
systemctl enable --now danted
```

Now add a firewall rule to allow SOCKS5 connections through the tunnel (so the proxy is only reachable when the VPN is up):

```bash
iptables -A INPUT -p tcp --dport 1080 -i wg0 -j ACCEPT
```

**Step 2 — Client config**

Route only the tunnel traffic to the VPN (keep `AllowedIPs` on the specific tunnel subnet if using split, or keep `0.0.0.0/0` for full tunnel — the proxy handles the split):

```ini
[Interface]
Address = 192.168.111.2/24
PrivateKey = <private-key>
DNS = 1.1.1.1

[Peer]
PublicKey = <server-public-key>
Endpoint = vpn.do.wbitt.com:51820
AllowedIPs = 0.0.0.0/0        # All traffic through tunnel
PersistentKeepalive = 25
```

**Step 3 — Use the proxy for the sensitive service only**

**Firefox** — Settings → Network Settings → Configure proxy → **Manual proxy configuration**:
- SOCKS Host: `192.168.111.1` (the WG server IP)
- Port: `1080`
- Check **Proxy DNS when using SOCKS v5**
- Set **No proxy for**: everything except the sensitive domain

**Chrome / Edge** — Use a **PAC file** or extension (e.g. SwitchyOmega):
```javascript
function FindProxyForURL(url, host) {
  if (dnsDomainIs(host, "sensitive-service.com"))
    return "SOCKS5 192.168.111.1:1080";
  return "DIRECT";
}
```

**How it works**:
- The VPN tunnel is always active (all traffic routes through it).
- Only browser requests to the sensitive domain are forwarded to the SOCKS5 proxy.
- If the VPN drops, the proxy IP (`192.168.111.1`) becomes unreachable — the service cannot be reached.
- All other traffic works normally through the browser or other apps.

## 10. Source IP Restriction (Optional)

By default, UDP 51820 is open to `0.0.0.0/0`. Anyone with a valid client config can connect from anywhere.

If you want to restrict which networks can reach the VPN server (defense in depth), add source IP rules to your cloud firewall:

| Restriction level | DigitalOcean Cloud Firewall rule | Effect |
|-------------------|----------------------------------|--------|
| Country-wide | Source: Pakistan IP ranges | Only users in Pakistan can connect. Users travelling abroad are blocked. |
| City / ISP | Source: specific ISP netblocks | Tightest control, but requires knowing all relevant IP ranges. |
| None | Source: `0.0.0.0/0` | Anyone with a valid config can connect from anywhere. |

**Tradeoff**: Source IP restriction prevents a stolen config from being used outside the allowed region. But it also blocks legitimate users when they travel. WireGuard's crypto (unique keys per client) already prevents unauthorized connection without a valid config.

To find Pakistan IP ranges:

```bash
whois -h whois.radb.net -- '-i origin AS17557' | grep route:
```

(Repeat for other Pakistan ASNs: AS24439, AS38193, AS55803.)

---

## 11. Next Steps

- [ ] Disable IPv6 on the client (section 7)
- [ ] Verify no leaks (section 8)
- [ ] Enable kill switch (section 9)
- [ ] Add more clients (repeat section 4 for each user)
- [ ] Restrict the cloud firewall to specific source IP ranges
- [ ] Set up server monitoring (ping, `wg show` cron job)
- [ ] Schedule regular OS updates
- [ ] Back up `/etc/wireguard/` off-server

## 12. Server IPv6 (Optional)

The server runs IPv4 only by default. If you need to route IPv6 through the tunnel:

1. **Power off the droplet** in DO control panel → **Enable IPv6** → Power on
2. **Update client config**: `AllowedIPs = 0.0.0.0/0, ::/0`
3. **Add IPv6 NAT rules** on the server (similar to the existing iptables rules but using `ip6tables`)
