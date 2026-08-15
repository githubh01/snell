# Surge 模版

一份可公开分享的 Surge 配置模版：完整保留了策略组结构、分流规则和 Ruleset，
**所有节点信息（服务器地址、密码/PSK、机场订阅链接、MITM CA 私钥、Wi-Fi 名称）已全部脱敏**。

- 配置文件：[`Surge.conf`](./Surge.conf)
- 脱敏脚本：[`tools/sanitize_surge.py`](./tools/sanitize_surge.py)

## 配置包含什么

| 模块 | 内容 |
| --- | --- |
| `[General]` | DNS、测试 URL、skip-proxy、always-real-ip、UDP 策略等基础参数 |
| `[Proxy]` | 6 个自建/中转节点 + 65 个机场静态节点（均为占位符） |
| `[Proxy Group]` | 中转控制组、默认组、20+ 应用分流组、4 个订阅地区组、23 个机场地区组 |
| `[Rule]` | ChatGPT 语音、实时通信、流媒体、金融、国内直连等完整分流规则 |
| `[Ruleset USBankDomains]` | 4000+ 条美国金融机构域名（内联 Ruleset） |
| `[URL Rewrite]` / `[SSID Setting]` / `[MITM]` | 保留结构，敏感值已清空 |

## 占位符对照表

替换时按下表把占位符换成自己的信息即可，同一个占位符在文件中出现多次代表原本就是同一台服务器。

| 占位符 | 对应节点 |
| --- | --- |
| `server-01.example.com` | `lisa-sg`（Snell v5，经 `Lisa中转` 落地） |
| `server-02.example.com` | `vircs`（Snell v5，经 `Vircs中转` 落地） |
| `server-03.example.com` | `dmit01`（Hysteria2）与 `dmit02`（AnyTLS）共用的主机 |
| `server-04.example.com` | `vircs-anytls`（AnyTLS） |
| `server-05.example.com` | 机场入口 A（香港 / 台湾 / 新加坡 / 澳大利亚 / 印度 / 泰国 / 越南 / 马来西亚 / 南非） |
| `server-06.example.com` | 机场入口 B（日本 / 美国 / 加拿大 / 阿根廷 / 巴西 / 智利 / 韩国） |
| `server-07.example.com` | 机场入口 C（英国 / 德国 / 荷兰 / 意大利 / 西班牙 / 土耳其 / 以色列） |
| `server-08.example.com` | `美国家宽`（Snell v6，经 `dmit02` 中转） |
| `YOUR_SNELL_PSK` / `YOUR_TROJAN_PASSWORD` / `YOUR_HYSTERIA2_PASSWORD` / `YOUR_ANYTLS_PASSWORD` | 各协议的密码 |
| `your-sni-host.example.com` | 机场节点的 SNI |
| `https://your-subscription-host.example.com/subscribe?token=...` | `JP` / `US` / `SG` / `HK` 四个地区组的机场订阅链接（`policy-path`） |
| `YOUR_WIFI_NAME` | `[SSID Setting]` 里需要挂起代理的 Wi-Fi 名称 |

端口保留了原值，仅作结构参考，请按自己的服务端实际端口调整。

## 使用步骤

1. 下载 `Surge.conf`，或在 Surge 里「从 URL 下载配置」填入本仓库的 raw 链接。
2. 按上表把所有 `server-XX.example.com`、`YOUR_*`、`your-*` 占位符替换成自己的信息。
3. 如果不需要机场的 65 个静态节点，删掉 `[Proxy]` 里 `WD-` 开头的行以及 `[Proxy Group]` 里
   `WD（…）` 开头的地区组，并把各策略组成员列表中的 `WD（…）` 一并删除。
4. `[MITM]` 的 CA 已移除，首次开启 MITM 时让 Surge 重新生成证书并在系统里信任。
5. 检查 `[Ponte]` 的 `client-proxy-name`，改成你自己要用的节点名。

> 不要给这份模版加 `#!MANAGED-CONFIG` 自动更新头。模版里全是占位符，
> 一旦自动更新会把你填好的真实配置覆盖回占位符。只有当你托管的是**自己填好的私有配置**时才适合用。

## 自己更新模版

改完真实配置后，重新跑一遍脱敏脚本即可生成新模版：

```bash
python3 tools/sanitize_surge.py 你的真实配置.conf -o Surge.conf
# 想连端口一起隐藏：
python3 tools/sanitize_surge.py 你的真实配置.conf -o Surge.conf --hide-ports
```

脚本会处理：

- `[Proxy]` 中所有节点的服务器地址、`password` / `psk` / `username` / `uuid` / `token` / `sni` 等字段；
- 策略组的 `policy-path` 订阅链接；
- `[MITM]` 的 `ca-passphrase` 与 `ca-p12`；
- `[SSID Setting]` 里的 Wi-Fi 名称。

相同的服务器地址会映射到相同的占位域名，所以脱敏后仍能看出哪些节点原本在同一台机器上。

推送前建议再自查一次：

```bash
grep -nE "psk=|password=|policy-path=|ca-p12" Surge.conf
```

输出应当只剩占位符。
