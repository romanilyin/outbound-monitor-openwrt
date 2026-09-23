#!/bin/sh
# Mock curl, storage/config paths, process identity and hashed podkop mapping.
# No external probes, real configuration edits or service changes.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SANDBOX=/tmp/outbound-monitor-check/integration
mkdir -p "$SANDBOX/bin"
chmod 700 "$SANDBOX"
cp "$ROOT/outbound-monitor/files/usr/share/outbound-monitor/core.uc" "$SANDBOX/core.uc"
cp "$ROOT/outbound-monitor/files/usr/share/outbound-monitor/network.uc" "$SANDBOX/network.uc"
cp "$ROOT/outbound-monitor/files/usr/share/outbound-monitor/podkop.uc" "$SANDBOX/podkop.uc"
cp "$ROOT/outbound-monitor/files/usr/share/outbound-monitor/runtime.uc" "$SANDBOX/runtime.uc"
sed -e "s|const DIR = .*|const DIR = '$SANDBOX';|" \
    -e "s|config: c.sing_box_config .*|config: '$SANDBOX/config.json'|" \
    -e "s|function generation() {|function generation() { return trim(fs.readfile('$SANDBOX/generation'));|" \
    -e "s|function podkop_targets() {|function podkop_targets() { return {links:json(fs.readfile('$SANDBOX/linkmap.json')), interfaces:json(fs.readfile('$SANDBOX/interfaces.json'))};|" \
    "$ROOT/outbound-monitor/files/usr/share/outbound-monitor/main.uc" > "$SANDBOX/main.uc"
echo test-generation-1 > "$SANDBOX/generation"
echo '{}' > "$SANDBOX/linkmap.json"
echo '{}' > "$SANDBOX/interfaces.json"
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
 */proxies) printf '{"proxies":{"one /é":{},"bad":{},"vpn-1-out":{},"vpn-2-out":{},"main-out":{},"warp-out":{},"direct-out":{}}}\n200' ;;
 */one%20%2F%C3%A9/delay) printf '{"delay":123}\n200' ;;
 */bad/delay) printf '{"message":"failed"}\n503' ;;
 */vpn-1-out/delay)
  if [ "$mode" = linkrace ]; then echo '{}' > "$base/linkmap.json"; fi
  printf '{"delay":123}\n200' ;;
 */vpn-2-out/delay) printf '{"delay":456}\n200' ;;
 */main-out/delay)
  if [ "$mode" = processrace ]; then echo different-server > "$base/generation"; fi
  if [ "$mode" = configrace ]; then sed -i 's/fake-single/fake-replacement/' "$base/config.json"; fi
  printf '{"delay":88}\n200' ;;
 */warp-out/delay) printf '{"delay":99}\n200' ;;
 */direct-out/delay) printf '{"delay":20}\n200' ;;
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

cat > "$SANDBOX/config.json" <<'EOF'
{"experimental":{"clash_api":{"external_controller":"127.0.0.1:9","secret":"fake-secret-never-log"}},"outbounds":[{"tag":"vpn","type":"urltest","outbounds":["vpn-1-out","vpn-2-out"]},{"tag":"vpn-1-out","type":"vless","server":"alpha.example","uuid":"fake-uuid-a"},{"tag":"vpn-2-out","type":"vless","server":"beta.example","uuid":"fake-uuid-b"}]}
EOF
cat > "$SANDBOX/linkmap.json" <<'EOF'
{"vpn-1-out":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","vpn-2-out":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}
EOF
rm -f "$SANDBOX/state.json"
ucode "$SANDBOX/main.uc" collect
ucode "$ROOT/tests/integration.uc" "$SANDBOX/state.json" seed-history
cat > "$SANDBOX/config.json" <<'EOF'
{"experimental":{"clash_api":{"external_controller":"127.0.0.1:9","secret":"fake-secret-never-log"}},"outbounds":[{"tag":"vpn","type":"urltest","outbounds":["vpn-1-out","vpn-2-out"]},{"tag":"vpn-1-out","type":"vless","server":"beta.example","uuid":"fake-uuid-b"},{"tag":"vpn-2-out","type":"vless","server":"alpha.example","uuid":"fake-uuid-a"}]}
EOF
cat > "$SANDBOX/linkmap.json" <<'EOF'
{"vpn-1-out":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","vpn-2-out":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
EOF
ucode "$SANDBOX/main.uc" collect
ucode "$ROOT/tests/integration.uc" "$SANDBOX/state.json" pending-identity
echo test-generation-2 > "$SANDBOX/generation"
ucode "$SANDBOX/main.uc" collect
ucode "$ROOT/tests/integration.uc" "$SANDBOX/state.json" reordered
# UCI can change before podkop writes/applies the JSON: keep old identities unknown.
cat > "$SANDBOX/linkmap.json" <<'EOF'
{"vpn-1-out":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","vpn-2-out":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
EOF
ucode "$SANDBOX/main.uc" collect
ucode "$ROOT/tests/integration.uc" "$SANDBOX/state.json" pending-identity
sed -i 's/fake-uuid-b/fake-uuid-c/' "$SANDBOX/config.json"
echo test-generation-3 > "$SANDBOX/generation"
ucode "$SANDBOX/main.uc" collect
ucode "$ROOT/tests/integration.uc" "$SANDBOX/state.json" replaced
echo linkrace > "$SANDBOX/mode"
ucode "$SANDBOX/main.uc" collect
ucode "$ROOT/tests/integration.uc" "$SANDBOX/state.json" linkrace
ucode "$SANDBOX/main.uc" status 24 > "$SANDBOX/status.json"
if grep -q 'fake-secret\|fake-uuid\|vless://' "$SANDBOX/state.json" "$SANDBOX/status.json" "$SANDBOX/argv.txt"; then
 echo 'FAIL identity credential leakage' >&2; exit 1
fi
echo 'PASS mocked HTTP collection: errors, Unicode, reordering, replacement, pending apply, mid-probe link changes, private credentials'

# A single URL and a VPN interface section need no URLTest wrapper.
cat > "$SANDBOX/config.json" <<'EOF'
{"experimental":{"clash_api":{"external_controller":"127.0.0.1:9"}},"outbounds":[{"tag":"main-out","type":"vless","uuid":"fake-single"},{"tag":"warp-out","type":"direct","bind_interface":"awg0"},{"tag":"wan-out","type":"direct","bind_interface":"wan"},{"tag":"direct-out","type":"direct"}]}
EOF
echo '{"warp-out":"awg0"}' > "$SANDBOX/interfaces.json"
echo '{"main-out":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' > "$SANDBOX/linkmap.json"
echo solo-server > "$SANDBOX/generation"
echo normal > "$SANDBOX/mode"
rm -f "$SANDBOX/state.json"
ucode "$SANDBOX/main.uc" collect
ucode -e '
import {readfile,writefile} from "fs";
let s=json(readfile(ARGV[0]));
if(length(s.keys)!=2 || s.collector_error || length(filter(s.keys,(k)=>k.current==1))!=2) die("FAIL singleton/WARP collection\n");
let warp=filter(s.keys,(k)=>k.tag=="warp-out")[0];
if(warp.interface!="awg0" || warp.samples[0][2]!=99 || s.connectivity.direct_tag!="direct-out") die("FAIL WARP probe or direct control separation\n");
// An older release used a narrower link fingerprint. Upgrade must not require
// restarting sing-box simply because newly supported sections now contribute.
delete s._runtime.discovery_version; s._runtime.link_fingerprint="legacy-fingerprint";
writefile(ARGV[0],sprintf("%J",s));
' "$SANDBOX/state.json"
ucode "$SANDBOX/main.uc" collect
ucode -e 'import {readfile} from "fs"; let s=json(readfile(ARGV[0])); if(s.collector_error || s._runtime.discovery_version!=2 || length(s.keys)!=2) die("FAIL discovery metadata upgrade\n");' "$SANDBOX/state.json"
for mode in processrace configrace; do
 echo "$mode" > "$SANDBOX/mode"
 ucode "$SANDBOX/main.uc" collect
 ucode -e '
 import {readfile} from "fs"; let s=json(readfile(ARGV[0]));
 let expected=ARGV[1]=="processrace" ? "Running sing-box process changed" : "sing-box configuration changed";
 if(index(s.collector_error,expected)!=0 || length(filter(s.keys,(k)=>k.active&&k.current!=-1))) die("FAIL specific race diagnosis\n");
 ' "$SANDBOX/state.json" "$mode"
done
echo 'PASS standalone/WARP collection, direct-control separation, metadata upgrade, precise process/config race diagnosis'
