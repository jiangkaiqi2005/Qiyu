# Ticket 25 Windows 发布验收记录

## 结论

- 候选版本：`0.1.0`，x64，输出为
  `apps/qiyu_windows_host/build/qiyu-windows-x64-0.1.0.zip`。
- `run-release-acceptance.ps1` 于 2026-08-20 在 Windows
  `10.0.26200.0` 上完成隔离目录实测，机器可见结果见
  `acceptance-results.json`。
- 派发 prompt 引用的 Obsidian `T25-记忆中心UI接管.md` 与本票编号冲突，不是
  Windows 打包设计。实现依据为产品灵魂、`栖语启动.md`、Flutter Windows 产品
  Spec 与本票清单；未发现实质设计冲突。

## 实测范围

1. 使用真实候选 bundle 安装到隔离的用户级目录，创建开始菜单与桌面快捷方式；在
   只保留 Windows 系统目录的 `PATH` 下运行已安装 exe 的 `--check`，不依赖 Node、
   Flutter、Dart 或仓库目录。
2. 未配置 Provider 时通过真实 Host API 聊天，事件状态为
   `source=local`、`fallbackReason=no_llm_config`。
3. 从环境变量读取 DeepSeek Key（不写日志、不写留档），通过独立 credential scope
   保存到 Windows Credential Manager；真实聊天状态为 `source=llm`，读取设置不返回
   明文 Key。
4. 强制结束宿主后重新启动：旧 cookie 返回 401；Provider、Key、同一 session 的
   4 个 turn 均恢复。
5. 导出 2297 字节 Markdown 备份，清空隔离 memory 后预览并恢复 1 个文件。
6. 同 runtime 第二次启动正常转交已有实例；独立 runtime 同时启动时由 `:0` 分配不同
   端口。
7. 监听地址为 `127.0.0.1`，本机非回环地址连接失败；异常 Host/Origin、缺失 CSRF
   分别返回 403，无会话伪造修改与重启后的旧 cookie 返回 401。
8. 真实执行同目录覆盖安装；历史候选安装包不存在，因此跨版本升级另由生命周期测试
   的 `0.1.0-test.1 → 0.1.0-test.2` 验证程序替换、Markdown 与运行配置留存。
9. 真实执行“保留数据”卸载后数据与 Key 均存在；重新安装后执行“永久删除数据”卸载，
   程序、隔离数据、快捷方式与本次专用 credential target 均删除。

## 环境限制

- 当前会话无管理员权限，查询 Windows Sandbox 即被系统拒绝，因此没有在独立干净 VM
  中执行；隔离用户目录与去开发工具 `PATH` 不能冒充干净 VM。
- 实机默认浏览器可用。为了不破坏用户系统关联，没有人为制造浏览器启动失败；该路径由
  `host_runner_test.dart` 验证失败时返回可复制的本机 URL。
- 没有重启当前用户电脑。已验证强制退出后的进程重启留存；安装器不写开机自启，符合
  Spec“首版由用户启动本机程序”的边界。

## 复现

```powershell
npm run build:windows-bundle
powershell -NoProfile -ExecutionPolicy Bypass -File `
  .scratch\ticket25-release\run-release-acceptance.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File `
  scripts\verify-windows-package.ps1 `
  -BundlePath apps\qiyu_windows_host\build\windows-bundle `
  -ArchivePath apps\qiyu_windows_host\build\qiyu-windows-x64-0.1.0.zip
```

运行期 `work/`、Host stdout/stderr 与备份 zip 被本目录 `.gitignore` 排除；提交中只保留
无凭据的脚本、结论和结构化结果。
