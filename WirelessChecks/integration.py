"""End-to-end HTTP checks against the actual Swift wireless server."""
import concurrent.futures
import http.client
import json
import os
from pathlib import Path
import selectors
import socket
import subprocess
import tempfile
import time
from urllib.parse import quote, urlsplit

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="android-wireless-checks-") as temporary:
    directory = Path(temporary)
    receive = directory / "received"
    source = directory / 'shared 夏.txt'
    payload = os.urandom(2 * 1024 * 1024 + 13)
    source.write_bytes(payload)
    process = subprocess.Popen([str(root / '.build/debug/WirelessChecks'), str(receive), str(source)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        if not selector.select(15):
            raise AssertionError('Server did not start within 15 seconds')
        base = process.stdout.readline().strip()
        assert base.startswith('http://'), base
        address = urlsplit(base)

        def request(method='GET', suffix='', body=None, headers=None, path=None):
            connection = http.client.HTTPConnection(address.hostname, address.port, timeout=10)
            connection.request(method, path or address.path + suffix, body=body, headers=headers or {})
            response = connection.getresponse()
            result = response.status, response.read(), dict(response.getheaders())
            connection.close()
            return result

        code, page, headers = request()
        assert code == 200 and b'Send to Mac' in page and b'XMLHttpRequest' in page, (code, page[:200])
        assert headers['Cache-Control'] == 'no-store'
        assert request(path='/')[0] == 403
        assert request(path='/wrong-token/files')[0] == 403
        assert request(suffix='files', headers={'Origin': 'http://untrusted.example'})[0] == 403
        files = json.loads(request(suffix='files')[1])
        assert len(files) == 1 and files[0]['name'] == source.name
        code, data, headers = request(suffix='download/' + files[0]['id'])
        assert code == 200 and data == payload and 'attachment;' in headers['Content-Disposition']
        assert request(suffix='download/../../etc/passwd')[0] == 404
        code, body, _ = request('POST', 'upload?name=' + quote('夏 phone.bin'), payload)
        assert code == 200, body
        assert (receive / json.loads(body)['saved']).read_bytes() == payload
        assert request('POST', 'upload?name=empty.txt', b'')[0] == 200
        assert (receive / 'empty.txt').read_bytes() == b''
        assert request('POST', 'upload?name=.hidden', b'x')[0] == 400
        assert request('POST', 'upload?name=huge', b'', {'Content-Length': str(21 * 1024**3)})[0] == 400
        code, body, _ = request('POST', 'upload?name=' + quote('../../safe.txt'), b'safe')
        assert code == 200 and (receive / 'safe.txt').read_bytes() == b'safe'
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            results = list(pool.map(lambda _: request('POST', 'upload?name=duplicate.txt', b'duplicate'), range(4)))
        names = [json.loads(body)['saved'] for code, body, _ in results if code == 200]
        assert len(set(names)) == 4
        assert all((receive / name).read_bytes() == b'duplicate' for name in names)

        # Split a header and upload payload across TCP writes, then half-close.
        sock = socket.create_connection((address.hostname, address.port), timeout=10)
        header = f'POST {address.path}upload?name=fragmented.txt HTTP/1.1\r\nHost: localhost\r\nContent-Length: 6\r\n\r\n'.encode()
        sock.sendall(header[:15]); time.sleep(.05); sock.sendall(header[15:] + b'abc'); time.sleep(.05); sock.sendall(b'def')
        sock.shutdown(socket.SHUT_WR)
        response = b''
        while chunk := sock.recv(65536): response += chunk
        sock.close()
        assert response.startswith(b'HTTP/1.1 200'), response
        assert (receive / 'fragmented.txt').read_bytes() == b'abcdef'

        # A dropped upload must not publish or leave partial data.
        sock = socket.create_connection((address.hostname, address.port), timeout=10)
        sock.sendall(f'POST {address.path}upload?name=interrupted.txt HTTP/1.1\r\nHost: localhost\r\nContent-Length: 10000\r\n\r\npartial'.encode())
        sock.close()
        for _ in range(30):
            time.sleep(.05)
            if not list(receive.glob('.incoming-*')): break
        assert not (receive / 'interrupted.txt').exists()
        assert not list(receive.glob('.incoming-*'))

        # Restart must rotate the link and close existing sessions.
        old_path = address.path
        process.stdin.write('restart\n'); process.stdin.flush()
        assert selector.select(15), 'Restart did not complete'
        address = urlsplit(process.stdout.readline().strip())
        assert address.path != old_path
        assert request(path=old_path + 'files')[0] == 403
        assert request(suffix='files')[0] == 200

        # Quit while an upload is active: cleanup must finish before process exit.
        sock = socket.create_connection((address.hostname, address.port), timeout=10)
        sock.sendall(f'POST {address.path}upload?name=quit.txt HTTP/1.1\r\nHost: localhost\r\nContent-Length: 10000\r\n\r\npartial'.encode())
        for _ in range(100):
            if list(receive.glob('.incoming-*')): break
            time.sleep(.02)
        assert list(receive.glob('.incoming-*')), 'Upload did not begin'
        process.stdin.write('quit\n'); process.stdin.flush()
        assert process.wait(timeout=10) == 0
        sock.close()
        assert not list(receive.glob('.incoming-*'))
        assert not (receive / 'quit.txt').exists()
        print('Passed wireless integration checks: authentication, page, file listing, byte-exact download/upload, empty files, limits, traversal, concurrent collisions, fragmented requests, interrupted-upload cleanup, expired links after restart, and cleanup before quit.')
    finally:
        process.terminate()
        try: process.wait(timeout=5)
        except subprocess.TimeoutExpired: process.kill(); process.wait()
