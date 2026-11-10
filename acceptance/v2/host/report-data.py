#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""收集报告需要的指纹与统计，输出 JSON（供 report-next-v3.1.0.md 引用）。"""
import hashlib
import json
import os
import subprocess
import sys
import datetime
import base64

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', '..'))
REPO = ROOT


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def fileinfo(rel):
    p = os.path.join(REPO, rel)
    if not os.path.exists(p):
        return {'path': rel, 'exists': False}
    return {'path': rel, 'exists': True, 'bytes': os.path.getsize(p), 'sha256': sha256(p)}


def run(cmd):
    try:
        out = subprocess.run(cmd, cwd=REPO, capture_output=True, shell=True)
        return out.stdout.decode('utf-8', 'replace').strip()
    except Exception as e:  # noqa
        return 'ERR: %s' % e


def git_state():
    head = run('git rev-parse HEAD')
    branch = run('git rev-parse --abbrev-ref HEAD')
    status = run('git status --porcelain')
    changed = [l for l in status.splitlines() if l.strip()]
    return {'head': head, 'branch': branch, 'dirtyCount': len(changed)}


def sig_status(path):
    # Pass a real argv vector; nested shell quoting used to silently lose status.
    quoted = path.replace("'", "''")
    code = ("$ErrorActionPreference='Stop'; $p='" + quoted + "'; $s=Get-AuthenticodeSignature -LiteralPath $p; "
            "$v=(Get-Item -LiteralPath $p).VersionInfo; "
            "[ordered]@{status=[string]$s.Status; signer=$s.SignerCertificate.Subject; "
            "fileVersion=$v.FileVersion; productVersion=$v.ProductVersion} | ConvertTo-Json -Compress")
    encoded = base64.b64encode(code.encode('utf-16-le')).decode('ascii')
    psenv = os.environ.copy()
    # Python does not perform pwsh's PSModulePath normalization when spawning 5.1.
    psenv['PSModulePath'] = os.path.join(os.environ['SystemRoot'], 'System32',
                                       'WindowsPowerShell', 'v1.0', 'Modules')
    result = subprocess.run(['powershell', '-NoProfile', '-EncodedCommand', encoded],
                            cwd=REPO, env=psenv, capture_output=True, encoding='utf-8', errors='replace')
    if result.returncode:
        return {'error': result.stderr.strip(), 'exitCode': result.returncode}
    try:
        return json.loads(result.stdout.lstrip('\ufeff'))
    except ValueError:
        return {'error': 'Invalid signature JSON', 'stdout': result.stdout}


def collect_run(runid):
    base = os.path.join(REPO, 'acceptance', 'evidence', runid)
    out = {'runId': runid, 'dir': base, 'phases': [], 'totals': {}}
    pdir = os.path.join(base, 'phases')
    if os.path.isdir(pdir):
        for ph in sorted(os.listdir(pdir)):
            pj = os.path.join(pdir, ph, 'phase.json')
            if not os.path.exists(pj):
                continue
            with open(pj, encoding='utf-8-sig') as f:
                d = json.load(f)
            out['phases'].append({
                'phase': ph,
                'exit': d.get('exitCode', d.get('guestExitCode')),
                'guestStarted': d.get('guestStarted'),
                'counts': d.get('counts') or {},
                'durationSeconds': d.get('durationSeconds'),
            })
    for p in out['phases']:
        for k, v in (p['counts'] or {}).items():
            out['totals'][k] = out['totals'].get(k, 0) + (v or 0)
    return out


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument('--run', action='append', default=[])
    ap.add_argument('--out', default='acceptance/evidence/report-data.json')
    args = ap.parse_args()

    dist = os.path.join(REPO, 'dist', 'MinglingWorkbench-3.1.0-setup.exe')
    data = {
        'generatedAt': datetime.datetime.now().astimezone().isoformat(),
        'git': git_state(),
        'installer': {
            'file': os.path.relpath(dist, REPO),
            'bytes': os.path.getsize(dist) if os.path.exists(dist) else None,
            'sha256': sha256(dist) if os.path.exists(dist) else None,
            'signature': sig_status(dist) if os.path.exists(dist) else None,
        },
        'scripts': [fileinfo(p) for p in [
            'tools/bootstrap.ps1',
            'tools/components.json',
            'tools/finish-update.ps1',
            'tools/backup-install.ps1',
            'installer/mingling.iss',
            'skill/mingling-install/scripts/bootstrap.ps1',
            'skill/mingling-install/scripts/resolve-program-root.ps1',
            'skill/mingling-install/scripts/deploy-singing.ps1',
            'tools/setup-singing.ps1',
            'acceptance/v2/stage/checksums.json',
        ] + sorted(os.path.relpath(os.path.join(base, n), REPO)
                   for folder in ['acceptance/lib', 'acceptance/v2', 'acceptance/tests', 'acceptance/tools']
                   for base, dirs, files in os.walk(os.path.join(REPO, folder))
                   if 'stage' not in os.path.relpath(base, REPO).split(os.sep)
                   for n in files if n.endswith(('.ps1', '.py')))],
        'stage': [],
        'runs': [collect_run(r) for r in args.run],
    }
    stage = os.path.join(REPO, 'acceptance', 'v2', 'stage')
    if os.path.isdir(stage):
        for n in sorted(os.listdir(stage)):
            p = os.path.join(stage, n)
            if os.path.isfile(p) and n.lower().endswith(('.exe', '.json', '.txt')):
                data['stage'].append({'name': n, 'bytes': os.path.getsize(p), 'sha256': sha256(p)})

    outp = os.path.join(REPO, args.out)
    os.makedirs(os.path.dirname(outp), exist_ok=True)
    with open(outp, 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    sys.stdout.buffer.write((json.dumps(data, ensure_ascii=False, indent=2) + '\n').encode('utf-8', 'replace'))


if __name__ == '__main__':
    main()
