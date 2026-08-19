# Windows 本机 Web 宿主

Windows Release 1 由编译后的 Dart Host 在 `127.0.0.1:0` 提供随包 Flutter Web 资源和本机 API。端口由系统分配；程序打开默认浏览器。它不是远程业务服务器，也不提供 LAN 模式。

## 用户启动与退出

候选 zip 解压后运行 `install.cmd`。安装到当前用户目录并创建桌面、开始菜单快捷方式；重复运行执行原位升级，且不触碰 `%USERPROFILE%\.qiyu`、Provider 设置或 Windows Credential Manager 中的 Key。

从快捷方式启动后，主实例持有 `%LOCALAPPDATA%\Qiyu\runtime` 下的独占锁。再次启动只激活已有实例，不建立第二个记忆写入者。显式关闭 Host 才停止本机 runtime；关闭浏览器标签页不会删除或停止数据。

卸载运行安装目录中的 `uninstall.cmd`。未明确选择保留或永久删除数据时取消操作。删除边界只允许经产品标识校验的专用 Qiyu 程序、数据、运行目录和 `Qiyu.Provider.ApiKey.*` 凭据命名空间。

## 开发启动与构包

```powershell
Push-Location apps\qiyu_flutter
flutter build web --no-web-resources-cdn
Pop-Location

Push-Location apps\qiyu_windows_host
dart run
Pop-Location

& .\scripts\build-windows-bundle.ps1
```

输出为 `apps\qiyu_windows_host\build\windows-bundle\` 与同目录下的 `qiyu-windows-x64-<version>.zip`。版本来自 Windows Host 的 `pubspec.yaml`，不读取旧 Web 产品元数据。

## 会话与安全

每次 Host 启动生成新的启动 token、本机会话、CSRF 和单实例激活凭据。浏览器首次访问 `/_session/start` 后收到 `HttpOnly; SameSite=Strict` cookie，再跳转到不含 token 的页面。宿主重启后旧 cookie 失效。

所有请求必须使用当前回环端口的精确 Host。API 需要当前会话；修改请求还需同源 Origin 与 `x-qiyu-csrf`。静态资源策略只允许本地脚本、字体、图片和连接；构建使用 `--no-web-resources-cdn` 并随包携带 CanvasKit 与字体。

Provider 请求由 Host 发起。非敏感设置写入本机 runtime；API Key 写入 Windows Credential Manager。API、日志、备份和 Markdown 不返回或保存明文 Key、Cookie、CSRF、第三方错误正文及真实用户路径。

## 数据目录

记忆目录优先级为 `--memory-dir`、`QIYU_MEMORY_DIR`、`%USERPROFILE%\.qiyu\memories`。sessions 每段最多 80 turns，活动历史恢复窗口 180 天；历史 Markdown 不自动删除。运行目录可由 `--runtime-dir` 覆盖，便于隔离验收。

## 验证

```powershell
& .\scripts\verify-release-baseline.ps1
```

门禁覆盖 Core/Flutter/Host、安装升级卸载、清单哈希、许可证、远程静态引用、敏感信息、非 Windows/调试产物、无开发工具 PATH 预检和真实页面启动。进一步的候选包验收记录见 `.scratch\ticket26-release\`。
