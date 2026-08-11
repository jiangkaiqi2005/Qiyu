# qiyu_windows_host

栖语的 Windows 本机 Dart 宿主。它只绑定 `127.0.0.1` 的随机端口，提供已经构建好的 Flutter Web 资源，并为本机 API 建立一次性启动会话。

```powershell
# 先构建相邻的 Flutter Web 工程
Push-Location ..\qiyu_flutter
flutter build web --no-web-resources-cdn
Pop-Location

# 启动并打开默认浏览器；Ctrl+C 停止宿主
dart run

# 只检查平台、行为核心和 Web 资源
dart run -- --check

# 从仓库根目录生成可搬移的 Windows 分发目录
Push-Location ..\..
npm run build:windows-bundle
Pop-Location
```

完整产物位于 `apps\qiyu_windows_host\build\windows-bundle\`，其中 `qiyu_windows_host.exe` 和 `web\` 必须一起移动或打包。exe 优先读取自身旁边的 `web\index.html`，因此从仓库外工作目录启动也不依赖开发树。

开发和验证时可用 `--no-browser` 禁止自动打开浏览器，用 `--web-root <path>` 指定 Web 资源目录，用 `--runtime-dir <path>` 隔离单实例状态。正常运行会始终打印可复制的本机地址；若浏览器启动失败，也可手动打开该地址。
