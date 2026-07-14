# WireGuard VPN — Operations Runbook

Day-to-day commands for running, maintaining, and troubleshooting a WireGuard VPN server. All commands run on the server unless stated otherwise.

## Contents

- [Status Checks](#status-checks)
- [Adding a Client](#adding-a-client)
- [Removing a Client](#removing-a-client)
- [Restarting WireGuard](#restarting-wireguard)
- [Updating the Server](#updating-the-server)
- [Rotating the Server Key](#rotating-the-server-key)
- [Backup](#backup)
- [Restore](#restore)
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

## Adding a Client

### 1. Generate keypair on the server

```bash
ssh root@<your-vps>

cd /etc/wireguard
umask 077
CLIENT_NAME="user02"                       # Change per user
wg genkey | tee "${CLIENT_NAME}.key" | wg pubkey > "${CLIENT_NAME}.key.pub"
```

### 2. Find the next available IP

```bash
wg show
# Peers use 10.0.0.2, 10.0.0.3, ... — pick the next one
```

### 3. Add the peer

```bash
NEXT_IP=10.0.0.3                           # Adjust
CLIENT_PUB=$(cat "${CLIENT_NAME}.key.pub")
wg set wg0 peer "${CLIENT_PUB}" allowed-ips "${NEXT_IP}/32"
wg-quick save wg0
```

### 4. Create and deliver the client config

```bash
SERVER_PUB=$(cat /etc/wireguard/server.key.pub)

cat > "${CLIENT_NAME}.conf" << EOF
[Interface]
Address = ${NEXT_IP}/24
PrivateKey = $(cat "${CLIENT_NAME}.key")
DNS = 1.1.1.1

[Peer]
PublicKey = ${SERVER_PUB}
Endpoint = <your-vps-ip-or-hostname>:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
```

```bash
# Generate a QR code for mobile users
qrencode -t ansiutf8 < "${CLIENT_NAME}.conf"

# Or download the file via SCP (from your local machine)
mkdir -p ~/vpn-clients
scp root@<your-vps>:/etc/wireguard/user02.conf ~/vpn-clients/
```

---

## Removing a Client

```bash
ssh root@<your-vps>

# Remove the peer
wg set wg0 peer <client-public-key> remove
wg-quick save wg0

# Delete their key files (optional)
rm /etc/wireguard/<client-name>.key
rm /etc/wireguard/<client-name>.key.pub
```

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

Do this if the server private key is compromised, or periodically as a security measure.

1. Generate a new keypair:
   ```bash
   cd /etc/wireguard
   umask 077
   wg genkey | tee server.key | wg pubkey > server.key.pub
   ```

2. Regenerate the server config with the new private key:
   ```bash
   # Use the same PostUp/PostDown and Address as your original config
   # Replace PrivateKey line with: PrivateKey = $(cat server.key)
   ```

3. Restart WireGuard:
   ```bash
   systemctl restart wg-quick@wg0
   ```

4. Send every client the **new server public key**:
   ```bash
   cat /etc/wireguard/server.key.pub
   ```

5. Each client must update their config's `[Peer] PublicKey` to the new value.

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

## Troubleshooting

### Client can't connect

| Possible cause | Check / Fix |
|----------------|-------------|
| Port blocked | `nc -zu <vps-ip> 51820` from an external machine. Should succeed. |
| Peer not added | `wg show` on server — does the client public key appear? |
| Firewall blocking | Check cloud firewall allows UDP 51820 inbound. |
| Config error | Verify client config has the correct server public key, endpoint IP, and private key. |

### No internet through the tunnel

| Possible cause | Check / Fix |
|----------------|-------------|
| IP forwarding off | `sysctl net.ipv4.ip_forward` should return `1` |
| NAT rule missing | `iptables -t nat -L POSTROUTING -v` — should show MASQUERADE on your interface |
| Wrong interface | Run `ip route show default`, confirm the interface in PostUp matches |
| Client AllowedIPs | Client config must have `AllowedIPs = 0.0.0.0/0` for full tunnel |

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

### Cannot SSH after firewall change

Use DigitalOcean's Recovery Console (in the web UI) to fix the firewall rules. Always keep the recovery console as a fallback.
