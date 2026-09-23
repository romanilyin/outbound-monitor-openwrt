#!/usr/bin/env python3
"""Build a tiny, reproducible source-install bundle using only Python stdlib."""
import gzip
import io
import pathlib
import tarfile

root = pathlib.Path(__file__).resolve().parents[1]
dest = root / 'dist'
dest.mkdir(exist_ok=True)
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
    for name in ['install.sh', 'README.md', 'LICENSE']:
        source = root / name
        if source.exists():
            payload = source.read_bytes().replace(b'\r\n', b'\n')
            info = tarfile.TarInfo(name)
            info.size = len(payload)
            info.mode = 0o755 if name.endswith('.sh') else 0o644
            tar.addfile(info, io.BytesIO(payload))
with open(dest / 'outbound-monitor-0.1.0.tar.gz', 'wb') as stream:
    with gzip.GzipFile(fileobj=stream, mode='wb', mtime=0, filename='') as gz:
        gz.write(buffer.getvalue())
print(f'Bundle: {dest / "outbound-monitor-0.1.0.tar.gz"}')
print(f'Compressed: {(dest / "outbound-monitor-0.1.0.tar.gz").stat().st_size} bytes')
