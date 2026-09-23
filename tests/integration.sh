#!/bin/sh
# Mock only curl and storage/config paths. No external probes, config edits or services.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SANDBOX=/tmp/outbound-monitor-check/integration
mkdir -p "$SANDBOX/bin"
chmod 700 "$SANDBOX"
cp "$ROOT/outbound-monitor/files/usr/share/outbound-monitor/core.uc" "$SANDBOX/core.uc"
sed -e "s|const DIR = .*|const DIR = '$SANDBOX';|" \
    -e "s|config: c.sing_box_config .*|config: '$SANDBOX/config.json'|" \
    "$ROOT/outbound-monitor/files/usr/share/outbound-monitor/main.uc" > "$SANDBOX/main.uc"
cat > "$SANDBOX/config.json" <<'EOF'
{"experimental":{"clash_api":{"external_controller":"127.0.0.1:9","secret":"fake-secret-never-log"}},"outbounds":[{"tag":"group","type":"urltest","outbounds":["one /é","bad"]},{"tag":"one /é","type":"vless","uuid":"fake-uuid-never-log"},{"tag":"bad","type":"vless","uuid":"fake-other"}]}
EOF
cat > "$SANDBOX/bin/curl" <<'EOF'
#!/bin/sh
base=/tmp/outbound-monitor-check/integration
printf '%s\n' "$@" > "$base/argv.txt"
for arg do url=$arg; done
mode=$(cat "$base/mode")
case "$mode" in
 network) exit 7 ;;
 auth) printf '{}\n401'; exit 0 ;;
 malformed) printf 'not-json\n200'; exit 0 ;;
esac
case "$url" in
 */proxies) printf '{"proxies":{"one /é":{},"bad":{}}}\n200' ;;
 */one%20%2F%C3%A9/delay) printf '{"delay":123}\n200' ;;
 */bad/delay) printf '{"message":"failed"}\n503' ;;
 *) printf '{}\n404' ;;
esac
EOF
chmod 755 "$SANDBOX/bin/curl"
export PATH="$SANDBOX/bin:$PATH"
rm -f "$SANDBOX/state.json"
echo normal > "$SANDBOX/mode"
ucode "$SANDBOX/main.uc" collect
ucode "$ROOT/tests/integration.uc" "$SANDBOX/state.json" normal
test ! -e "$SANDBOX/headers"
if grep -q 'fake-secret\|fake-uuid' "$SANDBOX/state.json" "$SANDBOX/argv.txt"; then
 echo 'FAIL secret leakage' >&2; exit 1
fi
for mode in auth malformed network; do
 echo "$mode" > "$SANDBOX/mode"
 ucode "$SANDBOX/main.uc" collect
 ucode "$ROOT/tests/integration.uc" "$SANDBOX/state.json" unknown
done
echo normal > "$SANDBOX/mode"
sed -i 's/fake-uuid-never-log/fake-rotated/' "$SANDBOX/config.json"
ucode "$SANDBOX/main.uc" collect
ucode "$ROOT/tests/integration.uc" "$SANDBOX/state.json" rotation
echo 'PASS mocked HTTP collection: success/failure, Unicode, auth, malformed, network, rotation, private credentials'
