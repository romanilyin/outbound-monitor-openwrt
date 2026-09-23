#!/usr/bin/env python3
"""Run isolated ucode tests in /tmp; does not install or restart services."""
import argparse
import io
import tarfile
from router import ROOT, connect, run

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--env', required=True)
args = parser.parse_args()
buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode='w:gz') as tar:
    for pattern in ['outbound-monitor/files/**/*', 'luci-app-outbound-monitor/root/**/*.uc', 'tests/*.uc', 'tests/*.sh', 'install.sh', 'scripts/install-local.sh']:
        for path in ROOT.glob(pattern):
            if path.is_file():
                data = path.read_bytes().replace(b'\r\n', b'\n')
                info = tarfile.TarInfo(path.relative_to(ROOT).as_posix())
                info.size = len(data)
                tar.addfile(info, io.BytesIO(data))
with connect(args.env) as client:
    stdin, stdout, stderr = client.exec_command('mkdir -p /tmp/outbound-monitor-check && tar -xzf - -C /tmp/outbound-monitor-check')
    stdin.channel.sendall(buf.getvalue())
    stdin.channel.shutdown_write()
    if stdout.channel.recv_exit_status():
        raise SystemExit(stderr.read().decode())
    raise SystemExit(run(client, 'sh -s', '''set -eu
cd /tmp/outbound-monitor-check
ucode tests/core.uc
ucode tests/update.uc
ucode tests/network.uc
ucode -c -o /tmp/outbound-monitor-check/main.ucb outbound-monitor/files/usr/share/outbound-monitor/main.uc
ucode -c -o /tmp/outbound-monitor-check/rpc.ucb luci-app-outbound-monitor/root/usr/share/rpcd/ucode/outbound-monitor.uc
ucode -c -o /tmp/outbound-monitor-check/update.ucb outbound-monitor/files/usr/share/outbound-monitor/update.uc
sh -n outbound-monitor/files/usr/bin/outbound-monitor
sh -n outbound-monitor/files/etc/init.d/outbound-monitor
sh -n outbound-monitor/files/usr/bin/outbound-monitor-update
sh -n install.sh
sh -n scripts/install-local.sh
echo 'PASS ucode compilation and shell syntax'
sh tests/integration.sh
sh tests/update-integration.sh
sh tests/install-integration.sh
sh tests/connectivity-integration.sh
if [ -f tests/network-integration.sh ]; then sh tests/network-integration.sh; fi
'''))
