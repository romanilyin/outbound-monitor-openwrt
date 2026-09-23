#!/usr/bin/env python3
"""Build a tiny, reproducible source-install bundle using only Python stdlib."""
import gzip
import io
import pathlib
import tarfile
import re

root = pathlib.Path(__file__).resolve().parents[1]
dest = root / 'dist'
dest.mkdir(exist_ok=True)
version = (root / 'VERSION').read_text().strip()
assert re.fullmatch(r'20\d{2}-[1-9]\d?-[1-9]\d?-[1-9]\d*', version)
archive = dest / f'outbound-monitor-{version}.tar.gz'
buffer = io.BytesIO()
with tarfile.open(fileobj=buffer, mode='w', format=tarfile.USTAR_FORMAT) as tar:
    for tree, prefix in [('outbound-monitor/files', ''), ('luci-app-outbound-monitor/root', ''),
                         ('luci-app-outbound-monitor/htdocs', 'www/')]:
        for source in sorted((root / tree).rglob('*')):
            if not source.is_file():
                continue
            target = prefix + source.relative_to(root / tree).as_posix()
            name = 'files/' + target
            payload = source.read_bytes().replace(b'\r\n', b'\n')
            info = tarfile.TarInfo(name)
            info.size = len(payload)
            info.mode = 0o755 if target.startswith(('usr/bin/', 'etc/init.d/')) else 0o644
            if target == 'etc/config/outbound-monitor':
                info.mode = 0o600
            tar.addfile(info, io.BytesIO(payload))
    for source_name, name in [('scripts/install-local.sh', 'install.sh'), ('README.md','README.md'), ('LICENSE','LICENSE'),
                              ('VERSION','files/usr/share/outbound-monitor/version'), ('install.sh','files/usr/share/outbound-monitor/install.sh')]:
        source = root / source_name
        if source.exists():
            payload = source.read_bytes().replace(b'\r\n', b'\n')
            info = tarfile.TarInfo(name)
            info.size = len(payload)
            info.mode = 0o755 if name.endswith('.sh') else 0o644
            tar.addfile(info, io.BytesIO(payload))
with open(archive, 'wb') as stream:
    with gzip.GzipFile(fileobj=stream, mode='wb', mtime=0, filename='') as gz:
        gz.write(buffer.getvalue())
print(f'Bundle: {archive}')
print(f'Compressed: {archive.stat().st_size} bytes')
