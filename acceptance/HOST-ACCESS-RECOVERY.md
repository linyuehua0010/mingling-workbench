# 验收宿主通道恢复（2026-11-10）

## 已确认的边界

当前会话是 workspace-write、网络受限的执行环境。LOCALAPPDATA 指向
`AppData\Local\Packages\sandbox.<id>\AC`；只读访问 Windows 服务管理器也被拒绝。
独立于产品和证据服务的本地 TCP 监听/连接检测失败；不带任何凭据的 `vmrun -T ws list`
返回 -1 / unable to start。因此当前会话不足以执行 VMware 验收。
这不证明 VMware 安装损坏或测试 VM 已关闭；恢复会话权限后仍须重新检测。

证据：
- `evidence/resume-20261110-085423-1c5e-host/host-access.json`
- 同目录 `commands.jsonl`、原始 stdout/stderr 与 manifest.json / manifest.json.sha256。
- `evidence/resume-20261110-085423-1c5e/resume-summary.json`

## 恢复方法

由用户在聊天输入框下的权限菜单选择允许 VMware 宿主访问及本地网络的权限配置。
若现有配置无法细分这些能力，可由用户决定是否为本次专用 VM 验收选择 Full access。
Full access 扩大当前聊天的文件和网络访问；这是应用的执行权限设置，不是 Windows
“以管理员身份运行”。受组织管理限制时，应由管理员提供允许该测试的执行环境。
代理不在脚本里修改全局配置、防火墙、系统 ACL 或沙箱。

审批策略与沙箱访问权限是两个独立设置。关闭审批提示不会自动打开网络或宿主服务访问。
官方依据：
- https://learn.chatgpt.com/docs/sandboxing?surface=app
- https://learn.chatgpt.com/docs/windows/windows-sandbox

权限更新后的第一条命令：

```powershell
cd F:\dsh工作区\MinglingWorkbench
powershell -NoProfile -ExecutionPolicy Bypass -File acceptance\v2\Resume-Acceptance.ps1 -CheckOnly
```

必须看到 `loopback=True`、`vmrunExit=0`、`targetVmListed=True` 后再续跑。
如果 vmrun 成功但指定 VM 未列出，由用户在 VMware 中确认该专用 VM 已运行；本检测不启动
或回滚 VM。如果仍为权限拒绝，需要重新检查当前聊天实际生效的权限配置。
本检测不验证来宾身份、VMware Tools 或 NAT 停止权限；后续原有夹具仍负责这些前置条件。

## 一条命令续跑

在用户明确选择的、具备相应访问能力的宿主会话中执行：

```powershell
cd F:\dsh工作区\MinglingWorkbench
powershell -NoProfile -ExecutionPolicy Bypass -File acceptance\v2\Resume-Acceptance.ps1
```

该入口先检测宿主，再补 SnowLuma 缓存，调用已有 full → recovery → upgrade → final → netcut。
阶段使用独立的新 run-id，保存顶层调用日志与退出码；现有 Run-All 负责阶段回收。
最后调用 collect-findings.py 和 report-data.py，生成批次 summary 与证据清单。
长任务查看各阶段原有 progress.json 与 host/run.log。
`acceptanceComplete` 始终为 false，直到人工/代理审查每项断言及外部依赖并正式出报告。
退出 0 或宿主门禁通过都不是端到端验收通过。

若用户保持当前受限聊天权限，也可以在自己授权的本机 PowerShell 中执行上面的入口，
代理随后读取工作区内的新增证据；代理不会通过其他工具代替用户跨越当前执行权限。

本轮验证仅覆盖：两个新脚本的 PS 5.1 Parser/BOM，以及真实的宿主阻塞分支。
正常通道和完整续跑分支尚未验证。历史报告、旧证据、产品版本与安装包未修改。
