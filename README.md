# snell

A self-contained bash management script for three proxy protocols on a Linux VPS:

- **Snell** (v4 / v5 / v6 Beta) — official binaries from `dl.nssurge.com`
- **VLESS + Reality** — via [sing-box](https://github.com/SagerNet/sing-box), no domain or certificate required
- **AnyTLS** — plain mode, or secured with your own domain certificate (HTTP-01, Cloudflare DNS-01, or an existing Let's Encrypt cert)

It also has one-click BBR congestion control setup.

## Usage

Download the script to the server and run it as root:

```bash
curl -fsSL -o /root/snell.sh https://raw.githubusercontent.com/githubh01/snell/main/snell.sh
chmod +x /root/snell.sh
sudo /root/snell.sh
```

The first run installs a shortcut command, so afterwards you can just run:

```bash
sudo hardy
```

From the menu you can install each protocol separately (Snell / VLESS+Reality / AnyTLS management), deploy all three at once (with or without binding your own domain certificate to AnyTLS), enable BBR, restart services, and view each protocol's client config (share link + QR code URL).

Note: Reality mode does not use your own certificate — it borrows a real site's TLS handshake — so only AnyTLS actually consumes a domain certificate.
