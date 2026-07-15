# Architecture Decisions

## Why WireGuard

Simple, fast, modern crypto. Built into the Linux kernel since 5.6. No CA, no certificate management, no daemon overhead. Single UDP port, quiet by default. The protocol has a tiny attack surface compared to OpenVPN or IPsec.

## Why Fedora (not Ubuntu)

The actual VPS was provisioned with Fedora 44 Cloud Edition. The docs were updated to cover both (`dnf` vs `apt` paths) but the canonical deployment is Fedora. Fedora has newer kernels, built-in WireGuard module, and excellent SELinux integration (though we disabled it per operator preference).

## Why 192.168.111.0/24

The original plan used 10.0.0.0/24. This was changed because DigitalOcean's private network uses the 10.x range (the VPS had 10.108.0.2). While no direct conflict existed (different subnet), 192.168.111.0/24 avoids any ambiguity with both DO's private network and common home/office LANs (192.168.0.x, 192.168.1.x). The .111 octet is easy to remember and unlikely to collide with existing infrastructure.

## Why Email-Based Naming + Device Type + Alias

Format: `<email-kebab>-<device-type>-<alias>` (e.g. `kamran-wbitt-com-laptop-office`)

- Email is deterministic and globally unique — no two users have the same
- Kebab form is filesystem-safe and shell-safe
- Device type distinguishes form factor (laptop, phone, etc.)
- Alias allows multiple devices of the same type (office vs personal laptop)
- The full name is self-documenting in logs and `wg show` output

## Why JSON as the IP Database (not SQLite or a relational DB)

The IP DB is a simple JSON object mapping IPs to client names. JSON was chosen because:
- Zero external dependencies (jq is already needed for other scripts)
- Human-readable and editable in an emergency
- Atomic updates via temp-file rename (`jq ... > tmp && mv tmp db`)
- Adequate for at most 253 records (a /24 subnet)
- No schema migrations, no server process, no locking complexity

## Why Split Tunnel / Proxy Instead of Full Tunnel

The user's primary need is US IP access for a specific service, not total privacy. A full tunnel (`0.0.0.0/0`) would route all traffic through the VPS, increasing latency for everyday browsing and making the machine unusable if the VPN drops. Split tunneling routes only the sensitive service through the tunnel, keeping everything else direct.

For static IP services, `AllowedIPs` + iptables REJECT rules handle this cleanly. For dynamic/CDN-backed services, a SOCKS5 proxy on the VPN server is used — the browser sends only the target domain through the proxy, everything else goes direct.

## Why SOCKS5 for Dynamic Domains

CDN-backed services (Cloudflare, AWS, Akamai) change IPs frequently, making static `AllowedIPs` rules unreliable. A SOCKS5 proxy on the VPN server (dante-server) provides a fixed endpoint (`192.168.111.1:1080`) that the browser routes specific domains through. PAC files or browser extensions handle domain-to-proxy mapping. If the VPN drops, the proxy IP becomes unreachable — the service is blocked.

## Why Separate Client Directories

Each client has its own directory under `/etc/wireguard/clients/<name>/` containing:
- `client.key` — private key
- `client.key.pub` — public key
- `<name>.conf` — ready-to-import config

This keeps `/etc/wireguard/` clean. The main directory only contains server keys and `wg0.conf`. Client management is done via scripts that operate on these directories. Backup and restore are per-client.

## Why GPG Encryption for Config Delivery

The `.conf` file contains the private key in plaintext. Sending it over email exposes the key. GPG symmetric encryption (`--symmetric --cipher-algo AES256`) encrypts the file before transmission. The decryption password is shared out of band (phone, Signal). The `email-config.sh` script automates this workflow.

## Why firewalld and SELinux Are Disabled

**firewalld** manages nftables rulesets. WireGuard uses iptables for NAT (PostUp/PostDown in wg0.conf). Running both firewalld and iptables simultaneously can cause conflicting rules — a firewalld reload can overwrite or clear the iptables NAT rules that WireGuard depends on, silently breaking the tunnel. Since the cloud firewall handles network-level filtering, a host firewall adds complexity without benefit. The operator explicitly requested no firewalld.

**SELinux** in Enforcing mode does not block WireGuard's kernel module directly. However, it can block the PostUp/PostDown iptables commands that wg-quick executes. Specifically:

- `wg-quick` calls iptables as a regular process to add NAT and forwarding rules.
- SELinux Enforcing with default targeted policy may deny these exec calls depending on the process context.
- This manifests as a tunnel that comes up (wg0 interface exists) but clients have no internet — the NAT rules were silently rejected.

Setting SELinux to permissive avoids this without fully disabling SELinux — it still logs denials but allows the operation. The operator explicitly requested no SELinux enforcement.

## Why IP Allocation DB is Managed via JSON (Not `wg show`)

`wg show` only shows the current runtime state. It does not persist across reboots or track which IPs are freed after a client is removed. The JSON DB is the authoritative record of which IPs are allocated and to whom. The `wg0.conf` file and the running WireGuard interface are derived from the DB, not the other way around.

## Why the Kill Switch Only Covers Accidental Exposure

The targeted kill switch (iptables REJECT on specific IPs, or SOCKS5 proxy) protects against a brief tunnel drop where the browser retries over the normal connection. It is not designed to prevent a user from deliberately turning off the VPN. On an unmanaged personal device, there is no technical solution for willful bypass — that is a policy and trust matter. The scripts and configs therefore focus on the accidental case: if the tunnel drops, the sensitive service becomes unreachable until the tunnel is restored.

## Why Source IP Restriction Is Optional

WireGuard requires the correct private key and server public key to establish a handshake. Without a valid config, nobody can connect — there is no password to guess, no brute-force surface. Restricting UDP 51820 to specific source IP ranges (e.g. Pakistan) adds defense in depth but prevents legitimate use when travelling. The default is open (`0.0.0.0/0`) with documentation on how to restrict if desired.

## Why Scripts Over Manual Commands

Every operation (add, delete, rotate, email) is scripted so that:
- Steps are consistent and repeatable
- The IP DB stays in sync with the running config
- A new operator can manage the VPN without deep WireGuard knowledge
- The scripts can be version-controlled alongside the docs
