#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""并行分段下载（用于在网络限速时预热安装器缓存），下载后校验大小与 SHA256。

用法：python prefetch.py <url> <out> <sha256> <size> [线程数]
镜像前缀可用环境变量 MW_MIRROR 指定（例如 https://edgeone.gh-proxy.com/）。
"""
import hashlib
import os
import sys
import threading
import time
import urllib.request

CHUNK = 1 << 20


def head_size(url):
    req = urllib.request.Request(url, method='HEAD')
    with urllib.request.urlopen(req, timeout=30) as r:
        return int(r.headers.get('Content-Length') or 0), r.headers.get('Accept-Ranges')


def worker(url, out, start, end, idx, prog):
    h = hashlib.sha256() if False else None  # 分片哈希无用，仅为占位
    part = out + '.part%d' % idx
    got = 0
    for attempt in range(3):
        pos = start + got
        if pos > end:
            break
        req = urllib.request.Request(url, headers={'Range': 'bytes=%d-%d' % (pos, end)})
        try:
            with urllib.request.urlopen(req, timeout=60) as r, open(part, 'ab') as f:
                while True:
                    b = r.read(CHUNK)
                    if not b:
                        break
                    f.write(b)
                    got += len(b)
                    prog[idx] = got
        except Exception as e:  # noqa
            sys.stderr.write('range %d attempt %d: %s\n' % (idx, attempt, e))
            time.sleep(2)
    if got < (end - start + 1):
        raise SystemExit('range %d incomplete: %d/%d' % (idx, got, end - start + 1))


def main():
    url, out, sha, size = sys.argv[1], sys.argv[2], sys.argv[3].lower(), int(sys.argv[4])
    n = int(sys.argv[5]) if len(sys.argv) > 5 else 8
    mirror = os.environ.get('MW_MIRROR') or ''
    if mirror and 'github.com' in url:
        url = mirror + url
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    for i in range(n):
        p = out + '.part%d' % i
        if os.path.exists(p):
            os.remove(p)
    step = size // n
    ranges = []
    for i in range(n):
        s = i * step
        e = (size - 1) if i == n - 1 else (s + step - 1)
        ranges.append((s, e, i))
    prog = {i: 0 for i in range(n)}
    ths = [threading.Thread(target=worker, args=(url, out, s, e, i, prog), daemon=True) for s, e, i in ranges]
    t0 = time.time()
    for t in ths:
        t.start()
    while any(t.is_alive() for t in ths):
        time.sleep(5)
        done = sum(prog.values())
        el = max(time.time() - t0, 1)
        sys.stderr.write('  %.1f/%d MB  %.2f MB/s\n' % (done / 1048576.0, size // 1048576, done / el / 1048576.0))
    for t in ths:
        t.join()

    # 合并
    with open(out, 'wb') as f:
        for i in range(n):
            with open(out + '.part%d' % i, 'rb') as p:
                while True:
                    b = p.read(CHUNK)
                    if not b:
                        break
                    f.write(b)
            os.remove(out + '.part%d' % i)
    got_bytes = os.path.getsize(out)
    h = hashlib.sha256()
    with open(out, 'rb') as f:
        for b in iter(lambda: f.read(CHUNK), b''):
            h.update(b)
    ok = (got_bytes == size and h.hexdigest().lower() == sha)
    print('bytes=%d expect=%d sha=%s expect=%s ok=%s elapsed=%.0fs' % (got_bytes, size, h.hexdigest(), sha, ok, time.time() - t0))
    if not ok:
        raise SystemExit(2)


if __name__ == '__main__':
    main()
