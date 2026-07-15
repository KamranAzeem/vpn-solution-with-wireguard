# WireGuard VPN — Operations Runbook

Day-to-day commands for running, maintaining, and troubleshooting a WireGuard VPN server. All commands run on the server unless stated otherwise.

## Contents

- [Status Checks](#status-checks)
- [Directory Structure](#directory-structure)
- [Initial Setup (New Server)](#initial-setup-new-server)
- [Running Scripts](#running-scripts)
- [Adding a Client](#adding-a-client)
- [Removing a Client](#removing-a-client)
- [Delivering a Config](#delivering-a-config)
- [Restarting WireGuard](#restarting-wireguard)
- [Updating the Server](#updating-the-server)
- [Rotating the Server Key](#rotating-the-server-key)
- [Backup](#backup)
- [Restore](#restore)
- [Expanding the IP Pool](#expanding-the-ip-pool)
- [Troubleshooting](#troubleshooting)

---

## Status Checks

```bash
# Show all peers and traffic
wg show

# Live transfer stats (bytes sent/received per peer)
wg show wg0 transfer

# Service status
systemctl status wg-quick@wg0

# Check IP forwarding is enabled
sysctl net.ipv4.ip_forward

# View recent logs
journalctl -u wg-quick@wg0 --no-pager -n 30

# Follow logs live
journalctl -u wg-quick@wg0 -f
```

---

## Directory Structure

```
# Repo (clones/pulled on the server, outside /etc/wireguard/)
/root/vpn-solution/
├── vpn.conf                    # Config — edit this before setup
├── architecture-decisions.md   # Design rationale
├── README.md                   # End-user guide
├── runbook.md                  # Operations guide
└── support-files/
    ├── initial-setup.sh        # One-shot server bootstrap
    ├── add-client.sh
    ├── delete-client.sh
    ├── rotate-server-key.sh
    └── email-config.sh

# Runtime data (created by initial-setup.sh and scripts, inside WG_DIR)
/etc/wireguard/
├── server.key                  # Server private key
├── server.key.pub              # Server public key
├── wg0.conf                    # Server config with all [Peer] sections
├── ip-allocations.json         # IP allocation database
├── clients/                    # Per-client keypairs and configs
│   └── <client-name>/
│       ├── client.key
│       ├── client.key.pub
│       └── <client-name>.conf
└── archive/                    # Deleted clients moved here
```

---

## Initial Setup (New Server)

These steps bootstrap a bare VPS. The repo stays at `/root/vpn-solution/` — nothing is copied into `/etc/wireguard/` except runtime data (keys, config, DB).

### 1. Clone the repo on the server

```bash
ssh root@<your-vps>
cd /root
# Copy the repo (or git clone if hosted)
scp -r <your-machine>:/path/to/vpn-solution /root/
```

### 2. Configure

Edit `vpn.conf` with your server's details:

```bash
cd /root/vpn-solution
nano vpn.conf
```

Set at minimum: `WG_INTERFACE` (run `ip route` on the VPS to find it), `WG_ENDPOINT` (your hostname or IP), and `FROM_EMAIL`.

### 3. Run initial setup

```bash
./support-files/initial-setup.sh
```

The script will:

1. Install `wireguard-tools`, `iptables-nft`, and `jq`
2. Create `clients/` and `archive/` inside `WG_DIR` (default: `/etc/wireguard/`)
3. Generate the IP allocation DB from the subnet in `vpn.conf`
4. Generate server keys
5. Write `wg0.conf`
6. Enable IP forwarding
7. Open the firewall port (if firewalld is active)
8. Start WireGuard

### 4. Verify

```bash
wg show
```

### 5. Configure DigitalOcean Cloud Firewall

- Inbound: UDP 51820 from `0.0.0.0/0`
- Inbound: TCP 22 from your IP only

---

## Running Scripts

All scripts live in the repo at `/root/vpn-solution/support-files/` and are run from there. They read `vpn.conf` (one directory up) to find `WG_DIR` and other settings.

```bash
cd /root/vpn-solution
./support-files/add-client.sh ...
```

Scripts require `jq` and `wg-quick` on the server. The email script additionally requires `msmtp` and a Gmail App Password.

---

## Adding a Client

SSH to the server and run the script from the repo:

```bash
ssh root@<your-vps>
cd /root/vpn-solution
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

## Removing a Client

```bash
ssh root@<your-vps>
cd /root/vpn-solution
./support-files/delete-client.sh --name user-example-com-laptop-office
```

To find the exact client name:

```bash
ls /etc/wireguard/clients/
```

The script removes the peer from WireGuard, frees the IP in the DB, and moves the client directory to `archive/`.

---

## Delivering a Config

### Option A — Encrypted email (automatic)

Requires msmtp configured with Gmail SMTP. See the script header for setup.

```bash
ssh root@<your-vps>
cd /root/vpn-solution
./support-files/email-config.sh \
  --name user-example-com-laptop-office \
  --email user@example.com
```

You will be prompted for an encryption password. The config is GPG-encrypted and emailed as an attachment. Share the password out of band.

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

**Security warning**: The `.conf` file contains the private key in plaintext. Never send it over unencrypted channels.

---

## Restarting WireGuard

**Warning**: This briefly disconnects all clients.

```bash
systemctl restart wg-quick@wg0
```

For changes that don't need a restart (adding/removing peers), use `wg set` instead — zero downtime.

---

## Updating the Server

```bash
ssh root@<your-vps>

# Fedora
dnf update -y

# Ubuntu
apt update && apt upgrade -y

# Reboot if a kernel update was applied
# reboot

# After reboot, verify WG came back
systemctl status wg-quick@wg0
wg show
```

---

## Rotating the Server Key

Do this if the server private key is compromised, or periodically as a security measure. The script handles everything:

```
ssh root@<your-vps>
/root/vpn-solution/support-files/rotate-server-key.sh
```

What it does:
1. Backs up the existing server keys
2. Generates a new server keypair
3. Rewrites `wg0.conf` with the new private key
4. Regenerates all client configs in `clients/<name>/` with the new server public key
5. Restarts WireGuard

**After rotation**: every client must reimport their config. The new server public key is displayed at the end of the script.

---

## Backup

```bash
# Create a timestamped archive
tar czf /root/wireguard-backup-$(date +%F).tar.gz /etc/wireguard/
```

**Store this off-server** — download to your local machine or upload to secure storage. Without it, you cannot recover if the VPS is destroyed.

---

## Restore

```bash
# On a fresh server
scp <your-machine>:/path/to/wireguard-backup-<date>.tar.gz root@<new-vps>:/root/
tar xzf /root/wireguard-backup-<date>.tar.gz -C /
systemctl enable --now wg-quick@wg0
```

Make sure `net.ipv4.ip_forward` is set and the firewall allows UDP 51820.

---

## Expanding the IP Pool

When the IP pool runs out (all IPs from `.2` to `.254` are allocated), you need a larger subnet.

### On a fresh VPN (before any clients)

Edit `ip-allocations.json` and change the `pool` and all IPs to a larger range, e.g. `10.0.0.0/16`:

```bash
# Regenerate the DB with a new subnet
ssh root@<your-vps>
python3 -c "
import json

network = '10.0.0'
allocations = {}
for i in range(1, 255):
    ip = f'{network}.{i}'
    allocations[ip] = 'server' if i == 1 else None

with open('/etc/wireguard/ip-allocations.json') as f:
    db = json.load(f)

db['pool'] = '10.0.0.0/24'
db['server'] = '10.0.0.1'
db['allocations'] = allocations

with open('/etc/wireguard/ip-allocations.json', 'w') as f:
    json.dump(db, f, indent=2)
"
```

Then update `/etc/wireguard/wg0.conf` with the new server IP and restart.

### If clients already exist

You need a different approach: add a second pool. The current scripts only manage a single `ip-allocations.json`. To support multiple pools, a future enhancement would be needed.

For now, expand the pool by switching to a `/23` subnet which doubles the IPs. Regenerate the DB manually following the pattern above.

---

## Troubleshooting

### Client can't connect

| Possible cause | Check / Fix |
|----------------|-------------|
| Port blocked | `nc -zu <vps-ip> 51820` from an external machine. Should succeed. |
| Peer not added | `wg show` on server — does the client public key appear? |
| Firewall blocking | Check cloud firewall allows UDP 51820 inbound. |
| Config error | Verify client config has the correct server public key, endpoint IP, and private key. |
| Client tools not installed | Run `which wg-quick` — if empty, install wireguard-tools (dnf/apt/pacman) |

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
| IPv6 not disabled on client | Follow the per-OS instructions in README section 8 to disable IPv6 system-wide |
| IPv6 re-enabled after reboot | Verify `/etc/sysctl.d/99-disable-ipv6.conf` exists and is loaded (Linux) |
| Client still shows IPv6 address | Run `ip -6 addr show scope global` — should show nothing. If it does, IPv6 is still active |

### DNS leaks

| Possible cause | Check / Fix |
|----------------|-------------|
| Missing DNS line | Client config must include `DNS = 1.1.1.1` under `[Interface]` |
| Browser using DoH | Some browsers bypass the OS DNS. Check browser DNS settings. |

Verify:

```bash
# While connected
nslookup google.com
# Resolver should be 1.1.1.1

# Full leak test
curl https://ipleak.net
```

### Slow performance

| Possible cause | Check / Fix |
|----------------|-------------|
| Server CPU | `top` or `htop` on the VPS — if CPU is pinned, upgrade the droplet |
| Latency | `ping <vps-ip>` from client — high latency means a farther server location |
| Congestion | `wg show wg0 transfer` — if transfer is high, bandwidth may be saturated |
| MTU issues | Lower MTU in client config: `MTU = 1280` under `[Interface]` |

### After server reboot

```bash
# Check WG came up
systemctl status wg-quick@wg0

# If not started:
systemctl enable --now wg-quick@wg0

# Verify IP forwarding survived reboot
sysctl net.ipv4.ip_forward
```

If IP forwarding is off after reboot, make sure `/etc/sysctl.d/99-wireguard.conf` exists and is loaded.

### Proxy is unreachable

| Possible cause | Check / Fix |
|----------------|-------------|
| VPN tunnel is down | Run `wg show` — no handshake means the proxy IP is unreachable. Reconnect the tunnel. |
| danted service not running | `ssh root@<your-vps> systemctl status danted` |
| Firewall blocking port 1080 | `iptables -L INPUT -v` on the server — confirm `tcp dpt:1080` is ACCEPT on `wg0` |
| Wrong proxy IP | The SOCKS proxy IP must be the WG server tunnel IP (`192.168.111.1`), not the public IP |

### Sensitive service still accessible outside the tunnel (Option A — static IP)

| Possible cause | Check / Fix |
|----------------|-------------|
| `AllowedIPs` still set to `0.0.0.0/0` | Change it to the specific IP range of the service |
| iptables rules not applied | Run `iptables -L OUTPUT -v` — check for REJECT rules on the service IP range |
| Interface name mismatch | Verify `%i` in PostUp matches the actual interface name (e.g. `wg-client`) |

### Sensitive service still accessible outside the tunnel (Option B — proxy)

| Possible cause | Check / Fix |
|----------------|-------------|
| Browser not using the proxy | Check browser proxy settings — must be `SOCKS5 192.168.111.1:1080` |
| PAC file not loaded | If using PAC, verify the file is accessible and the domain matches the rule |
| DNS not proxied | Check **Proxy DNS when using SOCKS v5** in browser settings |

### Cannot SSH after firewall change

Use DigitalOcean's Recovery Console (in the web UI) to fix the firewall rules. Always keep the recovery console as a fallback.
