#!/bin/sh
# Isolated fake IPRegion CLI. No DNS requests, router settings or services.
set -eu
umask 077
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d /tmp/outbound-monitor-network-test.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
trap 'exit 1' HUP INT TERM
mkdir -m 700 "$WORK/state"
export NETWORK_TEST_WORK=$WORK
cat > "$WORK/ipregion" <<'EOF'
#!/bin/sh
set -eu
root=$NETWORK_TEST_WORK
printf '%s\n' "$@" > "$root/arguments"
printf '%s' "$IPREGION_RUNTIME_DIR" > "$root/runtime-path"
case "$IPREGION_RUNTIME_DIR" in "$root/state/dns-"*) ;; *) exit 9 ;; esac
out=
while [ "$#" -gt 0 ]; do
 if [ "$1" = --output ]; then out=$2; shift; fi
 shift
done
[ "$out" = "$IPREGION_RUNTIME_DIR/result.json" ] || exit 9
printf '{"running":true}' > "$IPREGION_RUNTIME_DIR/dns-state.json"
case "$(cat "$root/mode")" in
 v2|v2timeout)
  printf '{"version":2,"mode":"dns","probes":[{"id":"test","name":"Test","ip_version":4,"transport":"udp","status":"ok","answers":["private-answer"]},{"id":"test","name":"Test","ip_version":4,"transport":"doh","status":"timeout"}],"summary":{"status":"warning","finding_details":[{"code":"udp_unavailable","name":"private-label"}]},"errors":[]}' > "$out"
  if [ "$(cat "$root/mode")" = v2timeout ]; then exec sleep 5; fi
  exit 1 ;;
 timeout) exec sleep 5 ;;
 malformed) printf 'invalid json' > "$out"; exit 0 ;;
 issues) status=failed; dot=timeout; doh=tls_failed; result=1 ;;
 *) status=ok; dot=ok; doh=ok; result=0 ;;
esac
printf '{"version":1,"mode":"dns","resolvers":[{"id":"test","name":"Test","status":"%s","dot":{"status":"%s","answers":["private-answer"]},"doh":{"status":"%s"}}],"errors":[]}' "$status" "$dot" "$doh" > "$out"
exit "$result"
EOF
chmod 700 "$WORK/ipregion"
printf "const RUNTIME_DIR = getenv('IPREGION_RUNTIME_DIR');\n" > "$WORK/ipregion.uc"
sed -e "s|const IPREGION = .*|const IPREGION = '$WORK/ipregion';|" \
    -e "s|const IPREGION_SCRIPT = .*|const IPREGION_SCRIPT = '$WORK/ipregion.uc';|" \
    -e 's|const DNS_TIMEOUT = .*|const DNS_TIMEOUT = 500;|' \
    "$ROOT/outbound-monitor/files/usr/share/outbound-monitor/network.uc" > "$WORK/network.uc"
cat > "$WORK/test.uc" <<'EOF'
import * as fs from 'fs';
import { dns_check } from './network.uc';
let root = getenv('NETWORK_TEST_WORK');
let count = 0;
function check(ok, message) { if (!ok) die('FAIL DNS integration: ' + message + '\n'); count++; }
function run(mode) {
 fs.writefile(root + '/mode', mode);
 let value = dns_check(true, [0, 0], root + '/state', 123);
 check(length(fs.glob(root + '/state/dns-*')) == 0, 'private runtime cleaned');
 return value;
}
check(dns_check(false, [0,0], root + '/state', 123).status == 'disabled', 'disabled');
check(dns_check(true, [1,0], root + '/state', 123).status == 'not_run', 'healthy controls skip CLI');
check(dns_check(true, [0,-1], root + '/state', 123).status == 'not_run', 'unknown controls skip CLI');
check(fs.stat(root + '/arguments') == null, 'skipped diagnostics never spawn');
let s = run('ok');
check(s.status == 'ok' && s.summary.ok == 1 && s.checked_at == 123 && s.route == 'router', 'successful isolated CLI');
let args = fs.readfile(root + '/arguments');
check(index(args, 'dns\n--no-uci\n--timeout\n2\n--retries\n0\n--output\n') == 0, 'no UCI, small timeout and no retries');
check(index(sprintf('%J', s), 'private-answer') == -1, 'raw answers omitted');
s = run('issues');
check(s.status == 'issues' && s.resolvers[0].dot == 'timeout' && s.summary.failed == 1, 'exit one is valid diagnostic failure');
s = run('v2');
check(s.status == 'issues' && s.resolvers[0].udp == 'ok' && s.resolvers[0].doh == 'timeout' && s.resolvers[0].tcp == 'not_tested' && s.summary.warning == 1, 'v2 CLI probes normalized');
check(index(sprintf('%J',s), 'private-') == -1, 'v2 raw probe and finding details omitted');
s = run('v2timeout');
check(s.status == 'error' && s.error == 'DNS diagnostics exceeded the time limit.', 'partial v2 cannot override deadline failure');
check(run('malformed').status == 'error', 'invalid JSON is an error');
s = run('timeout');
check(s.status == 'error' && s.error == 'DNS diagnostics exceeded the time limit.', 'hard runtime limit');
fs.chmod(root + '/state', 0755);
check(dns_check(true, [0,0], root + '/state', 123).status == 'error', 'unsafe directory refused');
fs.chmod(root + '/state', 0700);
fs.writefile(root + '/ipregion.uc', '// no runtime isolation support');
check(dns_check(true, [0,0], root + '/state', 123).status == 'error', 'unsupported isolation refused');
fs.chmod(root + '/ipregion', 0600);
check(dns_check(true, [0,0], root + '/state', 123).status == 'not_installed', 'missing executable distinguished');
printf('PASS %d isolated DNS integration assertions\n', count);
EOF
ucode "$WORK/test.uc"
