#!/usr/bin/env bash
# Static/functional test harness for snell.sh.
# Sources the script with main() disabled and paths redirected to a sandbox.

set -uo pipefail

SP="$(dirname "$0")"
SANDBOX="$(mktemp -d)"
PASS=0
FAIL=0

t_ok()   { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
t_bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     -> %s\n' "$1" "${2:-}"; }
check()  { if [ "$2" = "$3" ]; then t_ok "$1"; else t_bad "$1" "expected [$3] got [$2]"; fi; }

sed 's/^main "\$@"$/: # disabled/' /home/user/snell/snell.sh > "$SANDBOX/lib.sh"
# shellcheck disable=SC1090
source "$SANDBOX/lib.sh"

# Redirect all state into the sandbox.
VLESS_DIR="$SANDBOX/vless"
VLESS_CONFIG="$VLESS_DIR/config.json"
VLESS_PUBKEY_FILE="$VLESS_DIR/public.key"
VLESS_PARAMS_FILE="$VLESS_DIR/params.conf"
VLESS_CLIENT_FILE="$VLESS_DIR/vless.txt"
VLESS_SERVICE_FILE="$SANDBOX/vless.service"
ANYTLS_DIR="$SANDBOX/anytls"
ANYTLS_JSON="$ANYTLS_DIR/config.json"
ANYTLS_PARAMS_FILE="$ANYTLS_DIR/params.conf"
ANYTLS_CLIENT_FILE="$ANYTLS_DIR/anytls.txt"
ANYTLS_CERT_DIR="$ANYTLS_DIR/certs"
ANYTLS_SELF_CERT="$ANYTLS_CERT_DIR/self-signed.cert.pem"
ANYTLS_SELF_KEY="$ANYTLS_CERT_DIR/self-signed.key.pem"
ANYTLS_SERVICE_FILE="$SANDBOX/anytls.service"
ANYTLS_DOMAIN_FILE="$ANYTLS_DIR/domain"
SNELL_DIR="$SANDBOX/snell"
USERS_DIR="$SNELL_DIR/users"
MAIN_CONF="$USERS_DIR/snell-main.conf"
SNELL_LEGACY_CONF="$SNELL_DIR/snell-server.conf"
SERVICE_FILE="$SANDBOX/snell.service"
mkdir -p "$VLESS_DIR" "$ANYTLS_DIR" "$ANYTLS_CERT_DIR" "$USERS_DIR"

# Network calls are not available in the test environment.
client_endpoint_host() { printf '203.0.113.10'; }

echo "== 1. VLESS Reality config generation =="
UUID="7c1f3f6a-1111-4222-8333-abcdefabcdef"
PRIV="UuMBgl7MXTPx9inmQp2UC7Jcnwc6XYbwDNebonM-FCc"
PUB="bmXOC-F1FxEMF9dyiK2H5_1SUtzH0JuVo51h2wPfgyo"
SID="a1b2c3d4"
write_vless_config 8443 "$UUID" "www.microsoft.com" "$PRIV" "$SID"
vless_save_public_key "$PUB"

if jq -e . "$VLESS_CONFIG" >/dev/null 2>&1; then t_ok "config is valid JSON"; else t_bad "config is valid JSON" "jq rejected it"; fi
check "inbound type"      "$(jq -r '.inbounds[0].type' "$VLESS_CONFIG")" "vless"
check "listen_port is a number" "$(jq -r '.inbounds[0].listen_port|type' "$VLESS_CONFIG")" "number"
check "listen_port value" "$(jq -r '.inbounds[0].listen_port' "$VLESS_CONFIG")" "8443"
check "uuid"              "$(jq -r '.inbounds[0].users[0].uuid' "$VLESS_CONFIG")" "$UUID"
check "flow"              "$(jq -r '.inbounds[0].users[0].flow' "$VLESS_CONFIG")" "xtls-rprx-vision"
check "tls.enabled"       "$(jq -r '.inbounds[0].tls.enabled' "$VLESS_CONFIG")" "true"
check "server_name"       "$(jq -r '.inbounds[0].tls.server_name' "$VLESS_CONFIG")" "www.microsoft.com"
check "reality.enabled"   "$(jq -r '.inbounds[0].tls.reality.enabled' "$VLESS_CONFIG")" "true"
check "handshake.server == server_name" \
      "$(jq -r '.inbounds[0].tls.reality.handshake.server' "$VLESS_CONFIG")" \
      "$(jq -r '.inbounds[0].tls.server_name' "$VLESS_CONFIG")"
check "handshake.server_port" "$(jq -r '.inbounds[0].tls.reality.handshake.server_port' "$VLESS_CONFIG")" "443"
check "private_key"       "$(jq -r '.inbounds[0].tls.reality.private_key' "$VLESS_CONFIG")" "$PRIV"
check "short_id is array" "$(jq -r '.inbounds[0].tls.reality.short_id|type' "$VLESS_CONFIG")" "array"
check "short_id[0]"       "$(jq -r '.inbounds[0].tls.reality.short_id[0]' "$VLESS_CONFIG")" "$SID"
check "public key not in config" "$(jq -r '..|strings' "$VLESS_CONFIG" | grep -c "$PUB")" "0"

echo "== 2. VLESS read-back accessors =="
check "cfg_port"   "$(vless_cfg_port)"   "8443"
check "cfg_uuid"   "$(vless_cfg_uuid)"   "$UUID"
check "cfg_sni"    "$(vless_cfg_sni)"    "www.microsoft.com"
check "cfg_sid"    "$(vless_cfg_sid)"    "$SID"
check "cfg_pubkey" "$(vless_cfg_pubkey)" "$PUB"

echo "== 3. VLESS share link consistency =="
vless_client_export >/dev/null 2>&1
LINK="$(grep '^URL: ' "$VLESS_CLIENT_FILE" | sed 's/^URL: //')"
echo "     link: $LINK"
for pair in "security=reality" "flow=xtls-rprx-vision" "type=tcp" "encryption=none" "fp=chrome" \
            "sni=www.microsoft.com" "pbk=$PUB" "sid=$SID"; do
  if grep -q -- "$pair" <<<"$LINK"; then t_ok "link contains $pair"; else t_bad "link contains $pair" "$LINK"; fi
done
if grep -q "vless://$UUID@203.0.113.10:8443?" <<<"$LINK"; then t_ok "link uuid@host:port"; else t_bad "link uuid@host:port" "$LINK"; fi
if vless_verify_client_match >/dev/null 2>&1; then t_ok "vless_verify_client_match agrees"; else t_bad "vless_verify_client_match agrees" "mismatch reported"; fi

echo "== 4. VLESS legacy params.conf public-key recovery (v1.2.0 upgrade) =="
rm -f "$VLESS_PUBKEY_FILE"
cat > "$VLESS_PARAMS_FILE" <<EOF
PORT=8443
UUID=$UUID
SNI=www.microsoft.com
PRIVATE_KEY=$PRIV
PUBLIC_KEY=$PUB
SHORT_ID=$SID
EOF
check "pubkey recovered from legacy params" "$(vless_cfg_pubkey)" "$PUB"
# Sandbox has no sing-box binary, so the correct post-recovery state is
# binary_missing -- crucially NOT config_broken, which is what an
# unrecovered public key would produce.
check "state after recovery is not config_broken" "$(vless_state)" "binary_missing"

echo "== 5. VLESS state machine =="
rm -rf "$VLESS_DIR"; mkdir -p "$VLESS_DIR"
VLESS_SING_BOX_BIN="$SANDBOX/nonexistent-binary"
check "not_installed"  "$(vless_state)" "not_installed"
write_vless_config 8443 "$UUID" "www.microsoft.com" "$PRIV" "$SID"
vless_save_public_key "$PUB"
check "binary_missing" "$(vless_state)" "binary_missing"
printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/fakebin"; chmod +x "$SANDBOX/fakebin"
VLESS_SING_BOX_BIN="$SANDBOX/fakebin"
check "service_missing" "$(vless_state)" "service_missing"
: > "$VLESS_SERVICE_FILE"
check "ok" "$(vless_state)" "ok"
echo '{"inbounds":[{"type":"vless"}]}' > "$VLESS_CONFIG"
check "config_broken" "$(vless_state)" "config_broken"

echo "== 6. AnyTLS config generation (self-signed) =="
write_vless_config 8443 "$UUID" "www.microsoft.com" "$PRIV" "$SID"  # restore
anytls_write_config 9443 "s3cr3tpass" "$ANYTLS_SELF_CERT" "$ANYTLS_SELF_KEY" "www.bing.com"
if jq -e . "$ANYTLS_JSON" >/dev/null 2>&1; then t_ok "anytls config is valid JSON"; else t_bad "anytls config is valid JSON" "$(cat "$ANYTLS_JSON")"; fi
check "anytls type"        "$(jq -r '.inbounds[0].type' "$ANYTLS_JSON")" "anytls"
check "anytls listen_port" "$(jq -r '.inbounds[0].listen_port' "$ANYTLS_JSON")" "9443"
check "anytls port type"   "$(jq -r '.inbounds[0].listen_port|type' "$ANYTLS_JSON")" "number"
check "anytls password"    "$(jq -r '.inbounds[0].users[0].password' "$ANYTLS_JSON")" "s3cr3tpass"
check "anytls padding_scheme is array" "$(jq -r '.padding_scheme//.inbounds[0].padding_scheme|type' "$ANYTLS_JSON")" "array"
check "anytls tls.enabled" "$(jq -r '.inbounds[0].tls.enabled' "$ANYTLS_JSON")" "true"
check "anytls cert path"   "$(jq -r '.inbounds[0].tls.certificate_path' "$ANYTLS_JSON")" "$ANYTLS_SELF_CERT"
check "anytls key path"    "$(jq -r '.inbounds[0].tls.key_path' "$ANYTLS_JSON")" "$ANYTLS_SELF_KEY"
check "anytls server_name" "$(jq -r '.inbounds[0].tls.server_name' "$ANYTLS_JSON")" "www.bing.com"
check "no reality leak in anytls" "$(grep -c 'reality\|short_id\|private_key' "$ANYTLS_JSON")" "0"

echo "== 6b. AnyTLS config without SNI still valid JSON =="
anytls_write_config 9443 "pw" "/c.pem" "/k.pem" ""
if jq -e . "$ANYTLS_JSON" >/dev/null 2>&1; then t_ok "anytls config valid without server_name"; else t_bad "anytls config valid without server_name" "$(cat "$ANYTLS_JSON")"; fi
check "server_name absent" "$(jq -r '.inbounds[0].tls.server_name // "ABSENT"' "$ANYTLS_JSON")" "ABSENT"

echo "== 7. Self-signed certificate generation and validation =="
anytls_ensure_self_signed_cert true >/dev/null 2>&1
if [ -s "$ANYTLS_SELF_CERT" ] && [ -s "$ANYTLS_SELF_KEY" ]; then t_ok "cert+key files created"; else t_bad "cert+key files created" "missing"; fi
if openssl x509 -in "$ANYTLS_SELF_CERT" -noout >/dev/null 2>&1; then t_ok "cert parses as x509"; else t_bad "cert parses as x509" ""; fi
check "cert CN" "$(openssl x509 -in "$ANYTLS_SELF_CERT" -noout -subject 2>/dev/null | grep -o 'CN *= *[^,]*' | sed 's/CN *= *//')" "www.bing.com"
if anytls_validate_cert_pair "$ANYTLS_SELF_CERT" "$ANYTLS_SELF_KEY" "" >/dev/null 2>&1; then t_ok "validate_cert_pair accepts matched pair"; else t_bad "validate_cert_pair accepts matched pair" ""; fi
# mismatched pair must be rejected
openssl ecparam -genkey -name prime256v1 -out "$SANDBOX/other.key" 2>/dev/null
if anytls_validate_cert_pair "$ANYTLS_SELF_CERT" "$SANDBOX/other.key" "" >/dev/null 2>&1; then t_bad "validate_cert_pair rejects mismatch" "accepted a wrong key"; else t_ok "validate_cert_pair rejects mismatch"; fi
if anytls_validate_cert_pair "$SANDBOX/missing.pem" "$ANYTLS_SELF_KEY" "" >/dev/null 2>&1; then t_bad "validate_cert_pair rejects missing cert" "accepted"; else t_ok "validate_cert_pair rejects missing cert"; fi
: > "$SANDBOX/empty.pem"
if anytls_validate_cert_pair "$SANDBOX/empty.pem" "$ANYTLS_SELF_KEY" "" >/dev/null 2>&1; then t_bad "validate_cert_pair rejects empty cert" "accepted"; else t_ok "validate_cert_pair rejects empty cert"; fi

echo "== 8. AnyTLS client link: self-signed vs acme =="
anytls_write_config 9443 "s3cr3tpass" "$ANYTLS_SELF_CERT" "$ANYTLS_SELF_KEY" "www.bing.com"
anytls_write_params "self" ""
anytls_client_export >/dev/null 2>&1
SLINK="$(grep '^URL: ' "$ANYTLS_CLIENT_FILE" | sed 's/^URL: //')"
echo "     self-signed link: $SLINK"
if grep -q "insecure=1" <<<"$SLINK"; then t_ok "self-signed sets insecure=1"; else t_bad "self-signed sets insecure=1" "$SLINK"; fi
if grep -q "203.0.113.10:9443" <<<"$SLINK"; then t_ok "self-signed uses IP endpoint"; else t_bad "self-signed uses IP endpoint" "$SLINK"; fi
anytls_write_params "acme" "proxy.example.com"
anytls_client_export >/dev/null 2>&1
ALINK="$(grep '^URL: ' "$ANYTLS_CLIENT_FILE" | sed 's/^URL: //')"
echo "     acme link: $ALINK"
if grep -q "insecure=0" <<<"$ALINK"; then t_ok "acme sets insecure=0"; else t_bad "acme sets insecure=0" "$ALINK"; fi
if grep -q "@proxy.example.com:9443" <<<"$ALINK"; then t_ok "acme uses domain endpoint"; else t_bad "acme uses domain endpoint" "$ALINK"; fi
if grep -q "sni=proxy.example.com" <<<"$ALINK"; then t_ok "acme sni is the domain"; else t_bad "acme sni is the domain" "$ALINK"; fi
if anytls_verify_client_match >/dev/null 2>&1; then t_ok "anytls_verify_client_match agrees"; else t_bad "anytls_verify_client_match agrees" ""; fi

echo "== 9. Snell Surge version mapping (installed version drives output) =="
check "v4 server -> version 4"     "$(snell_surge_versions v4)"      "4"
check "v5 server -> versions 4 5"  "$(snell_surge_versions v5)"      "4 5"
check "v6 server -> version 6"     "$(snell_surge_versions v6)"      "6"
check "unknown -> version 4"       "$(snell_surge_versions unknown)" "4"

echo "== 10. Snell config write + read-back =="
SERVICE_USER="root"; SERVICE_GROUP="root"
write_config "$MAIN_CONF" 12345 "MyPreSharedKey==" "1.1.1.1,8.8.8.8"
check "snell_main_port" "$(snell_main_port)" "12345"
check "snell_main_psk"  "$(snell_main_psk)"  "MyPreSharedKey=="
check "snell_main_dns"  "$(snell_main_dns)"  "1.1.1.1,8.8.8.8"
if snell_config_is_valid; then t_ok "config_is_valid accepts good config"; else t_bad "config_is_valid accepts good config" ""; fi
# Regression: base64 PSKs containing '=' must not be truncated.
write_config "$MAIN_CONF" 443 "aGVsbG8gd29ybGQgcGFkZGluZw==" "1.1.1.1"
check "PSK with trailing == survives" "$(snell_main_psk)" "aGVsbG8gd29ybGQgcGFkZGluZw=="
write_config "$MAIN_CONF" 443 "key=with=equals" "1.1.1.1"
check "PSK with embedded = survives" "$(snell_main_psk)" "key=with=equals"
write_config "$MAIN_CONF" 12345 "MyPreSharedKey==" "1.1.1.1,8.8.8.8"
printf '[snell-server]\nlisten = ::0:1\n' > "$MAIN_CONF"
if snell_config_is_valid; then t_bad "config_is_valid rejects psk-less config" "accepted"; else t_ok "config_is_valid rejects psk-less config"; fi

echo "== 11. Snell legacy config migration =="
rm -f "$MAIN_CONF"
printf '[snell-server]\nlisten = ::0:5555\npsk = LegacyKey\nipv6 = true\ndns = 1.1.1.1\n' > "$SNELL_LEGACY_CONF"
migrate_legacy_snell_config >/dev/null 2>&1
if [ -f "$MAIN_CONF" ]; then t_ok "legacy conf migrated to users/"; else t_bad "legacy conf migrated to users/" "missing"; fi
check "migrated port preserved" "$(snell_main_port)" "5555"
check "migrated psk preserved"  "$(snell_main_psk)"  "LegacyKey"
if [ -f "$SNELL_LEGACY_CONF" ]; then t_ok "original legacy file kept"; else t_bad "original legacy file kept" "deleted"; fi

echo "== 12. Snell Surge line uses installed version, not menu choice =="
snell_installed_major() { echo "v5"; }
detect_public_ip() { printf '203.0.113.10'; }
OUT="$(print_one_config "$MAIN_CONF" "test" 2>/dev/null)"
echo "$OUT" | grep '^Snell = ' | sed 's/^/     /'
check "v5 emits two Surge lines" "$(echo "$OUT" | grep -c '^Snell = ')" "2"
if echo "$OUT" | grep -q 'version = 4,'; then t_ok "v5 emits version = 4"; else t_bad "v5 emits version = 4" "$OUT"; fi
if echo "$OUT" | grep -q 'version = 5,'; then t_ok "v5 emits version = 5"; else t_bad "v5 emits version = 5" "$OUT"; fi
if echo "$OUT" | grep -q 'version = 6'; then t_bad "v5 must NOT emit version = 6" "$OUT"; else t_ok "v5 does not emit version = 6"; fi

echo "== 13. Domain validation =="
for d in example.com sub.example.com a-b.example.co.uk proxy.example.com; do
  if is_valid_domain "$d"; then t_ok "accepts $d"; else t_bad "accepts $d" "rejected"; fi
done
for d in "" "notadomain" "1.2.3.4" "-bad.com" "bad-.com" "http://example.com" "exa mple.com" "example..com"; do
  if is_valid_domain "$d"; then t_bad "rejects '$d'" "accepted"; else t_ok "rejects '$d'"; fi
done

echo "== 14. Port validation =="
for p in 1 443 65535; do
  if valid_port "$p"; then t_ok "accepts port $p"; else t_bad "accepts port $p" ""; fi
done
for p in 0 65536 abc "" -1; do
  if valid_port "$p"; then t_bad "rejects port '$p'" "accepted"; else t_ok "rejects port '$p'"; fi
done

echo "== 15. systemd unit sanity =="
write_vless_service "v1.13.18"
for k in "\[Unit\]" "\[Service\]" "\[Install\]" "ExecStart=" "WantedBy=multi-user.target" "Restart=on-failure"; do
  if grep -q "$k" "$VLESS_SERVICE_FILE"; then t_ok "vless unit has $k"; else t_bad "vless unit has $k" ""; fi
done
check "vless unit records version" "$(grep '^X-VLESS-Version=' "$VLESS_SERVICE_FILE" | cut -d= -f2)" "v1.13.18"
check "vless_installed_version reads it back" "$(vless_installed_version)" "v1.13.18"
if grep -q "run -c $VLESS_CONFIG" "$VLESS_SERVICE_FILE"; then t_ok "vless ExecStart points at its config"; else t_bad "vless ExecStart points at its config" "$(grep ExecStart "$VLESS_SERVICE_FILE")"; fi
anytls_write_service "v1.13.18"
if grep -q "run -c $ANYTLS_JSON" "$ANYTLS_SERVICE_FILE"; then t_ok "anytls ExecStart points at its config"; else t_bad "anytls ExecStart points at its config" "$(grep ExecStart "$ANYTLS_SERVICE_FILE")"; fi
check "anytls_installed_version reads back" "$(anytls_installed_version)" "v1.13.18"
SNELL_BIN="/usr/local/bin/snell-server"
write_service
if grep -q "ExecStart=$SNELL_BIN -c $MAIN_CONF" "$SERVICE_FILE"; then t_ok "snell ExecStart binary+config correct"; else t_bad "snell ExecStart binary+config correct" "$(grep ExecStart "$SERVICE_FILE")"; fi
if grep -q "^User=" "$SERVICE_FILE"; then t_ok "snell unit runs as a dedicated user"; else t_bad "snell unit runs as a dedicated user" ""; fi

echo "== 16. Reality/AnyTLS certificate decoupling =="
if grep -n "certbot\|letsencrypt\|acme" "$SANDBOX/lib.sh" | grep -iE "vless|reality" ; then
  t_bad "no ACME references inside the VLESS module" "found above"
else
  t_ok "no ACME references inside the VLESS module"
fi
# Extract only the executable lines of the vless_* functions (comments and
# the unrelated security_note text must not count).
VBLOCK="$(awk '/^vless_[a-z_]*\(\) \{/{f=1} f{print} /^}/{f=0}' "$SANDBOX/lib.sh" | grep -v '^[[:space:]]*#')"
if grep -qiE "certbot|letsencrypt|acme|ANYTLS_" <<<"$VBLOCK"; then
  t_bad "VLESS functions free of certificate logic" "$(grep -inE 'certbot|letsencrypt|acme|ANYTLS_' <<<"$VBLOCK" | head -3)"
else
  t_ok "VLESS functions free of certificate logic"
fi
# And the reverse: AnyTLS functions must not carry Reality logic.
# Drop comments and pure display lines (ok/warn/err/info/echo) so only
# executable logic is inspected.
ABLOCK="$(awk '/^anytls_[a-z_]*\(\) \{/{f=1} f{print} /^}/{f=0}' "$SANDBOX/lib.sh" \
  | grep -v '^[[:space:]]*#' \
  | grep -vE '^[[:space:]]*(ok|warn|err|info|echo)[[:space:]]')"
if grep -qiE "reality|short_id|pbk=|VLESS_" <<<"$ABLOCK"; then
  t_bad "AnyTLS functions free of Reality logic" "$(grep -inE 'reality|short_id|pbk=|VLESS_' <<<"$ABLOCK" | head -3)"
else
  t_ok "AnyTLS functions free of Reality logic"
fi

echo
echo "=================================="
echo " PASS: $PASS   FAIL: $FAIL"
echo "=================================="
rm -rf "$SANDBOX"
[ "$FAIL" -eq 0 ]
