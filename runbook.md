# WireGuard VPN — Complete Guide

All commands run on the server unless stated otherwise. Replace `<placeholders>` with your own values.

---

## Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Cloud Firewall / Security Group](#cloud-firewall--security-group)
- [Directory Structure](#directory-structure)
- [Scripts Overview](#scripts-overview)
- [Quickstart (New Server)](#quickstart-new-server)
- [Naming Convention](#naming-convention)
- [Adding a Client](#adding-a-client)
- [Client Setup (by Platform)](#client-setup-by-platform)
- [Delivering a Config](#delivering-a-config)
- [Verifying the Connection](#verifying-the-connection)
- [Disable IPv6 on the Client](#disable-ipv6-on-the-client)
- [Removing a Client](#removing-a-client)
- [Targeted Kill Switch (Split Tunnel)](#targeted-kill-switch-split-tunnel)
- [Source IP Restriction](#source-ip-restriction)
- [Operations](#operations)
- [Expanding the IP Pool](#expanding-the-ip-pool)
- [Server IPv6 (Optional)](#server-ipv6-optional)
- [Next Steps](#next-steps)
- [Troubleshooting](#troubleshooting)

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

WireGuard creates an encrypted tunnel between each client and the server. The server performs NAT (masquerading) so all client traffic appears to originate from the server's public IP. DNS is forced through the tunnel to prevent leaks.

Architecture decisions are documented in `architecture-decisions.md`.

---

## Prerequisites

| Item | Details |
|------|---------|
| VPS | Any cloud provider. 1 vCPU, 1 GB RAM, 25 GB storage is enough for 50+ users |
| OS | Fedora 40+ or Ubuntu 22.04+ (this guide uses Fedora) |
| Domain (optional) | A DNS A record pointing to your VPS IP |
| SSH key | For server access. Password auth is disabled. |
| Port | UDP 51820 must be open on the cloud firewall |
| firewalld | Must be disabled (conflicts with iptables NAT rules used by WireGuard) |
| SELinux | Must be permissive or disabled (Enforcing can block PostUp/PostDown iptables calls) |

---

## Cloud Firewall / Security Group

Before the VPN can work, your cloud provider must allow UDP 51820 traffic to the VPS.

| Provider | Resource | Inbound Rules |
|----------|----------|---------------|
| DigitalOcean | Cloud Firewall | UDP 51820 from `0.0.0.0/0`, TCP 22 from your IP only |
| AWS | Security Group | Same — attach to the EC2 instance |
| Azure | NSG | Same — associate with the VM subnet or NIC |
| Hetzner | Firewall | Same — apply to the server |

**Notes**:

- The cloud firewall is the first line of defense. It filters traffic before it reaches the OS.
- WireGuard uses iptables rules for NAT (masquerading) via PostUp/PostDown in wg0.conf.
- **firewalld** should be disabled — it manages nftables rules that can conflict with iptables.
- **SELinux Enforcing** can block PostUp/PostDown from executing iptables commands. Set it to permissive.
- If you rely solely on a cloud firewall, no host-level firewall is needed.

---

## Directory Structure

```
# Repo (cloned on the server, outside /etc/wireguard/)
vpn-solution-with-wireguard/
├── vpn.conf                    # Config — edit this before setup
├── vpn.conf.example            # Template — copy to vpn.conf and edit
├── architecture-decisions.md   # Design rationale
├── README.md                   # Quickstart guide
├── runbook.md                  # This file — complete guide
└── support-files/
    ├── initial-setup.sh        # One-shot server bootstrap
    ├── add-client.sh
    ├── delete-client.sh
    ├── rotate-server-key.sh
    ├── email-config.sh
    └── email-template.md       # Email body (not a script)

# Runtime data (created by initial-setup.sh and scripts)
/etc/wireguard/
├── server.key                  # Server private key
├── server.key.pub              # Server public key
├── wg0.conf                    # Server config with all [Peer] sections
├── ip-allocations.json         # IP allocation database
├── vpn.conf                    # Site config (deployed by initial-setup.sh)
├── clients/                    # Per-client keypairs and configs
│   └── <client-name>/
│       ├── client.key
│       ├── client.key.pub
│       └── <client-name>.conf
└── archive/                    # Deleted clients moved here
```

---

## Scripts Overview

| Script | What it does | When to run |
|--------|-------------|-------------|
| `initial-setup.sh` | Bootstraps a bare VPS: checks deps, generates keys, writes config, starts WG | Once on a new server |
| `add-client.sh` | Creates a client: allocates IP, generates keys, writes config, adds peer | For each new team member device |
| `delete-client.sh` | Removes a client: deletes peer, frees IP, archives files | When a device is decommissioned |
| `rotate-server-key.sh` | Regenerates server key and all client configs | After a key compromise or periodically |
| `email-config.sh` | Emails a client config (encrypted or plaintext) | After creating a client |
| `email-template.md` | Email message body (not a script) | Referenced by email-config.sh |

All scripts source `vpn.conf` for site-specific settings. They require `jq` and `wg-quick` on the server. The email script additionally requires `msmtp` and a Gmail App Password.

---

## Quickstart (New Server)

### 1. Provision a VPS

Create a DigitalOcean droplet (or any VPS):

1. Log in → Create Droplet
2. Choose **Fedora 44 (Cloud Edition)** or **Ubuntu 24.04 LTS**
3. Plan: Basic — 1 vCPU, 1 GB RAM ($6/month)
4. Region: Choose a US region for US IP
5. Authentication: **SSH Key** — add your public key
6. Create the droplet

Set up DNS (optional):

```
vpn  IN  A  <your-droplet-public-ip>
```

### 2. Clone the repo on the server

```bash
ssh root@<your-vps>
cd /root
# Copy the repo (or git clone if hosted)
scp -r <your-machine>:/path/to/vpn-solution-with-wireguard /root/
```

### 3. Configure

```bash
cd /root/vpn-solution-with-wireguard
cp vpn.conf.example vpn.conf
nano vpn.conf
```

Set at minimum: `WG_INTERFACE` (run `ip route` on the VPS to find it), `WG_ENDPOINT`, and `FROM_EMAIL`.

### 4. Run initial setup

```bash
./support-files/initial-setup.sh
```

The script checks that packages are installed (exits if missing), warns about firewalld/SELinux, creates the directory structure, generates the IP DB, creates server keys, writes wg0.conf, enables IP forwarding, and starts WireGuard.

### 5. Verify

```bash
wg show
```

### 6. Configure Cloud Firewall

| Direction | Protocol | Port | Source | Purpose |
|-----------|----------|------|--------|---------|
| Inbound | UDP | 51820 | `0.0.0.0/0` | WireGuard VPN |
| Inbound | TCP | 22 | Your IP only | SSH access |

---

## Naming Convention

Each client is identified by email (flattened to kebab), device type, and alias.

**Formula**: `<email-kebab>-<device-type>-<alias>`

| Email | Device | Alias | Result |
|-------|--------|-------|--------|
| kamran@wbitt.com | laptop | office | `kamran-wbitt-com-laptop-office` |
| kamran@wbitt.com | laptop | personal | `kamran-wbitt-com-laptop-personal` |
| kamran@wbitt.com | phone | personal | `kamran-wbitt-com-phone-personal` |

Alias allows multiple devices of the same type (office laptop, personal laptop, etc.).

Helper function:

```bash
email_to_name() {
  echo "$1" | tr '@.' '-' | tr -s '-'
}
```

Email `kamran@wbitt.com` → `kamran-wbitt-com`. Append `-<device>-<alias>`.

Supported device types: `laptop`, `desktop`, `phone`, `tablet`, `server`.

---

## Adding a Client

```bash
ssh root@<your-vps>
cd /root/vpn-solution-with-wireguard
./support-files/add-client.sh \
  --email user@example.com \
  --device laptop \
  --alias office
```

The script:
1. Generates the client name from email-device-alias (e.g. `user-example-com-laptop-office`)
2. Finds the first available IP from `ip-allocations.json`
3. Generates a WireGuard keypair in `clients/<name>/`
4. Creates the client config file
5. Adds the peer to the running WireGuard interface
6. Saves the config and updates the IP DB

**Example output:**
```
=== Adding client: user-example-com-laptop-office ===
Allocated IP: 192.168.111.2
  Config:     /etc/wireguard/clients/user-example-com-laptop-office/user-example-com-laptop-office.conf
  Public key: <base64-key>
```

---

## Client Setup (by Platform)

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
sudo cp <client-name>.conf /etc/wireguard/wg-client.conf
sudo wg-quick up wg-client
```

---

## Delivering a Config

### Option A — Automated email

```bash
cd /root/vpn-solution-with-wireguard
./support-files/email-config.sh \
  --name user-example-com-laptop-office \
  --email user@example.com
```

By default, the config is GPG-encrypted and you are prompted for a password. Pass `--plain` to send unencrypted. The email body is read from `support-files/email-template.md`.

### Option B — SCP from server

```bash
# On your local machine
mkdir -p ~/vpn-clients
scp root@<your-vps>:/etc/wireguard/clients/user-example-com-laptop-office/user-example-com-laptop-office.conf ~/vpn-clients/
```

### Option C — QR code (mobile only)

```bash
ssh root@<your-vps>
qrencode -t ansiutf8 < /etc/wireguard/clients/user-example-com-laptop-office/user-example-com-laptop-office.conf
```

**Security warning**: The `.conf` file contains the private key in plaintext.

---

## Verifying the Connection

While connected to the VPN:

```bash
# IPv4 check — should show VPS IP
curl -4 ifconfig.me

# DNS check
nslookup google.com
# Should show 1.1.1.1 as the resolver

# Full leak test
curl https://ipleak.net
# Should show your VPS IP and location, not your local one
```

### Server-side verification

```bash
# Show active peers and traffic counters
wg show
wg show wg0 transfer
journalctl -u wg-quick@wg0 --no-pager -n 20
```

### Performance impact

Real-world test (720p YouTube on a Fedora laptop):

| Metric | Without VPN | With VPN |
|--------|-------------|----------|
| CPU | ~5% | ~7% |
| Bandwidth | ~200 kbps | ~600 kbps |
| RAM | ~30% | ~30% |

Overhead is minimal.

---

## Disable IPv6 on the Client

Without disabling IPv6, your IPv6 traffic bypasses the tunnel and leaks your real IP.

### Linux

```bash
cat > /etc/sysctl.d/99-disable-ipv6.conf << EOF
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
sudo sysctl -p /etc/sysctl.d/99-disable-ipv6.conf
```

### Windows

Control Panel → Network and Sharing Center → Change adapter settings → right-click adapter → Properties → uncheck **Internet Protocol Version 6 (TCP/IPv6)**.

### macOS

```bash
networksetup -setv6off Wi-Fi
```

### Verify IPv6 is disabled

```bash
curl -6 ifconfig.me
# Expected: curl: (7) Couldn't connect to server

ip -6 addr show scope global
# Should show nothing
```

---

## Removing a Client

```bash
ssh root@<your-vps>
cd /root/vpn-solution-with-wireguard
./support-files/delete-client.sh --name user-example-com-laptop-office
```

To find the exact client name:

```bash
ls /etc/wireguard/clients/
```

The script removes the peer from WireGuard, frees the IP in the DB, and moves the client directory to `archive/`.

---

## Targeted Kill Switch (Split Tunnel)

A full kill switch blocks everything when the VPN drops. The targeted approach blocks only the sensitive US service — everything else routes directly.

**Important**: This protects against **accidental exposure** (a brief tunnel drop). It does not prevent deliberate bypass on an unmanaged personal device.

The right approach depends on the service.

### Option A — Static IP Service

Replace `AllowedIPs = 0.0.0.0/0` with the specific IP range and add a block rule:

```ini
[Interface]
Address = 192.168.111.2/24
PrivateKey = <private-key>
DNS = 1.1.1.1

PostUp = iptables -I OUTPUT -d 198.51.100.0/24 ! -o %i -j REJECT
PreDown = iptables -D OUTPUT -d 198.51.100.0/24 ! -o %i -j REJECT

[Peer]
PublicKey = <server-public-key>
Endpoint = vpn.do.wbitt.com:51820
AllowedIPs = 198.51.100.0/24
PersistentKeepalive = 25
```

Traffic to `198.51.100.x` is routed through the tunnel. If the tunnel drops, the REJECT rule catches it. Everything else goes direct.

### Option B — Dynamic / CDN-Backed Service

For services behind a CDN (Cloudflare, AWS, Akamai), install a SOCKS5 proxy on the VPS:

```bash
ssh root@<your-vps>
dnf install -y dante-server
```

Create `/etc/danted.conf`:

```
internal: 0.0.0.0 port = 1080
external: ens3
method: none
client pass { from: 0.0.0.0/0 to: 0.0.0.0/0; log: error; }
socks pass { from: 0.0.0.0/0 to: 0.0.0.0/0; log: error; }
```

```bash
systemctl enable --now danted
iptables -A INPUT -p tcp --dport 1080 -i wg0 -j ACCEPT
```

On the client, configure the browser to use `SOCKS5 192.168.111.1:1080` for the sensitive domain only (PAC file or SwitchyOmega).

---

## Source IP Restriction

By default, UDP 51820 is open to `0.0.0.0/0`. Restrict by adding source rules to your cloud firewall:

| Restriction | Rule | Effect |
|-------------|------|--------|
| Country-wide | Source: Pakistan IP ranges | Only users in Pakistan can connect |
| None | Source: `0.0.0.0/0` | Anyone with a valid config can connect |

**Tradeoff**: Restriction prevents a stolen config from being used outside the allowed region but blocks legitimate users when travelling. WireGuard's crypto already prevents unauthorized connections without a valid config.

To find Pakistan IP ranges:

```bash
whois -h whois.radb.net -- '-i origin AS17557' | grep route:
```

---

## Operations

### Status Checks

```bash
wg show
wg show wg0 transfer
systemctl status wg-quick@wg0
sysctl net.ipv4.ip_forward
journalctl -u wg-quick@wg0 --no-pager -n 30
```

### Restarting WireGuard

**Warning**: This briefly disconnects all clients.

```bash
systemctl restart wg-quick@wg0
```

For live changes (adding/removing peers), use `wg set` instead — zero downtime.

### Updating the Server

```bash
ssh root@<your-vps>

# Fedora
dnf update -y

# Ubuntu
apt update && apt upgrade -y

# Reboot if a kernel update was applied
# After reboot, verify WG came back
systemctl status wg-quick@wg0
wg show
```

### Rotating the Server Key

Do this if the server private key is compromised or periodically.

```bash
ssh root@<your-vps>
/root/vpn-solution-with-wireguard/support-files/rotate-server-key.sh
```

The script backs up old keys, generates new ones, rewrites wg0.conf, regenerates all client configs, and restarts WireGuard.

**After rotation**: every client must reimport their config.

### Backup

```bash
tar czf /root/wireguard-backup-$(date +%F).tar.gz /etc/wireguard/
```

**Store this off-server** — without it, you cannot recover if the VPS is destroyed.

### Restore

```bash
# On a fresh server
scp <your-machine>:/path/to/wireguard-backup-<date>.tar.gz root@<new-vps>:/root/
tar xzf /root/wireguard-backup-<date>.tar.gz -C /
systemctl enable --now wg-quick@wg0
```

Verify IP forwarding and firewall rules are set.

---

## Expanding the IP Pool

When the pool runs out (all 253 client IPs are allocated), you need a larger subnet.

### On a fresh VPN (no clients yet)

Regenerate `ip-allocations.json` with a new subnet, then update `wg0.conf`.

### If clients already exist

Switch to a `/23` subnet to double the pool. Regenerate the DB manually.

---

## Server IPv6 (Optional)

The server runs IPv4 only by default. To route IPv6 through the tunnel:

1. Power off the droplet in DO control panel → **Enable IPv6** → Power on
2. Update client config: `AllowedIPs = 0.0.0.0/0, ::/0`
3. Add IPv6 NAT rules (similar to existing iptables rules but using `ip6tables`)

---

## Next Steps

- [ ] Disable IPv6 on the client
- [ ] Verify no leaks
- [ ] Configure targeted kill switch for the sensitive service
- [ ] Consider source IP restriction
- [ ] Add more clients
- [ ] Set up server monitoring (ping, `wg show` cron job)
- [ ] Schedule regular OS updates
- [ ] Back up `/etc/wireguard/` off-server

---

## Troubleshooting

### Client can't connect

| Possible cause | Check / Fix |
|----------------|-------------|
| Port blocked | `nc -zu <vps-ip> 51820` from an external machine. Should succeed. |
| Peer not added | `wg show` on server — does the client public key appear? |
| Firewall blocking | Check cloud firewall allows UDP 51820 inbound. |
| Config error | Verify client config has the correct server public key, endpoint IP, and private key. |
| Client tools not installed | Run `which wg-quick` — if empty, install wireguard-tools |

### No internet through the tunnel

| Possible cause | Check / Fix |
|----------------|-------------|
| IP forwarding off | `sysctl net.ipv4.ip_forward` should return `1` |
| NAT rule missing | `iptables -t nat -L POSTROUTING -v` — should show MASQUERADE on your interface |
| Wrong interface | Run `ip route show default`, confirm the interface in PostUp matches |
| Client AllowedIPs | Client config must have `AllowedIPs = 0.0.0.0/0` for full tunnel |

### IPv4 works but IPv6 leaks real IP

| Possible cause | Check / Fix |
|----------------|-------------|
| IPv6 not disabled | Follow the per-OS instructions above |
| IPv6 re-enabled after reboot | Verify `/etc/sysctl.d/99-disable-ipv6.conf` loads on boot |
| Client still has IPv6 address | Run `ip -6 addr show scope global` — should show nothing |

### DNS leaks

| Possible cause | Check / Fix |
|----------------|-------------|
| Missing DNS line | Client config must include `DNS = 1.1.1.1` under `[Interface]` |
| Browser using DoH | Some browsers bypass the OS DNS. Check browser DNS settings. |

Verify:

```bash
nslookup google.com
curl https://ipleak.net
```

### Slow performance

| Possible cause | Check / Fix |
|----------------|-------------|
| Server CPU | `top` or `htop` — if pinned, upgrade the droplet |
| Latency | `ping <vps-ip>` — high latency means farther server location |
| Congestion | `wg show wg0 transfer` — check if bandwidth is saturated |
| MTU issues | Lower MTU in client config: `MTU = 1280` under `[Interface]` |

### After server reboot

```bash
systemctl status wg-quick@wg0
systemctl enable --now wg-quick@wg0  # if not started
sysctl net.ipv4.ip_forward
```

If IP forwarding is off, make sure `/etc/sysctl.d/99-wireguard.conf` exists.

### Proxy is unreachable

| Possible cause | Check / Fix |
|----------------|-------------|
| VPN tunnel is down | `wg show` — reconnect the tunnel |
| danted not running | `systemctl status danted` |
| Firewall blocking 1080 | Check `iptables -L INPUT -v` for `tcp dpt:1080` on wg0 |
| Wrong proxy IP | Proxy IP must be `192.168.111.1`, not the public IP |

### Cannot SSH after firewall change

Use DigitalOcean's Recovery Console (web UI) to fix the firewall rules.
