# snell

A self-contained bash management script for three proxy protocols on a Linux VPS:

- **Snell** (v4 / v5 / v6 Beta) — official binaries from `dl.nssurge.com`
- **VLESS + Reality** — via [sing-box](https://github.com/SagerNet/sing-box); no domain, no certificate, no port 80
- **AnyTLS** — via sing-box, with two clearly separated TLS modes: self-signed, or a real certificate for your own domain

It also has one-click BBR congestion control setup.

## Usage

Download the script to the server and run it as root:

```bash
curl -fsSL -o /root/snell https://raw.githubusercontent.com/githubh01/snell/main/snell
chmod +x /root/snell
sudo /root/snell
```

The first run installs a shortcut command, so afterwards you can just run:

```bash
sudo hardy
```

If you previously saved this script as `/root/snell.sh`, that path still works —
the shortcut installer accepts both names. Nothing needs to be reinstalled.

## What the menu offers

Each protocol has its own submenu (install, update, change port/credentials,
status, logs, uninstall). The top level also offers combined deployments —
all three protocols at once, with or without binding your domain certificate
to AnyTLS, optionally preceded by enabling BBR.

## How certificates work here

The three protocols have genuinely different certificate needs, and the script
keeps them separate:

| Protocol | Needs a domain? | Needs a certificate? | Needs port 80? |
|---|---|---|---|
| Snell | No | No (not a TLS protocol) | No |
| VLESS + Reality | No | No | No |
| AnyTLS | Only in "real certificate" mode | Yes (self-signed or real) | Only for HTTP-01 |

**Reality does not use your certificate by design.** It borrows the TLS
handshake of an unrelated third-party site (the "masquerade SNI", e.g.
`www.microsoft.com`). That site must *not* resolve to your server. Installing
Reality never runs certbot.

**AnyTLS owns all certificate logic.** Self-signed mode needs nothing external;
clients simply have to skip certificate verification. Real-certificate mode
runs pre-flight checks (domain validity, DNS resolution, DNS pointing at this
host for HTTP-01, port 80 availability, system clock sanity, ACME API
reachability) *before* calling certbot, prints certbot's real error if it
fails, and offers to fall back to self-signed rather than leaving a broken
service.

## Reliability behaviour

- **Nothing reports success until it is verified.** Every install validates its
  generated config with `sing-box check`, starts the unit, confirms the service
  is active, and confirms the port is actually listening. A failure prints the
  failing step, the underlying error, what to check, and the exact `journalctl`
  command to see more.
- **Client info is read back from disk.** Share links are generated from the
  config the server actually runs, then cross-checked field by field, so client
  and server cannot drift apart.
- **Re-running an install is safe.** Each module detects whether it is not
  installed, healthy, missing its binary, missing its unit, or holding a broken
  config, and offers to keep existing settings instead of overwriting them.
  Configs are backed up with a timestamp before being replaced.
- **Updates preserve settings.** Updating a binary never changes ports,
  passwords, PSKs, UUIDs or keys.
- **Uninstall is scoped.** Each module removes only its own files; Let's Encrypt
  certificates and the other two protocols are left untouched.

## Verifying a deployment

```bash
# Snell
systemctl status snell && ss -tlnp | grep snell
journalctl -u snell -e --no-pager

# VLESS + Reality
systemctl status vless-reality && /etc/vless-reality/sing-box check -c /etc/vless-reality/config.json
journalctl -u vless-reality -e --no-pager

# AnyTLS
systemctl status anytls && /etc/AnyTLS/sing-box check -c /etc/AnyTLS/config.json
journalctl -u anytls -e --no-pager
```

## Files

| Path | Contents |
|---|---|
| `/etc/snell/users/snell-main.conf` | Snell port + PSK |
| `/etc/vless-reality/config.json` | Reality inbound (UUID, private key) |
| `/etc/vless-reality/public.key` | Reality public key (needed for client links) |
| `/etc/AnyTLS/config.json` | AnyTLS inbound (password, cert paths) |
| `/etc/AnyTLS/certs/` | Self-signed or copied Let's Encrypt certificates |

Do not publish any of these: they contain PSKs, passwords and private keys.
