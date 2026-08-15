#!/usr/bin/env bash
# Static/functional test harness for the ./snell script.
# shellcheck disable=SC2034  # path vars below are consumed by the sourced script
# Sources the script with main() disabled and paths redirected to a sandbox.

set -uo pipefail

SANDBOX="$(mktemp -d)"
PASS=0
FAIL=0

t_ok()   { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
t_bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     -> %s\n' "$1" "${2:-}"; }
check()  { if [ "$2" = "$3" ]; then t_ok "$1"; else t_bad "$1" "expected [$3] got [$2]"; fi; }

# Resolve the script relative to this test file so the suite is location-independent.
TARGET="$(cd "$(dirname "$0")/.." && pwd)/snell"
[ -f "$TARGET" ] || { echo "Cannot find the snell script at $TARGET"; exit 1; }
sed 's/^main "\$@"$/: # disabled/' "$TARGET" > "$SANDBOX/lib.sh"
# shellcheck disable=SC1090
source "$SANDBOX/lib.sh"
# The script enables errexit; the harness must survive functions that
# deliberately return non-zero, so turn it back off after sourcing.
set +e

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
# v6 is not backward compatible and "reuse" is a v4-era parameter.
V4L="$(snell_surge_lines v4 1.2.3.4 443 PSK)"
V5L="$(snell_surge_lines v5 1.2.3.4 443 PSK)"
V6L="$(snell_surge_lines v6 1.2.3.4 443 PSK)"
check "v4 emits one line"            "$(printf '%s\n' "$V4L" | grep -c '^Snell = ')" "1"
check "v4 uses version = 4"          "$(printf '%s' "$V4L" | grep -c 'version = 4')" "1"
check "v4 keeps reuse"               "$(printf '%s' "$V4L" | grep -c 'reuse = true')" "1"
check "v5 emits two lines"           "$(printf '%s\n' "$V5L" | grep -c '^Snell = ')" "2"
check "v5 primary is version = 5"    "$(printf '%s\n' "$V5L" | head -1 | grep -c 'version = 5')" "1"
check "v5 offers v4 compatibility"   "$(printf '%s\n' "$V5L" | grep -c 'version = 4')" "1"
check "v5 never emits version = 6"   "$(printf '%s' "$V5L" | grep -c 'version = 6')" "0"
check "v5 line has no reuse"         "$(printf '%s\n' "$V5L" | head -1 | grep -c 'reuse')" "0"
check "v6 emits one line"            "$(printf '%s\n' "$V6L" | grep -c '^Snell = ')" "1"
check "v6 uses version = 6"          "$(printf '%s' "$V6L" | grep -c 'version = 6')" "1"
check "v6 drops the v4-era reuse"    "$(printf '%s' "$V6L" | grep -c 'reuse')" "0"
if snell_surge_lines unknown 1.2.3.4 443 PSK >/dev/null 2>&1; then
  t_bad "unknown version emits nothing" "it produced a node anyway"
else t_ok "unknown version emits nothing"; fi

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
check "v5 emits two Surge lines" "$(echo "$OUT" | grep -c 'Snell = snell')" "2"
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
# Inspect executable lines only: the security-notes heredoc is documentation
# and legitimately mentions both Reality and certbot in one sentence.
CODE_ONLY="$(awk '/^security_note\(\) \{/{skip=1} skip && /^}/{skip=0; next} !skip' "$SANDBOX/lib.sh" | grep -v '^[[:space:]]*#')"
if grep -n "certbot\|letsencrypt\|acme" <<<"$CODE_ONLY" | grep -iE "vless|reality" ; then
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

echo "== 17. Interactive choosers must not leak their menu into the return value =="
# Regression: functions whose stdout is captured must print UI to stderr only.
MAIN_CONF="$USERS_DIR/snell-main.conf"
for pair in "1:keep" "2:regenerate" "3:show" "0:cancel" "9:cancel"; do
  IFS=: read -r inp want <<<"$pair"
  got="$(echo "$inp" | snell_existing_config_choice 2>/dev/null)"
  check "chooser input '$inp' returns '$want'" "$got" "$want"
done
# The chooser now probes the target; stub the probe so the suite stays
# hermetic and tests the return value rather than the network.
_real_probe="$(declare -f reality_target_is_suitable)"
reality_target_is_suitable() { return 0; }

got="$(printf '6\nwww.example.com\n' | vless_prompt_sni 2>/dev/null)"
check "custom SNI returns only the hostname" "$got" "www.example.com"
got="$(printf '2\n' | vless_prompt_sni 2>/dev/null)"
SECOND_CANDIDATE="$(printf '%s\n' "$VLESS_SNI_CANDIDATES" | sed -n 2p)"
check "listed SNI returns only the hostname" "$got" "$SECOND_CANDIDATE"

# An unsuitable target must be rejected, not silently accepted.
reality_target_is_suitable() { case "$1" in bad.example.com) return 1 ;; *) return 0 ;; esac; }
got="$(printf '6\nbad.example.com\n6\nwww.example.com\n' | vless_prompt_sni 2>/dev/null)"
check "unsuitable target is rejected and re-prompted" "$got" "www.example.com"
reality_target_is_suitable() { return 0; }

# A polluted SNI would corrupt the Reality config, so assert it stays usable.
SNI_OUT="$(printf '6\nwww.example.com\n' | vless_prompt_sni 2>/dev/null)"
write_vless_config 8443 "$UUID" "$SNI_OUT" "$PRIV" "$SID"
if jq -e . "$VLESS_CONFIG" >/dev/null 2>&1; then t_ok "config built from prompted SNI is valid JSON"; else t_bad "config built from prompted SNI is valid JSON" ""; fi
check "prompted SNI lands intact in config" "$(vless_cfg_sni)" "www.example.com"
eval "$_real_probe"

echo "== 18. Status helpers write diagnostics to stderr, not stdout =="
# info/ok/warn are diagnostics; nothing that returns data may emit them on stdout.
out="$(info "x"; ok "y"; warn "z"; err "w"; true)"
check "info/ok/warn/err produce no stdout" "$out" ""

echo "== 19. port_is_listening must never fail open =="
# Regression: an earlier version returned success when no socket tool was
# installed, making every listener verification meaningless.
python3 -c "
import socket,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(('0.0.0.0',48231)); s.listen(1); time.sleep(8)
" &
PROBE_PID=$!
sleep 1
port_is_listening 48231 1; rc=$?
check "occupied port reports listening" "$rc" "0"
port_is_listening 48232 1; rc=$?
if [ "$rc" = "1" ] || [ "$rc" = "2" ]; then
  t_ok "free port does not report listening (rc=$rc)"
else
  t_bad "free port does not report listening" "rc=$rc (0 would be a false positive)"
fi
# With no socket tool at all, a free port must be "unknown" (2), never "listening" (0).
_real_has_command="$(declare -f has_command)"
has_command() { case "$1" in ss|netstat|lsof) return 1 ;; *) command -v "$1" >/dev/null 2>&1 ;; esac; }
port_is_listening 48231 1; rc=$?
check "probe fallback detects a real listener" "$rc" "0"
port_is_listening 48232 1; rc=$?
check "probe fallback reports unknown, not listening" "$rc" "2"
eval "$_real_has_command"
kill "$PROBE_PID" 2>/dev/null; wait "$PROBE_PID" 2>/dev/null || true

echo "== 20. Reality X25519 public-key derivation =="
# The advertised public key must provably belong to the server's private key;
# a mismatch is what produces "REALITY: processed invalid connection".
openssl genpkey -algorithm X25519 -out "$SANDBOX/kp.pem" 2>/dev/null
KPRIV="$(openssl pkey -in "$SANDBOX/kp.pem" -outform DER 2>/dev/null | tail -c 32 | base64 | tr '+/' '-_' | tr -d '=\n')"
KPUB="$(openssl pkey -in "$SANDBOX/kp.pem" -pubout -outform DER 2>/dev/null | tail -c 32 | base64 | tr '+/' '-_' | tr -d '=\n')"
check "derives the correct public key" "$(vless_derive_reality_public_key "$KPRIV")" "$KPUB"
check "derived key is 43 base64url chars" "${#KPUB}" "43"
if vless_derive_reality_public_key "not-a-real-key" >/dev/null 2>&1; then
  t_bad "rejects a malformed private key" "accepted"
else t_ok "rejects a malformed private key"; fi
if vless_derive_reality_public_key "" >/dev/null 2>&1; then
  t_bad "rejects an empty private key" "accepted"
else t_ok "rejects an empty private key"; fi
# A different key must not derive to the same public key.
openssl genpkey -algorithm X25519 -out "$SANDBOX/kp2.pem" 2>/dev/null
KPRIV2="$(openssl pkey -in "$SANDBOX/kp2.pem" -outform DER 2>/dev/null | tail -c 32 | base64 | tr '+/' '-_' | tr -d '=\n')"
if [ "$(vless_derive_reality_public_key "$KPRIV2")" = "$KPUB" ]; then
  t_bad "distinct keys derive distinct public keys" "collision"
else t_ok "distinct keys derive distinct public keys"; fi
# base64url round-trip
check "b64url round-trip" "$(b64url_decode "$KPUB" | b64url_encode)" "$KPUB"
if b64url_decode >/dev/null 2>&1; then t_bad "b64url_decode rejects no argument" "accepted"; else t_ok "b64url_decode rejects no argument"; fi

echo "== 21. Stale-service detection =="
# A process started before the current config keeps serving the old keys:
# the file validates, clients get values from the file, and the live service
# rejects all of them. That must be detected, not silently ignored.
STALE_CFG="$SANDBOX/stale.json"
STARTED_AT="Sat 2026-08-15 08:03:00 UTC"
systemctl() {
  case "$*" in
    *ExecMainStartTimestamp*) printf '%s\n' "$STARTED_AT" ;;
    *MainPID*) printf '0\n' ;;
  esac
}
service_is_active() { return 0; }

touch -d "2026-08-15 08:02:00 UTC" "$STALE_CFG"
service_config_is_stale u.service "$STALE_CFG"; rc=$?
check "config older than service = current" "$rc" "1"

touch -d "2026-08-15 08:20:00 UTC" "$STALE_CFG"
service_config_is_stale u.service "$STALE_CFG"; rc=$?
check "config newer than service = STALE" "$rc" "0"

touch -d "2026-08-15 08:03:01 UTC" "$STALE_CFG"
service_config_is_stale u.service "$STALE_CFG"; rc=$?
check "write inside restart window = current" "$rc" "1"

service_config_is_stale u.service "$SANDBOX/does-not-exist"; rc=$?
check "missing config = undeterminable" "$rc" "2"

STARTED_AT=""
touch -d "2026-08-15 08:20:00 UTC" "$STALE_CFG"
service_config_is_stale u.service "$STALE_CFG"; rc=$?
check "no timestamp = undeterminable" "$rc" "2"
unset -f systemctl service_is_active

echo "== 22. GitHub release tag parsing =="
# Regression: a greedy sed captured the last quoted string in a single-line
# API response, which is the trailing reactions key "eyes", producing a
# download URL for a release that does not exist.
parse_tag() {
  local body="$1" v=""
  if command -v jq >/dev/null 2>&1; then
    v="$(printf '%s' "$body" | jq -r '.tag_name // empty' 2>/dev/null || true)"
  fi
  if [ -z "$v" ]; then
    v="$(printf '%s' "$body" | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' | head -n1 \
        | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)"/\1/' || true)"
  fi
  [[ "$v" =~ ^v?[0-9]+\.[0-9]+(\.[0-9]+)?([a-zA-Z0-9.-]*)$ ]] || return 1
  printf '%s' "$v"
}
COMPACT='{"tag_name":"v1.13.18","name":"1.13.18","reactions":{"total_count":5,"+1":0,"heart":1,"rocket":0,"eyes":2}}'
check "single-line JSON is parsed, not 'eyes'" "$(parse_tag "$COMPACT")" "v1.13.18"
PRETTY="$(printf '{\n  "tag_name": "v1.13.18",\n  "reactions": { "eyes": 2 }\n}')"
check "pretty-printed JSON is parsed" "$(parse_tag "$PRETTY")" "v1.13.18"
if parse_tag '{"message":"API rate limit exceeded","documentation_url":"https://x"}' >/dev/null 2>&1; then
  t_bad "rate-limit body is rejected" "accepted as a version"
else t_ok "rate-limit body is rejected"; fi
if parse_tag '' >/dev/null 2>&1; then t_bad "empty body is rejected" "accepted"; else t_ok "empty body is rejected"; fi
if parse_tag '{"tag_name":"eyes"}' >/dev/null 2>&1; then
  t_bad "non-version tag is rejected" "accepted"
else t_ok "non-version tag is rejected"; fi

echo "== 23. Version-aware Snell config (verified against real binaries) =="
# Established by running snell-server v4.1.1 / v5.0.1 / v6.0.0rc2:
# v6 rejects a PSK under 12 bytes; v4/v5 do not. ::0: fails to bind on an
# IPv4-only host. v6 uses dns-ip-preference instead of the ipv6 boolean.
SERVICE_USER=root; SERVICE_GROUP=root
for m in v4 v5 v6; do
  write_config "$SANDBOX/$m.conf" 39000 "AnAcceptablePSK123" "1.1.1.1" "$m"
done
check "v6 uses dns-ip-preference"  "$(grep -c '^dns-ip-preference' "$SANDBOX/v6.conf")" "1"
check "v6 drops the ipv6 boolean"  "$(grep -c '^ipv6' "$SANDBOX/v6.conf")" "0"
check "v5 keeps the ipv6 boolean"  "$(grep -c '^ipv6' "$SANDBOX/v5.conf")" "1"
check "v5 has no dns-ip-preference" "$(grep -c '^dns-ip-preference' "$SANDBOX/v5.conf")" "0"
if grep -q '^listen = ::0:' "$SANDBOX/v4.conf" && ! host_supports_ipv6; then
  t_bad "listen matches the host stack" "emitted ::0: on an IPv4-only host"
else t_ok "listen matches the host stack"; fi
# v6 dns-ip-preference must be one of the values the binary accepts.
V6PREF="$(sed -nE 's/^dns-ip-preference = (.*)$/\1/p' "$SANDBOX/v6.conf")"
case "$V6PREF" in
  default|prefer-ipv4|prefer-ipv6|ipv4-only|ipv6-only) t_ok "dns-ip-preference value is valid ($V6PREF)" ;;
  *) t_bad "dns-ip-preference value is valid" "got '$V6PREF'" ;;
esac

echo "== 24. PSK validation matches the binaries =="
for n in 10 11; do
  P="$(printf 'A%.0s' $(seq $n))"
  if snell_validate_psk v6 "$P" >/dev/null 2>&1; then t_bad "v6 rejects a ${n}-byte PSK" "accepted"; else t_ok "v6 rejects a ${n}-byte PSK"; fi
  if snell_validate_psk v5 "$P" >/dev/null 2>&1; then t_ok "v5 accepts a ${n}-byte PSK"; else t_bad "v5 accepts a ${n}-byte PSK" "rejected"; fi
done
P12="$(printf 'A%.0s' $(seq 12))"
if snell_validate_psk v6 "$P12" >/dev/null 2>&1; then t_ok "v6 accepts a 12-byte PSK"; else t_bad "v6 accepts a 12-byte PSK" "rejected"; fi
for bad in "has space" "has,comma" "has=equals"; do
  if snell_validate_psk v6 "${bad}padding123" >/dev/null 2>&1; then
    t_bad "PSK with '$bad' is rejected" "accepted"
  else t_ok "PSK with '$bad' is rejected"; fi
done
check "generated PSK satisfies v6" "$(P="$(random_psk)"; snell_validate_psk v6 "$P" >/dev/null 2>&1 && echo ok)" "ok"

echo "== 25. Single-key edits preserve the rest of the config =="
KC="$SANDBOX/keep.conf"
printf '[snell-server]\nlisten = 0.0.0.0:1111\npsk = Orig123456789\nipv6 = false\ndns = 1.1.1.1\nobfs = http\ntfo = true\negress-interface = eth1\n' > "$KC"
snell_set_config_key "$KC" listen "0.0.0.0:2222"
snell_set_config_key "$KC" psk "New1234567890"
check "listen updated"      "$(sed -nE 's/^listen = (.*)$/\1/p' "$KC")" "0.0.0.0:2222"
check "psk updated"         "$(sed -nE 's/^psk = (.*)$/\1/p' "$KC")" "New1234567890"
check "obfs preserved"      "$(grep -c '^obfs' "$KC")" "1"
check "tfo preserved"       "$(grep -c '^tfo' "$KC")" "1"
check "egress preserved"    "$(grep -c '^egress-interface' "$KC")" "1"
snell_set_config_key "$KC" mode "added"
check "absent key is added"  "$(grep -c '^mode = added' "$KC")" "1"

echo
echo "=================================="
echo " PASS: $PASS   FAIL: $FAIL"
echo "=================================="
rm -rf "$SANDBOX"
[ "$FAIL" -eq 0 ]
