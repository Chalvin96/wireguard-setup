"""Render a disposable ruleset, then test it as root inside `unshare --net`."""

import os
import socket
import subprocess
import sys
import threading
from pathlib import Path


def render(path: Path) -> None:
    from jinja2 import Environment

    source = Path(__file__).parents[1] / 'ansible/roles/app-isolation/templates/app-isolation.nft.j2'
    path.write_text(Environment().from_string(source.read_text()).render(
        app_isolation_user='nobody', app_isolation_bridge='',
        ansible_facts={'getent_passwd': {'nobody': ['x', '65534']}},
        app_isolation_allowed_services=[
            {'address': '10.200.0.1', 'protocol': 'tcp', 'port': 15353},
            {'address': '10.200.0.1', 'protocol': 'udp', 'port': 15353},
        ],
    ))


def test_connections(path: Path) -> None:
    assert os.geteuid() == 0, 'Run only inside a disposable root network namespace'
    assert Path('/proc/self/ns/net').readlink() != Path('/proc/1/ns/net').readlink(), 'Refusing to modify the host network namespace'
    subprocess.run(['ip', 'link', 'set', 'lo', 'up'], check=True)
    for address in ('10.200.0.1', '10.200.0.2', '198.51.100.1'):
        subprocess.run(['ip', 'address', 'add', address + '/32', 'dev', 'lo'], check=True)

    sockets = []
    for family, address in ((socket.AF_INET, '0.0.0.0'), (socket.AF_INET6, '::1')):
        for port in (15353, 18080):
            listener = socket.socket(family)
            listener.bind((address, port))
            listener.listen()
            sockets.append(listener)

            def accept_connections(server: socket.socket) -> None:
                while True:
                    connection, _ = server.accept()
                    connection.close()

            threading.Thread(target=accept_connections, args=(listener,), daemon=True).start()
    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp.bind(('0.0.0.0', 15353))

    def echo_packets() -> None:
        while True:
            data, address = udp.recvfrom(64)
            udp.sendto(data, address)

    threading.Thread(target=echo_packets, daemon=True).start()
    subprocess.run(['nft', '--check', '-f', str(path)], check=True)
    subprocess.run(['nft', '-f', str(path)], check=True)
    subprocess.run(['nft', '-f', str(path)], check=True)
    probe = '''import os,socket,sys
os.setgroups([])
os.setgid(int(sys.argv[1]))
os.setuid(int(sys.argv[1]))
try:
 s=socket.socket(socket.AF_INET6 if ':' in sys.argv[2] else socket.AF_INET,
                 socket.SOCK_DGRAM if sys.argv[4]=='udp' else socket.SOCK_STREAM)
 s.settimeout(1)
 s.connect((sys.argv[2],int(sys.argv[3])))
 if sys.argv[4]=='udp':
  s.send(b'probe')
  assert s.recv(64)==b'probe'
except OSError:
 sys.exit(1)
'''
    cases = [
        (65534, '10.200.0.1', 15353, 'tcp', True),
        (65534, '10.200.0.1', 15353, 'udp', True),
        (65534, '10.200.0.1', 18080, 'tcp', False),
        (65534, '10.200.0.2', 15353, 'tcp', False),
        (65534, '10.200.0.2', 15353, 'udp', False),
        (65534, '127.0.0.1', 18080, 'tcp', False),
        (65534, '::1', 18080, 'tcp', False),
        (65534, '198.51.100.1', 18080, 'tcp', True),
        (0, '10.200.0.2', 18080, 'tcp', True),
    ]
    for uid, address, port, protocol, expected in cases:
        result = subprocess.run([sys.executable, '-c', probe, str(uid), address, str(port), protocol], check=False)
        assert (result.returncode == 0) == expected, (uid, address, port, protocol, expected)
    print('PASS: exact TCP/UDP exceptions, private/loopback/IPv6 denial, public access, unaffected operator, and repeatable loading.')


if __name__ == '__main__':
    if sys.argv[1] == 'render':
        render(Path(sys.argv[2]))
    else:
        test_connections(Path(sys.argv[1]))
