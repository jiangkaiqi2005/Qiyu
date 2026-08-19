# 栖语

栖语是一个完全在本机运行的睡前 AI 陪伴产品：打开后直接聊天，关闭标签页或重启宿主后，聊天、关系和 Markdown 记忆仍会延续。未配置模型时也能使用本地规则回复；配置自己的 Provider 后，由 Windows 本机 Host 代发请求，API Key 不进入浏览器。

## Windows 使用

普通用户不需要安装 Node、Dart 或 Flutter。

1. 解压 `qiyu-windows-x64-<version>.zip`。
2. 运行 `install.cmd`，完成当前用户安装。
3. 从桌面或开始菜单打开“栖语”；本机程序会在 `127.0.0.1` 启动并打开默认浏览器。
4. 在设置中选择 OpenAI-compatible、Anthropic 或 Ollama，填写自己的 Provider 信息；也可以跳过并直接离线聊天。

卸载时运行安装目录中的 `uninstall.cmd`。脚本会明确询问保留还是永久删除聊天、Markdown 记忆、Provider 设置和 API Key。

## 数据与安全边界

- 记忆默认位于 `%USERPROFILE%\.qiyu\memories`，可用 `QIYU_MEMORY_DIR` 覆盖；开发调试还可传 `--memory-dir`。
- Provider 非秘密设置位于 `%LOCALAPPDATA%\Qiyu`，API Key 保存在 Windows Credential Manager。
- Host 只监听回环地址，并校验本机会话、Host、Origin 与 CSRF；浏览器拿不到 Key 明文和真实记忆路径。
- 除用户主动配置的模型 Provider 外，产品不访问栖语远端服务，不提供账号、云同步或远程托管页面。
- iOS 与 Android 是后续适配范围；Release 1 不实现移动端、云同步或旧 localStorage 迁移。

## 开发与发布

开发机需要当前锁定版本所兼容的 Dart 与 Flutter SDK。以下命令均从仓库根目录运行：

```powershell
& .\scripts\verify-release-baseline.ps1
& .\scripts\build-windows-bundle.ps1
```

全量门禁依次运行 Dart Core 分析与契约测试、Flutter 分析/Widget 测试/Web 构建、Windows Host 分析与测试、安装生命周期测试、候选包清单/敏感信息检查、仓库外预检和启动冒烟。它不执行 Node/npm。

输出位于：

- 可移动目录：`apps\qiyu_windows_host\build\windows-bundle\`
- 发布压缩包：`apps\qiyu_windows_host\build\qiyu-windows-x64-<version>.zip`

单独验证各层：

```powershell
Push-Location packages\qiyu_behavior_core
dart analyze
dart test
Pop-Location

Push-Location apps\qiyu_flutter
flutter analyze
flutter test
Pop-Location

Push-Location apps\qiyu_windows_host
dart analyze
dart test
Pop-Location
```

## 故障排查

- 启动前检查候选包：运行 `qiyu_windows_host.exe --check`。
- 浏览器未自动打开：复制 Host 控制台输出的 `http://127.0.0.1:<port>/...` 地址。
- 页面提示本机程序停止：关闭旧标签页，从快捷方式重新启动栖语。
- Provider 失败：在设置页分别运行“测试连接”和“测试栖语回复”；诊断只显示脱敏后的错误类别。
- 数据异常：先导出完整 Markdown 备份，再从记忆中心查看恢复结果；不要直接覆盖运行中的记忆目录。

## 文档入口

- `AGENTS.md`：当前架构、行为约束和验证命令。
- `docs/engineering/windows-release-baseline.md`：Release 1 能力证据与行为对拍。
- `docs/engineering/windows-local-web-shell.md`：Windows Host、安装和安全边界。
- `docs/product/behavior-spec.md`：工程行为规范。
- `栖语产品灵魂.md`：人格与可见行为的最高设计依据。
