# Mullvad VLESS Bridge: Install And Use

Unofficial script for a VPS. It installs a VLESS Reality server and routes outbound traffic through Mullvad.

> This project is not affiliated with Mullvad VPN, 3x-ui, Xray, Happ, or any VPS provider.

## License

Licensed under the [GNU Affero General Public License v3.0](../../LICENSE).

Commercial use is allowed only under the terms of the AGPLv3. Modified versions must remain under the same license and provide source code to users.

## Result

After installation you get:

- one subscription link for Happ or another VLESS Reality app;
- two nodes in the same subscription:
  - `RU - Mullvad - Reality` - primary option for restrictive networks;
  - `Global - Mullvad - Reality` - fallback or primary option for regular networks;
- two optional Happ profiles:
  - [`profiles/happ/ru.json`](../../profiles/happ/ru.json);
  - [`profiles/happ/global.json`](../../profiles/happ/global.json);
- outbound traffic through Mullvad, not through the VPS IP;
- Mullvad features available on the server: DAITA, Multihop, Quantum Resistance and Lockdown Mode.

## How It Works

```text
Phone or computer
  -> VLESS Reality
  -> your VPS
  -> Mullvad on the VPS
  -> internet
```

The user connects to your VPS, not directly to Mullvad. VLESS Reality receives the connection on the VPS, then Mullvad carries the outbound traffic.

Mullvad runs as a normal host service. This keeps DAITA, Multihop, Quantum Resistance and Lockdown Mode available.

To keep SSH, VLESS and the subscription link reachable after Lockdown Mode is enabled, the script adds special rules only for public service ports. User traffic is not sent through those rules; it exits through Mullvad.

## Requirements

- fresh Debian 12 or Ubuntu 24.04 VPS;
- SSH access as `root`;
- public IPv4;
- active Mullvad account;
- provider firewall allows TCP ports:
  - `22` for SSH;
  - `80` for certificate issuing;
  - `443` for the `RU` node;
  - `8443` for the `Global` node;
  - `2096` for the subscription link.

> Do not run the script on a server with important existing configuration. It changes firewall, DNS, SSH, systemd, Mullvad and 3x-ui/Xray settings.

If `/root/.ssh/authorized_keys` already contains SSH keys, the script disables password login for `root`. If there are no keys, password login stays enabled so you do not lose access to a fresh VPS.

## Install

There are two installation options.

### Option 1: From A Published GitHub Repository

Log in to the VPS as `root`:

```bash
ssh root@VPS_IP
```

Replace `VPS_IP` with your server IP address.

On the VPS, run:

```bash
curl -fsSLo /root/install-mullvad-vless-bridge.sh \
  https://raw.githubusercontent.com/Wiredless-wq/mullvad-vless-bridge/main/ops/scripts/install-mullvad-vless-bridge.sh
chmod +x /root/install-mullvad-vless-bridge.sh
/root/install-mullvad-vless-bridge.sh
```

This command downloads the script from `Wiredless-wq/mullvad-vless-bridge`.

### Option 2: Copy The Local Script To The VPS

Before publishing the repository, copy the script from your computer to the VPS.

On your computer, open the project folder:

```bash
cd /home/mark/Documents/Dev_MullvadVless/Mullvad-VLESS-GitHub
```

Copy the script to the server:

```bash
scp -P 22 ops/scripts/install-mullvad-vless-bridge.sh root@VPS_IP:/root/
```

If SSH says `REMOTE HOST IDENTIFICATION HAS CHANGED`, and you are sure you reinstalled this VPS yourself, remove the old host key:

```bash
ssh-keygen -R VPS_IP
```

Then repeat the `scp` command.

Log in to the server:

```bash
ssh root@VPS_IP
```

Run the installer:

```bash
chmod +x /root/install-mullvad-vless-bridge.sh
/root/install-mullvad-vless-bridge.sh
```

The script asks for the Mullvad account number:

```text
Mullvad account number:
```

At the end it prints the subscription link:

```text
https://DOMAIN:2096/sub/SUB_ID
```

Save this link. Import it into Happ or another VLESS Reality app.

If a previous installation stopped halfway and you need to start from a clean installer state, run:

```bash
RESET_INSTALL=1 /root/install-mullvad-vless-bridge.sh
```

## Connect In Happ

1. Open Happ.
2. Add the subscription link printed by the script.
3. Two nodes will appear: `RU - Mullvad - Reality` and `Global - Mullvad - Reality`.

## Happ Profiles

Profiles are separate from the subscription link. They configure DNS and routing inside Happ.

How to use:

1. Import the subscription link.
2. Import the needed Happ profile.
3. Select `RU - Mullvad - Reality` or `Global - Mullvad - Reality`.
4. Turn on the VPN in Happ.

The global profile uses Mullvad DNS over HTTPS: `https://dns.mullvad.net/dns-query`. The hostname and IP are listed in the official Mullvad guide: <https://mullvad.net/en/help/dns-over-https-and-dns-over-tls>.

## Verify

On the VPS:

```bash
mullvad status -v
systemctl is-active x-ui mullvad-daemon mullvad-connect mullvad-vps-bypass
ss -tlnp | grep -E ':(22|443|8443|2096)'
curl -s "https://DOMAIN:2096/sub/SUB_ID" | base64 -d
```

For a test after connecting, open:

```text
https://am.i.mullvad.net/connected
```

## Re-run

If installation stops halfway, fix the reported issue and run the same file again:

```bash
/root/install-mullvad-vless-bridge.sh
```

The script stores state here:

```text
/var/lib/mullvad-vless-bridge/install.env
```

It reuses the generated keys, UUIDs and subscription link.

To regenerate everything:

```bash
RESET_INSTALL=1 /root/install-mullvad-vless-bridge.sh
```

## Logs / Backups

```text
/var/log/mullvad-vless-install.log
/var/lib/mullvad-vless-bridge/install.env
/root/mullvad-vless-installer-backups/
```

## Limits

- One VPS means one bridge. If the VPS IP is blocked, use a new VPS.
