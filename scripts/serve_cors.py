#!/usr/bin/env python3
"""Serve a directory on 127.0.0.1 with Access-Control-Allow-Origin: *, the
header GitHub Pages sends (docs/SITE-PAGES.md), so the /get/ button's
Apple2TS fetch of the disk image behaves here as it will from Pages.
Usage: serve_cors.py DIR PORT.  Stdlib only."""
import functools
import http.server
import os
import re
import shutil
import sys


class Handler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, HEAD, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Range')
        self.send_header('Access-Control-Expose-Headers',
                         'Content-Range, Accept-Ranges, Content-Length')
        self.send_header('Accept-Ranges', 'bytes')
        self.send_header('Cache-Control', 'no-store')
        super().end_headers()

    def _range(self):
        """(path, size, start, end) when the request is a single
        satisfiable byte range of a regular file; 'bad' for an
        unsatisfiable one (416 is sent); None to serve normally."""
        spec = self.headers.get('Range')
        path = self.translate_path(self.path)
        if not spec or not os.path.isfile(path):
            return None
        m = re.fullmatch(r'bytes=(\d*)-(\d*)', spec.strip())
        if not m or (not m.group(1) and not m.group(2)):
            return None
        size = os.path.getsize(path)
        if m.group(1):
            start = int(m.group(1))
            if m.group(2) and int(m.group(2)) < start:
                return None                # malformed: ignored (RFC 9110)
            end = min(int(m.group(2)), size - 1) if m.group(2) else size - 1
        else:                                  # bytes=-N: the last N
            n = int(m.group(2))
            start, end = max(0, size - n), size - 1
        if start >= size or start > end:
            self.send_response(416)
            self.send_header('Content-Range', 'bytes */%d' % size)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return 'bad'
        return path, size, start, end

    def _serve(self, body):
        r = self._range()
        if r == 'bad':
            return
        if r is None:
            f = self.send_head()
            if f:
                try:
                    if body:
                        shutil.copyfileobj(f, self.wfile)
                finally:
                    f.close()
            return
        path, size, start, end = r
        self.send_response(206)
        self.send_header('Content-Type', self.guess_type(path))
        self.send_header('Content-Range', 'bytes %d-%d/%d' % (start, end, size))
        self.send_header('Content-Length', str(end - start + 1))
        self.end_headers()
        if body:
            with open(path, 'rb') as f:
                f.seek(start)
                left = end - start + 1
                while left > 0:
                    chunk = f.read(min(65536, left))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    left -= len(chunk)

    def do_GET(self):
        self._serve(True)

    def do_HEAD(self):
        self._serve(False)

    def handle(self):
        # an aborted range request (a player seeking) is not an error
        try:
            super().handle()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def finish(self):
        try:
            super().finish()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_OPTIONS(self):
        self.send_response(204)
        self.end_headers()


def main():
    d, port = sys.argv[1], int(sys.argv[2])
    h = functools.partial(Handler, directory=d)
    srv = http.server.ThreadingHTTPServer(('127.0.0.1', port), h)
    print('serving %s on http://127.0.0.1:%d/ with CORS (^C stops)' % (d, port),
          flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == '__main__':
    main()
