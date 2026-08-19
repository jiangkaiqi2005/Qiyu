# qiyu_windows_host

栖语 Windows 本机 Dart Host：只绑定 `127.0.0.1`，提供 Flutter Web、受保护的本机 API、Provider、Windows 凭据、Markdown 记忆、Dream、备份与恢复。

```powershell
# 开发运行
Push-Location ..\qiyu_flutter
flutter build web --no-web-resources-cdn
Pop-Location
dart run

# 平台与随包资源预检
dart run -- --check

# 在仓库根目录构建候选包
Push-Location ..\..
& .\scripts\build-windows-bundle.ps1
Pop-Location
```

输出目录为 `build\windows-bundle\`，zip 为 `build\qiyu-windows-x64-<version>.zip`。用户运行 `install.cmd` 安装或升级，运行安装目录中的 `uninstall.cmd` 并明确选择是否保留数据。

便携运行时必须一起移动 `qiyu_windows_host.exe`、`web\`、`persona-constitution.md`、安装卸载脚本与 `licenses\`。exe 优先读取自身旁边的资源，因此不依赖仓库和当前工作目录。

记忆目录优先级为 `--memory-dir <path>`、`QIYU_MEMORY_DIR`、`%USERPROFILE%\.qiyu\memories`。开发和验收还可用 `--no-browser`、`--web-root` 与 `--runtime-dir`；正常启动始终打印可复制的本机地址。
