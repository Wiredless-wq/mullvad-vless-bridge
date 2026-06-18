# Mullvad VLESS Bridge

Unofficial VPS installer for a VLESS Reality server that sends outbound traffic through Mullvad.

> This project is not affiliated with Mullvad VPN, 3x-ui, Xray, Happ, or any VPS provider.

## License

Licensed under the [GNU Affero General Public License v3.0](LICENSE).

Commercial use is allowed only under the terms of the AGPLv3. Modified versions must remain under the same license and provide source code to users.

## Documentation

| Language | Guide |
| --- | --- |
| Русский | [docs/ru/README.md](docs/ru/README.md) |
| English | [docs/en/README.md](docs/en/README.md) |

## What You Get

- one install script for a fresh Debian 12 or Ubuntu 24.04 VPS;
- two VLESS Reality nodes in one subscription: `RU - Mullvad - Reality` and `Global - Mullvad - Reality`;
- two optional Happ profiles: `RU` and `Global`;
- Mullvad runs on the server, so DAITA, Multihop, Quantum Resistance and Lockdown Mode remain available.

## Quick Install

Run as `root` on a fresh VPS:

```bash
curl -fsSLo /root/install-mullvad-vless-bridge.sh \
  https://raw.githubusercontent.com/Wiredless-wq/mullvad-vless-bridge/main/ops/scripts/install-mullvad-vless-bridge.sh
chmod +x /root/install-mullvad-vless-bridge.sh
/root/install-mullvad-vless-bridge.sh
```

The script asks for your Mullvad account number and prints a subscription link for Happ or another VLESS Reality app.

## Repository Layout

```text
docs/ru/README.md                         Russian guide
docs/en/README.md                         English guide
ops/scripts/install-mullvad-vless-bridge.sh
profiles/happ/ru.json
profiles/happ/global.json
```

Use a fresh VPS. The script changes firewall, DNS, SSH, systemd, Mullvad and 3x-ui/Xray settings.
