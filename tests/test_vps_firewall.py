"""Exercise VPS ingress and forwarding in disposable network namespaces."""

import os
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path


def render(path: Path) -> None:
    from jinja2 import Environment

    root = Path(__file__).parents[1]
    source = root / 'ansible/roles/vps-firewall/templates/vps-firewall.nft.j2'
    path.write_text(Environment().from_string(source.read_text()).render(
        ansible_port=2222, haproxy_http_port=80, haproxy_https_port=443,
        wireguard_port=51820, ansible_default_ipv4={'interface': 'wan-test'},
    ))
    path.with_suffix('.blocklist.nft').write_text(
        (root / 'ansible/roles/vps-blocklist/templates/blocklist.nft.j2').read_text())


def verify(path: Path) -> None:
    assert os.geteuid() == 0, 'Root is required inside a disposable namespace'
    assert Path('/proc/self/ns/net').readlink() != Path('/proc/1/ns/net').readlink(), 'Refusing to modify the host network namespace'
    children = []

    def command(*args: str) -> None:
        subprocess.run(args, check=True, capture_output=True)

    def in_namespace(pid: int, *args: str) -> None:
        command('nsenter', '-t', str(pid), '-n', *args)

    def peer(interface: str, host: str, client: str, ipv6: bool = False) -> int:
        process = subprocess.Popen(['unshare', '--net', sys.executable, '-c', 'import time; time.sleep(180)'])
        children.append(process)
        for _ in range(100):
            if Path(f'/proc/{process.pid}/ns/net').readlink() != Path('/proc/self/ns/net').readlink():
                break
            time.sleep(0.01)
        else:
            raise AssertionError('Peer namespace did not initialize')
        command('ip', 'link', 'add', interface, 'type', 'veth', 'peer', 'name', 'peer')
        command('ip', 'link', 'set', 'peer', 'netns', str(process.pid))
        command('ip', 'address', 'add', host + '/24', 'dev', interface)
        command('ip', 'link', 'set', interface, 'up')
        in_namespace(process.pid, 'ip', 'link', 'set', 'lo', 'up')
        in_namespace(process.pid, 'ip', 'address', 'add', client + '/24', 'dev', 'peer')
        in_namespace(process.pid, 'ip', 'link', 'set', 'peer', 'up')
        if ipv6:
            command('ip', '-6', 'address', 'add', '2001:db8::1/64', 'dev', interface, 'nodad')
            in_namespace(process.pid, 'ip', '-6', 'address', 'add', '2001:db8::2/64', 'dev', 'peer', 'nodad')
        return process.pid

    probe = '''import socket,sys
address,port,kind,source=sys.argv[1:]
s=socket.socket(socket.AF_INET6 if ':' in address else socket.AF_INET,
                socket.SOCK_DGRAM if kind=='udp' else socket.SOCK_STREAM)
s.settimeout(1)
if source:s.bind(('::' if ':' in address else '0.0.0.0',int(source)))
try:
 s.connect((address,int(port)))
 if kind=='udp':s.send(b'probe')
 assert s.recv(16)==b'ok'
except OSError:sys.exit(1)
'''

    def check(pid: int, address: str, port: int, allowed: bool, kind: str = 'tcp', source: str = '') -> None:
        result = subprocess.run(['nsenter', '-t', str(pid), '-n', sys.executable, '-c', probe,
                                 address, str(port), kind, source], check=False, capture_output=True)
        assert (result.returncode == 0) == allowed, (address, port, kind, allowed)

    def listener(family: int, address: str, port: int, kind: int) -> None:
        server = socket.socket(family, kind)
        if family == socket.AF_INET6:
            server.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        server.bind((address, port))
        if kind == socket.SOCK_STREAM:
            server.listen()

        def serve() -> None:
            while True:
                if kind == socket.SOCK_STREAM:
                    connection, _ = server.accept()
                    connection.sendall(b'ok')
                    connection.close()
                else:
                    _, remote = server.recvfrom(16)
                    server.sendto(b'ok', remote)

        threading.Thread(target=serve, daemon=True).start()

    def peer_server(pid: int, port: int) -> None:
        code = '''import socket,sys
s=socket.socket();s.bind(('0.0.0.0',int(sys.argv[1])));s.listen();print('ready',flush=True)
while True:
 c,_=s.accept();c.sendall(b'ok');c.close()
'''
        process = subprocess.Popen(['nsenter', '-t', str(pid), '-n', sys.executable, '-c', code, str(port)], stdout=subprocess.PIPE, text=True)
        children.append(process)
        assert process.stdout.readline().strip() == 'ready'

    try:
        command('ip', 'link', 'set', 'lo', 'up')
        Path('/proc/sys/net/ipv4/ip_forward').write_text('1')
        wan = peer('wan-test', '192.0.2.1', '192.0.2.2', ipv6=True)
        tunnel = peer('wg-test', '198.51.100.1', '198.51.100.2')
        in_namespace(wan, 'ip', 'route', 'add', '198.51.100.0/24', 'via', '192.0.2.1')
        in_namespace(tunnel, 'ip', 'route', 'add', 'default', 'via', '198.51.100.1')
        peer_server(wan, 18080)
        peer_server(tunnel, 9090)
        for family, address in ((socket.AF_INET, '0.0.0.0'), (socket.AF_INET6, '::')):
            for port in (22, 80, 443, 2222, 9999):
                listener(family, address, port, socket.SOCK_STREAM)
            for port in (68, 546, 51820, 9999):
                listener(family, address, port, socket.SOCK_DGRAM)
        fixture = '''add table ip fixture_nat
add chain ip fixture_nat prerouting { type nat hook prerouting priority -100; }
add rule ip fixture_nat prerouting iifname "wan-test" tcp dport 9998 dnat to 198.51.100.2:9090
'''
        subprocess.run(['nft', '-f', '-'], input=fixture, text=True, check=True)
        command('nft', '-f', str(path.with_suffix('.blocklist.nft')))
        check(wan, '192.0.2.1', 9998, True)
        command('nft', '--check', '-f', str(path))
        command('nft', '-f', str(path))
        command('nft', '-f', str(path))
        for address in ('192.0.2.1', '2001:db8::1'):
            for port in (80, 443, 2222):
                check(wan, address, port, True)
            for port in (22, 9999):
                check(wan, address, port, False)
            check(wan, address, 51820, True, 'udp')
            check(wan, address, 9999, False, 'udp')
        check(wan, '192.0.2.1', 68, True, 'udp', '67')
        check(wan, '2001:db8::1', 546, True, 'udp', '547')
        check(wan, '192.0.2.1', 9998, False)
        check(tunnel, '192.0.2.2', 18080, True)
        with socket.create_connection(('127.0.0.1', 9999), timeout=1) as connection:
            assert connection.recv(16) == b'ok'
        subprocess.run(['nft', 'add', 'element', 'inet', 'blocklist', 'banned', '{ 192.0.2.2 timeout 1h }'], check=True)
        command('nft', '-f', str(path.with_suffix('.blocklist.nft')))
        command('nft', '-f', str(path))
        check(wan, '192.0.2.1', 2222, False)
        command('nft', 'list', 'table', 'ip', 'fixture_nat')
        print('PASS: IPv4/IPv6 ingress, custom SSH, DHCP, loopback, tunnel/return forwarding, published-port denial, existing bans/NAT and repeatable loading.')
    finally:
        for child in reversed(children):
            child.terminate()
            child.wait(timeout=5)


if __name__ == '__main__':
    if sys.argv[1] == 'render':
        render(Path(sys.argv[2]))
    else:
        verify(Path(sys.argv[1]))
