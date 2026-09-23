#!/usr/bin/env python3
"""Exit 0 only when a YYYY-M-D-N release should become GitHub latest."""
import re
import sys

def version(value):
    if not re.fullmatch(r'20\d{2}-[1-9]\d?-[1-9]\d?-[1-9]\d*', value):
        return None
    return tuple(map(int, value.split('-')))

candidate, previous = version(sys.argv[1]), version(sys.argv[2])
raise SystemExit(0 if candidate and (previous is None or candidate > previous) else 1)
