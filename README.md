# WireGuard VPN Server — Automated Setup & Management

A reproducible, script-driven WireGuard VPN solution for teams that need traffic to originate from a specific geographic location.

## Why this exists

Some online services are only available or only function correctly when accessed from a specific country or region. A VPN server in that region lets a team route their traffic through it, making their requests appear to come from that location.

This project provides a complete, automated solution: from provisioning a bare VPS to managing client configs at scale. Every operation is scripted so anyone on the team can add a user, rotate keys, or restore from backup without deep WireGuard knowledge.

## What is included

| What | Details |
|------|---------|
| **Server bootstrap** | One script turns a bare VPS into a running WireGuard server |
| **Client management** | Add, delete, and email configs with a single command |
| **IP allocation** | Automatically tracks which IPs are in use and reuses freed ones |
| **Key rotation** | Regenerate the server key and all client configs in one step |
| **Split tunnel / kill switch** | Route only the target service through the tunnel, or block it if the tunnel drops |
| **Platform coverage** | Client setup instructions for Windows, macOS, Linux, iOS, Android |
| **Runbook** | Complete operations guide with troubleshooting |

## Quickstart

```bash
# Copy the repo to a new VPS and bootstrap
ssh root@<your-vps>
cd /root
scp -r <your-machine>:/path/to/vpn-solution-with-wireguard /root/
cd /root/vpn-solution-with-wireguard
cp vpn.conf.example vpn.conf
nano vpn.conf
./support-files/initial-setup.sh

# Add a team member
./support-files/add-client.sh --email user@example.com --device laptop --alias office

# Email them their config
./support-files/email-config.sh --name user-example-com-laptop-office --email user@example.com
```

## Documentation

| File | What it covers |
|------|----------------|
| [runbook.md](runbook.md) | Complete guide: setup, clients, operations, troubleshooting |
| [architecture-decisions.md](architecture-decisions.md) | Why specific choices were made |
| `support-files/` | All scripts and the email template |
