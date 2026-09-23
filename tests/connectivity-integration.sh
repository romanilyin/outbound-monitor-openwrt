#!/bin/sh
# Real collector with fake API and disabled optional DNS; no external probes.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BOX=/tmp/outbound-monitor-check/connectivity
mkdir -p "$BOX/bin"
chmod 700 "$BOX"
cp "$ROOT/outbound-monitor/files/usr/share/outbound-monitor/core.uc" "$BOX/core.uc"
cp "$ROOT/outbound-monitor/files/usr/share/outbound-monitor/network.uc" "$BOX/network.uc"
cp "$ROOT/outbound-monitor/files/usr/share/outbound-monitor/podkop.uc" "$BOX/podkop.uc"
cp "$ROOT/outbound-monitor/files/usr/share/outbound-monitor/runtime.uc" "$BOX/runtime.uc"
sed -e "s|const DIR = .*|const DIR = '$BOX';|" \
 -e "s|config: c.sing_box_config .*|config: '$BOX/config.json'|" \
 -e "s|dns_check: c.dns_check .*|dns_check: false,|" \
 -e "s|function generation() {|function generation() { return 'mock-process';|" \
 -e "s|function podkop_targets() {|function podkop_targets() { return {links:{},interfaces:{}};|" \
 "$ROOT/outbound-monitor/files/usr/share/outbound-monitor/main.uc" > "$BOX/main.uc"
cat > "$BOX/config.json" <<'EOF'
{"experimental":{"clash_api":{"external_controller":"127.0.0.1:9"}},"outbounds":[{"tag":"group","type":"urltest","outbounds":["one","two"]},{"tag":"one","type":"vless","uuid":"fake-one"},{"tag":"two","type":"vless","uuid":"fake-two"},{"tag":"direct-out","type":"direct"}]}
EOF
cat > "$BOX/bin/curl" <<'EOF'
#!/bin/sh
base=/tmp/outbound-monitor-check/connectivity
mode=$(cat "$base/mode")
for arg do url=$arg; done
case "$url" in
 */proxies) printf '{"proxies":{"one":{},"two":{},"direct-out":{}}}\n200'; exit ;;
 */direct-out/delay)
  case "$mode" in
   outage|mixed) printf '{}\n503' ;;
   unknown) printf '{}\n401' ;;
   *) printf '{"delay":20}\n200' ;;
  esac; exit ;;
 */one/delay)
  if [ "$mode" = mixed ]; then printf '{"delay":100}\n200'; exit; fi ;;
esac
printf '{}\n503'
EOF
chmod 755 "$BOX/bin/curl"
export PATH="$BOX/bin:$PATH"
for mode in outage mixed vpn unknown; do
 rm -f "$BOX/state.json"
 echo "$mode" > "$BOX/mode"
 ucode "$BOX/main.uc" collect
 ucode -e '
 import {readfile} from "fs";
 let s=json(readfile(ARGV[0])), mode=ARGV[1];
 function check(v,m) { if (!v) die("FAIL network integration: " + m + "\n"); }
 let active=filter(s.keys,(k)=>k.active);
 if(mode=="outage") {
  check(length(filter(active,(k)=>k.current==-2))==2,"blue common failure");
  check(length(filter(active,(k)=>k.consecutive_failures!=0))==0,"no key replacement streak");
  check(s.connectivity.common_failure && length(s.network_events)==1,"incident recorded");
  check(s.network_events[0].dns.status=="disabled","optional DNS recorded");
 } else if(mode=="mixed") {
  check(s.connectivity.reason=="mixed" && !s.connectivity.common_failure,"mixed is not ISP blame");
  check(length(filter(active,(k)=>k.current==1))==1,"working VPN remains successful");
  check(length(filter(active,(k)=>k.current==0))==1,"failed VPN remains red");
 } else {
  check(length(filter(active,(k)=>k.current==0))==2,"individual failures stay red");
  check(!length(s.network_events),"no false network incident");
  check(s.connectivity.status==(mode=="vpn"?1:-1),"direct success vs API unknown");
 }
 ' "$BOX/state.json" "$mode"
done
echo 'PASS collector diagnosis: common outage, mixed connectivity, VPN-only failure, unknown controls, optional DNS records'
