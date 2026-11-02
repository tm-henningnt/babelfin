"""Bounded local WebSocket peers; credentials are synthetic and never recorded."""
import base64
import hashlib
import http.server
import socketserver
import struct
import subprocess
import sys
import threading

class Peer(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *_):
        pass
    def do_GET(self):
        if self.path == '/target':
            self.server.target_hits += 1
        if self.path.startswith('/redirect'):
            target = self.server.server_address[1] if self.path == '/redirect-same' else self.server.other_port
            self.send_response(302)
            self.send_header('Location', f'http://127.0.0.1:{target}/target')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        credential = self.headers.get('Authorization') or self.headers.get('xi-api-key')
        if credential not in ('Bearer synthetic-fixture', 'synthetic-fixture'):
            self.send_response(403)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        key = self.headers.get('Sec-WebSocket-Key', '')
        accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
        self.send_response(101)
        self.send_header('Upgrade', 'websocket')
        self.send_header('Connection', 'Upgrade')
        self.send_header('Sec-WebSocket-Accept', accept)
        self.end_headers()
        self.close_connection = True
        self.connection.settimeout(4)
        try:
            first, second = self.rfile.read(2)
            size = second & 127
            if size == 126: size = struct.unpack('!H', self.rfile.read(2))[0]
            if size == 127: size = struct.unpack('!Q', self.rfile.read(8))[0]
            mask = self.rfile.read(4) if second & 128 else b''
            payload = self.rfile.read(size)
            if mask: payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
            if self.path.startswith('/oversize-'): payload = b'x' * int(self.path.rsplit('-', 1)[1])
            header = bytes([0x81, len(payload)]) if len(payload) < 126 else bytes([0x81, 127]) + struct.pack('!Q', len(payload))
            self.wfile.write(header + payload)
            self.wfile.flush()
        except (OSError, ValueError):
            pass

class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    target_hits = 0

servers = [Server(('127.0.0.1', 0), Peer) for _ in range(2)]
for i, server in enumerate(servers):
    server.other_port = servers[1-i].server_address[1]
    threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    for provider, limit in [('openai',800000),('eleven',65536)]:
        for path, expected in [('/echo','echo'),(f'/oversize-{limit}','large'),('/redirect-same','refuse'),('/redirect-cross','refuse'),(f'/oversize-{limit+1}','refuse')]:
            before = sum(s.target_hits for s in servers)
            subprocess.run([sys.argv[1],provider,f'ws://127.0.0.1:{servers[0].server_address[1]}{path}',expected],check=True,timeout=6)
            assert sum(s.target_hits for s in servers) == before, 'redirect target was contacted'
            print('PASS:',provider,path,flush=True)
finally:
    for server in servers: server.shutdown(); server.server_close()
