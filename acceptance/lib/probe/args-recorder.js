// 参数接收探针（原生 exe，node）：node 在 Windows 上经 uv_setup_args → CommandLineToArgvW，
// 与 MSVCRT 规则一致，可作为 "native exe 实际收到的 argv" 的基准。
const fs = require('fs');
const out = process.env.MW_PROBE_OUT || require('path').join(require('os').tmpdir(), 'mw-probe-exe.json');
const items = process.argv.slice(2);
fs.writeFileSync(out, JSON.stringify({ kind: 'exe', count: items.length, args: items }, null, 0), 'utf8');
process.exit(0);
