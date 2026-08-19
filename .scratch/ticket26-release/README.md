# Ticket 26 Windows 无 Node 候选验收

本目录保存 Ticket 26 的可复现验收脚本与脱敏结果。脚本使用隔离的数据、运行时、安装和快捷方式目录，不读写真实用户数据；真实 Provider Key 只从 `Qiyu_API_KEY` 读取并写入隔离的 Windows Credential Manager scope，不进入报告。

运行前先生成候选包：

```powershell
& .\scripts\build-windows-bundle.ps1
$env:Qiyu_API_KEY = '<仅当前进程使用的真实 Key>'
& .\.scratch\ticket26-release\run-release-acceptance.ps1
```

脚本会在只含 Windows 系统目录的 `PATH` 中完成安装、首次启动、Provider 配置、离线聊天、真实 Provider 聊天、晚安触发的 Dream 七天时间模拟、强制退出重启、备份恢复和两种卸载。临时运行产物位于忽略的 `work/`，提交的 `acceptance-results.json` 只含布尔值、状态码、计数和环境限制。

当前机器不能诚实覆盖独立干净 VM 与整机重启，这两项会在结果里明确记为未执行；进程强退后的重启恢复由脚本实测。

2026-08-20 实测结果为 `passed_with_environment_limits`：隔离 PATH 中四种开发工具均不可见；离线回复来自本地引擎，真实 Provider 回复来自 LLM，Dream 在八天间隔与晚安触发后采用成功；强退后恢复 6 个 turns，备份预览与导入各恢复 4 个文件；保留数据与永久删除两种卸载均通过。机器、用户名、路径和任何凭据值均未写入提交结果。
