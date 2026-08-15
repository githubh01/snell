#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把真实的 Surge 配置脱敏成可公开托管的模版。

用法：
    python3 tools/sanitize_surge.py 我的配置.conf -o Surge.conf

脱敏内容：
  1. [Proxy] 里所有节点的服务器地址、密码/PSK/用户名、SNI 等敏感字段；
  2. 策略组 policy-path 的机场订阅链接（内含 token）；
  3. [MITM] 的 ca-passphrase 与 ca-p12（本地 CA 私钥）；
  4. [SSID Setting] 里的 Wi-Fi 名称。

保留内容：节点名、策略组结构、规则、Ruleset —— 拿到模版的人只需要
把占位符换成自己的信息即可直接使用。
"""

import argparse
import re
import sys

# 需要整体替换成占位符的字段（凭据类）
CREDENTIAL_KEYS = {
    "password": "YOUR_PASSWORD",
    "psk": "YOUR_PSK",
    "username": "YOUR_USERNAME",
    "token": "YOUR_TOKEN",
    "uuid": "YOUR_UUID",
    "ws-path": "/YOUR_WS_PATH",
    "obfs-host": "your-obfs-host.example.com",
    "sni": "your-sni-host.example.com",
    "server-cert-fingerprint-sha256": "YOUR_CERT_FINGERPRINT",
}

# 按协议给出更可读的凭据占位符
CREDENTIAL_BY_PROTO = {
    "snell": {"psk": "YOUR_SNELL_PSK"},
    "trojan": {"password": "YOUR_TROJAN_PASSWORD"},
    "hysteria2": {"password": "YOUR_HYSTERIA2_PASSWORD"},
    "anytls": {"password": "YOUR_ANYTLS_PASSWORD"},
    "ss": {"password": "YOUR_SS_PASSWORD"},
    "vmess": {"username": "YOUR_VMESS_UUID"},
}

# 不是节点定义、需要原样保留的 [Proxy] 行
PROXY_PASSTHROUGH = re.compile(r"^\s*(#|$)")

SUBSCRIPTION_PLACEHOLDER = (
    "https://your-subscription-host.example.com/subscribe?token=YOUR_SUBSCRIPTION_TOKEN"
)


BANNER = """# ============================================================
# Surge 模版配置（已脱敏，可公开）
# 所有 server-XX.example.com / YOUR_* 均为占位符，
# 使用前请替换成自己的节点信息，详见仓库 README。
# ============================================================

"""


class HostMasker:
    """把真实服务器地址映射成稳定的占位域名（同一地址始终得到同一占位符）。"""

    def __init__(self):
        self._mapping = {}

    def mask(self, host):
        host = host.strip()
        if not host:
            return host
        if host not in self._mapping:
            self._mapping[host] = "server-%02d.example.com" % (len(self._mapping) + 1)
        return self._mapping[host]

    @property
    def count(self):
        return len(self._mapping)


def split_fields(value):
    """按逗号切分节点参数，忽略引号内的逗号。"""
    fields, buf, quote = [], [], None
    for ch in value:
        if quote:
            buf.append(ch)
            if ch == quote:
                quote = None
        elif ch in "\"'":
            quote = ch
            buf.append(ch)
        elif ch == ",":
            fields.append("".join(buf))
            buf = []
        else:
            buf.append(ch)
    fields.append("".join(buf))
    return fields


def sanitize_proxy_line(line, masker, hide_ports):
    if PROXY_PASSTHROUGH.match(line) or "=" not in line:
        return line

    name, value = line.split("=", 1)
    fields = split_fields(value)
    proto = fields[0].strip().lower()

    # direct / reject 之类没有服务器地址
    if proto not in ("direct", "reject", "reject-tinygif") and len(fields) >= 3:
        head = fields[1]
        fields[1] = head.replace(head.strip(), masker.mask(head.strip()), 1)
        if hide_ports:
            port = fields[2]
            fields[2] = port.replace(port.strip(), "PORT", 1)

    proto_overrides = CREDENTIAL_BY_PROTO.get(proto, {})
    for i, field in enumerate(fields):
        if "=" not in field:
            continue
        key, val = field.split("=", 1)
        bare = key.strip().lower()
        if bare not in CREDENTIAL_KEYS:
            continue
        placeholder = proto_overrides.get(bare, CREDENTIAL_KEYS[bare])
        fields[i] = field.replace(val.strip(), placeholder, 1) if val.strip() else field

    return name + "=" + ",".join(fields)


def sanitize(lines, hide_ports=False):
    masker = HostMasker()
    section = None
    out = []
    stats = {"proxies": 0, "subscriptions": 0, "mitm": 0, "ssid": 0}

    for raw in lines:
        line = raw.rstrip("\n")
        stripped = line.strip()

        if stripped.startswith("[") and stripped.endswith("]"):
            section = stripped
            out.append(line)
            continue

        if section == "[Proxy]":
            new_line = sanitize_proxy_line(line, masker, hide_ports)
            if new_line != line:
                stats["proxies"] += 1
            out.append(new_line)
            continue

        if "policy-path=" in line or "policy-path =" in line:
            new_line = re.sub(
                r"(policy-path\s*=\s*)\S+", r"\1" + SUBSCRIPTION_PLACEHOLDER, line
            )
            if new_line != line:
                stats["subscriptions"] += 1
            out.append(new_line)
            continue

        if section == "[MITM]" and re.match(r"\s*(ca-passphrase|ca-p12)\s*=", line):
            # 本地 CA 私钥，直接丢弃；Surge 首次开启 MITM 时会自己重新生成
            if not stats["mitm"]:
                out.append("# ca-passphrase / ca-p12 已移除，请在本机 Surge 中重新生成 CA 证书")
            stats["mitm"] += 1
            continue

        if section == "[SSID Setting]" and stripped.startswith("SSID:"):
            new_line = re.sub(r"SSID:[^\s]+", "SSID:YOUR_WIFI_NAME", line)
            if new_line != line:
                stats["ssid"] += 1
            out.append(new_line)
            continue

        out.append(line)

    return out, stats, masker


def main():
    parser = argparse.ArgumentParser(description="脱敏 Surge 配置")
    parser.add_argument("source", help="真实配置文件路径")
    parser.add_argument("-o", "--output", help="输出路径（默认写到标准输出）")
    parser.add_argument(
        "--hide-ports", action="store_true", help="连端口一起隐藏（默认保留）"
    )
    args = parser.parse_args()

    with open(args.source, encoding="utf-8") as fh:
        lines = fh.readlines()

    out, stats, masker = sanitize(lines, hide_ports=args.hide_ports)
    text = BANNER + "\n".join(out) + "\n"

    if args.output:
        with open(args.output, "w", encoding="utf-8") as fh:
            fh.write(text)
    else:
        sys.stdout.write(text)

    sys.stderr.write(
        "已脱敏：节点 %d 条（服务器地址 %d 个）、订阅链接 %d 处、"
        "MITM 私钥 %d 项、Wi-Fi 名称 %d 处\n"
        % (
            stats["proxies"],
            masker.count,
            stats["subscriptions"],
            stats["mitm"],
            stats["ssid"],
        )
    )


if __name__ == "__main__":
    main()
