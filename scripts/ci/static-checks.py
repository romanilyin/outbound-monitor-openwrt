#!/usr/bin/env python3
"""Check release consistency and source syntax without third-party libraries."""
import ast
import json
import pathlib
import re
import subprocess

root = pathlib.Path(__file__).resolve().parents[2]
version = (root / 'VERSION').read_text().strip()
m = re.fullmatch(r'(20\d{2})-([1-9]\d?)-([1-9]\d?)-([1-9]\d*)', version)
assert m and int(m[2]) <= 12 and int(m[3]) <= 31, 'Invalid YYYY-M-D-N release tag'
package_version = '.'.join(m.group(i) for i in (1, 2, 3))
for directory in ('outbound-monitor', 'luci-app-outbound-monitor'):
    text = (root / directory / 'Makefile').read_text()
    assert f'PKG_VERSION:={package_version}\n' in text
    assert f'PKG_RELEASE:={m[4]}\n' in text
for top in ('outbound-monitor', 'luci-app-outbound-monitor', 'scripts', 'tests'):
    for path in (root / top).rglob('*'):
        if not path.is_file():
            continue
        if path.suffix == '.json':
            json.loads(path.read_text())
        elif path.suffix == '.py':
            ast.parse(path.read_text(), filename=str(path))
        elif path.suffix == '.sh' or path.parent.name in ('bin', 'init.d'):
            subprocess.run(['sh', '-n', str(path)], check=True)
subprocess.run(['sh', '-n', str(root / 'install.sh')], check=True)
print('PASS JSON, Python, shell, and release version consistency')
