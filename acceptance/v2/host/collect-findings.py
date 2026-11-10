#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""把某次验收运行的证据汇总成 13 项矩阵 + 计数，供报告引用。
用法: python collect-findings.py <run-id> [--json out.json] [--md out.md]
只读 evidence/，不修改任何证据文件。"""
import json, os, sys, io, hashlib, glob

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))

STATUSES = ['pass','fail-product','fail-fixture','blocked-precondition','blocked-env',
            'evidence-incomplete','manual-pending','not-run']

def read_json(p):
    with io.open(p, encoding='utf-8-sig') as f:
        return json.load(f)

def sha256(p):
    h = hashlib.sha256()
    with open(p,'rb') as f:
        for b in iter(lambda: f.read(1<<20), b''):
            h.update(b)
    return h.hexdigest()

def main():
    if len(sys.argv) < 2:
        print('usage: collect-findings.py <run-id>'); return 2
    run = sys.argv[1]
    out_json = None; out_md = None
    a = sys.argv[2:]
    for i,v in enumerate(a):
        if v == '--json': out_json = a[i+1]
        if v == '--md': out_md = a[i+1]
    ev = os.path.join(ROOT, 'acceptance', 'evidence', run)
    if not os.path.isdir(ev):
        print('没有这个运行目录: ' + ev); return 3

    phases = []
    checks = []
    for ph in sorted(glob.glob(os.path.join(ev, 'phases', '*'))):
        name = os.path.basename(ph)
        pj = os.path.join(ph, 'phase.json')
        info = {'phase': name, 'exit': None, 'counts': {}, 'durationSeconds': None}
        if os.path.exists(pj):
            j = read_json(pj)
            info['exit'] = j.get('exitCode', j.get('guestExitCode'))
            info['counts'] = j.get('counts') or {}
            info['durationSeconds'] = j.get('durationSeconds')
        phases.append(info)
        check_files = glob.glob(os.path.join(ph, 'guest', 'checks', '*.json'))
        check_files += glob.glob(os.path.join(ph, 'checks', '*.json'))
        for cf in sorted(check_files):
            c = read_json(cf)
            c['_phase'] = name
            c['_source'] = 'host' if os.path.dirname(cf) == os.path.join(ph, 'checks') else 'guest'
            # 证据路径映射到本机回收位置
            ev_map = []
            marker = '\\run\\%s\\%s\\' % (run, name)
            for src in (c.get('evidence') or []):
                rel = None
                s = str(src)
                if marker in s:
                    rel = s.split(marker, 1)[1].replace('\\', '/')
                if rel is None:
                    if c['_source'] == 'host':
                        ev_map.append({'local': s, 'exists': os.path.isfile(s), 'external': False})
                        continue
                    # 产品/工作区内的现场文件：只在来宾存在过，回收包里没有副本
                    ev_map.append({'guest': s, 'local': None, 'exists': False, 'external': True,
                                   'note': 'Guest-only reference; not independently verified on host'})
                    continue
                local = os.path.join(ph, 'guest', rel)
                ev_map.append({'guest': s, 'local': local,
                               'exists': os.path.exists(local), 'external': False})
            c['_evidenceLocal'] = ev_map
            checks.append(c)

    # 按 criterion 归组
    by_criterion = {}
    for c in checks:
        crit = c.get('criterion')
        if crit is None:
            crit = 0
        by_criterion.setdefault(int(crit), []).append(c)

    totals = {s: 0 for s in STATUSES}
    for c in checks:
        st = c.get('status') or 'not-run'
        totals[st] = totals.get(st, 0) + 1
    totals['total'] = len(checks)

    crit_rows = []
    for crit in sorted(by_criterion):
        cs = by_criterion[crit]
        cnt = {}
        for c in cs:
            st = c.get('status') or 'not-run'
            cnt[st] = cnt.get(st, 0) + 1
        crit_rows.append({'criterion': crit, 'counts': cnt,
                          'checks': [{'id': c.get('id'), 'status': c.get('status'),
                                      'actual': c.get('actual'), 'detail': c.get('detail'),
                                      'phase': c.get('_phase'),
                                      'evidenceExists': all(e['exists'] for e in c['_evidenceLocal']) if c['_evidenceLocal'] else False}
                                     for c in cs]})

    facts = {
        'runId': run,
        'evidenceDir': ev,
        'phases': phases,
        'totals': totals,
        'criteria': crit_rows,
        'installer': read_json(os.path.join(ROOT,'acceptance','v2','stage','checksums.json')) if os.path.exists(os.path.join(ROOT,'acceptance','v2','stage','checksums.json')) else None,
        'installerNote': 'Current stage only; verify run-specific fingerprint before reusing conclusions',
    }
    txt = json.dumps(facts, ensure_ascii=False, indent=1)
    if out_json:
        with io.open(out_json,'w',encoding='utf-8') as f: f.write(txt)
    else:
        sys.stdout.buffer.write(txt.encode('utf-8', 'replace'))

    if out_md:
        lines = ['# 运行 %s 的 13 项汇总' % run, '',
                 '| 项 | 检查数 | 状态分布 |', '|---|---|---|']
        for r in crit_rows:
            dist = ' '.join('%s=%d' % (k, v) for k, v in sorted(r['counts'].items()))
            lines.append('| %s | %d | %s |' % (r['criterion'] if r['criterion'] else 'c0(夹具/前置)', len(r['checks']), dist))
        lines.append('')
        lines.append('总计: ' + ' '.join('%s=%d' % (k,v) for k,v in sorted(totals.items())))
        with io.open(out_md,'w',encoding='utf-8') as f: f.write('\n'.join(lines) + '\n')
    return 0

if __name__ == '__main__':
    sys.exit(main())
