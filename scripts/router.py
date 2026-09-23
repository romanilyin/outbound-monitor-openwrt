#!/usr/bin/env python3
"""Developer SSH helper. Credentials stay in an external .env, never in argv/logs."""
import argparse
import pathlib
import shlex
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / '.tools'))
import paramiko


def connect(env_path):
    values = {}
    for line in pathlib.Path(env_path).read_text(encoding='utf-8-sig').splitlines():
        if '=' in line and not line.lstrip().startswith('#'):
            key, value = line.split('=', 1)
            values[key.strip()] = value.strip().strip('\"\'')
    local = ROOT / '.local'
    local.mkdir(exist_ok=True)
    known = local / 'known_hosts'
    known.touch(exist_ok=True)
    client = paramiko.SSHClient()
    client.load_host_keys(str(known))
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(values['ROUTER_IP'], port=int(values.get('ROUTER_PORT', '22')),
                   username=values.get('ROUTER_USER', 'root'), password=values['ROUTER_PASSWORD'],
                   look_for_keys=False, allow_agent=False, timeout=12)
    return client


def run(client, command, stdin_data=None):
    stdin, stdout, stderr = client.exec_command(command, timeout=180)
    if stdin_data is not None:
        stdin.write(stdin_data)
    stdin.channel.shutdown_write()
    out, err = stdout.read(), stderr.read()
    sys.stdout.buffer.write(out)
    sys.stderr.buffer.write(err)
    return stdout.channel.recv_exit_status()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--env', required=True)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--command')
    group.add_argument('--script', type=pathlib.Path)
    group.add_argument('--put', nargs=2, metavar=('LOCAL', 'REMOTE'))
    args = parser.parse_args()
    with connect(args.env) as client:
        if args.put:
            stdin, stdout, stderr = client.exec_command('cat > ' + shlex.quote(args.put[1]))
            stdin.channel.sendall(pathlib.Path(args.put[0]).read_bytes())
            stdin.channel.shutdown_write()
            code = stdout.channel.recv_exit_status()
            sys.stderr.buffer.write(stderr.read())
            return code
        return run(client, args.command or 'sh -s',
                   args.script.read_text(encoding='utf-8') if args.script else None)


if __name__ == '__main__':
    raise SystemExit(main())
