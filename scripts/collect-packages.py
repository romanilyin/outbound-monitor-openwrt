#!/usr/bin/env python3
"""Collect stable aliases and GitHub-compatible versioned names from one SDK build."""
import pathlib
import shutil
import sys

source, destination, fmt = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
assert fmt in ('apk', 'ipk')
destination.mkdir(parents=True, exist_ok=True)
for name in ('outbound-monitor', 'luci-app-outbound-monitor', 'luci-i18n-outbound-monitor-ru'):
    matches = [p for p in source.rglob(f'*.{fmt}') if p.name.startswith((name + '-', name + '_'))]
    if len(matches) != 1:
        raise SystemExit(f'Expected one {name}.{fmt}, found {len(matches)}: {matches}')
    path = matches[0]
    # GitHub rewrites '~' in asset names; normalize before creating SHA256SUMS.
    asset_name = path.name.replace('~', '.')
    shutil.copyfile(path, destination / asset_name)
    shutil.copyfile(path, destination / f'{name}.{fmt}')
    print(f'{name}.{fmt}: {path.stat().st_size} bytes ({path.name})')
