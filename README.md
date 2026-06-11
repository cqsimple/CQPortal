## Server Details

- **Host:** Vultr VPS, Debian 12 (Bookworm)
- **Public IP:** 207.148.10.72 (interface enp1s0, NOT eth0)
- **Portal access:** http://10.9.0.1/portal/  (WireGuard wg0 only — not public)
- **Warning page:** http://10.9.0.1:8082/  (shown for blocked HTTP destinations)
- **Database:** MariaDB `portal` — tables: `users`, `clients`, `onprem_links`
- **Shared server:** Co-resides with Bridge_Phone (OpenVPN tun0 10.8.0.0/16,
  WireGuard wg0 10.9.0.0/16, site-dashboard on 10.9.0.1:8080)

## Deployment (fresh server)

```bash
# 1. Copy files to server
scp server/*.sh server/cqsimple_logo.png root@<server-ip>:/root/

# 2. Fix line endings (if copied from Windows)
sed -i 's/\r//' /root/*.sh

# 3. Run setup
bash /root/setup_login_system_debian.sh

# 4. Deploy logo + generate/firewall scripts
cp /root/cqsimple_logo.png /var/www/html/portal/cqsimple_logo.png
cp /root/cqsimple_logo.png /var/www/html/portal-warning/cqsimple_logo.png
cp /root/generate_instances_debian.sh /usr/local/bin/generate_instances.sh
cp /root/portal_firewall.sh /usr/local/bin/portal_firewall.sh
chmod +x /usr/local/bin/generate_instances.sh /usr/local/bin/portal_firewall.sh

# 5. Set Vultr API key in /usr/local/bin/generate_instances.sh
#    (must be whitelisted in Vultr dashboard for this server's IP)

# 6. Generate pages (also rebuilds firewall whitelist)
bash /usr/local/bin/generate_instances.sh
```

## WireGuard Configuration

Full-tunnel required so all dealer traffic exits via the portal's public IP
(needed for remote VPS firewall rules to allow access by source IP):

```ini
[Peer]
AllowedIPs = 0.0.0.0/0
```

Remote VPS systems should allow: `ufw allow from 207.148.10.72 to any port 80`

## Network Notes

- This server uses `enp1s0`, NOT `eth0` — masquerade rules must reference
  `enp1s0` or NAT/forwarding silently fails.
- MariaDB root login uses `mysql_native_password` (not socket auth):
  `ALTER USER 'root'@'localhost' IDENTIFIED VIA mysql_native_password USING PASSWORD('NewRootPass123!');`
- iptables-legacy is required:
  `update-alternatives --set iptables /usr/sbin/iptables-legacy`

## SSH Access (Admin Team Only)

The Master Instances page includes SSH buttons (Vultr instances + on-prem
systems) using a `kitty://` custom protocol. See `client-tools/` for the
one-time Windows setup per team member.

---
*CQ Simple LLC — 2026*
READMEEOF
