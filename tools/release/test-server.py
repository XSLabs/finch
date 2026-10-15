#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""A web server for tools/release/test-update.sh: serves DIR on the loopback interface with
an ETag and byte ranges (Range: bytes=N-), and cuts off the first whole download of each
.tar.gz halfway. Writes its port to DIR/.port and each request's Range to DIR/.ranges.

  tools/release/test-server.py DIR
"""
import http.server
import os
import sys

ROOT = sys.argv[1]
cut = set()


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        path = os.path.join(ROOT, os.path.basename(self.path))
        if not os.path.isfile(path):
            self.send_error(404)
            return
        data = open(path, 'rb').read()
        rng = self.headers.get('Range')
        with open(os.path.join(ROOT, '.ranges'), 'a') as f:
            f.write(f'{os.path.basename(path)} {rng or "-"}\n')
        start = int(rng.split('=')[1].split('-')[0]) if rng else 0
        self.send_response(206 if start else 200)
        self.send_header('ETag', f'"{len(data)}"')
        self.send_header('Accept-Ranges', 'bytes')
        if start:
            self.send_header('Content-Range', f'bytes {start}-{len(data) - 1}/{len(data)}')
        self.send_header('Content-Length', str(len(data) - start))
        self.end_headers()
        if not start and path.endswith('.tar.gz') and path not in cut:
            cut.add(path)
            self.wfile.write(data[:len(data) // 2])
            self.wfile.flush()
            self.close_connection = True
            return
        self.wfile.write(data[start:])

    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
with open(os.path.join(ROOT, '.port'), 'w') as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
