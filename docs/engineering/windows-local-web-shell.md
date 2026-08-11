# Windows 本机 Web 外壳

本实现对应 `.scratch/qiyu-local-flutter-windows/issues/02-launch-windows-local-web-shell.md`。Windows 可执行程序负责在本机启动 Flutter Web 页面，不提供远程静态站点，也不开放局域网访问。

## 启动与退出

宿主通过 `shelf` 绑定 `127.0.0.1:0`，由操作系统选择可用端口，并通过 `shelf_static` 提供 `apps/qiyu_flutter/build/web/`。启动成功后调用 Windows 默认浏览器；无论浏览器调用是否成功，控制台都会输出可复制的本机地址。主实例接收 `Ctrl+C` 后关闭 HTTP 服务并释放端口。

单实例状态位于 `%LOCALAPPDATA%\Qiyu\runtime`。主实例持有 `instance.lock` 的独占文件锁并发布地址和内部激活凭据；第二次启动拿不到锁时只请求主实例重新打开当前页面，不再监听第二个端口。锁和描述文件都随主实例退出释放。

开发运行：

```powershell
Push-Location apps\qiyu_flutter
flutter build web --no-web-resources-cdn
Pop-Location

Push-Location apps\qiyu_windows_host
dart run
Pop-Location
```

## 页面会话与本机 API

每次宿主进程都会生成新的启动凭据、会话凭据、CSRF 凭据和单实例激活凭据。浏览器首先访问带本次进程专用凭据的 `/_session/start`，宿主写入 `HttpOnly; SameSite=Strict` 的 `qiyu_session` Cookie 后跳转到 `/`，避免凭据继续留在页面地址中。宿主重启会生成全新凭据，因此旧页面不能继续调用新进程的 API。

所有请求必须使用当前随机端口对应的精确 `Host`。`/api/*` 还必须携带当前会话；来源存在时必须与宿主同源，修改请求必须同时携带同源 `Origin` 和从 `GET /api/bootstrap` 取得的 `x-qiyu-csrf`。当前健康检查为 `GET /api/health`。安全响应头将脚本、连接、图片和字体限制为本机资源，只为 Flutter 的本地 WebAssembly 开启 `wasm-unsafe-eval`；构建固定使用 `--no-web-resources-cdn`，同时打包 CanvasKit 和当前迁移空壳所需的 `Noto Sans SC` 字符子集，不依赖远程 CDN。

字体子集来自 Google Fonts 的 `ofl/notosanssc/NotoSansSC[wght].ttf`，保留基础 ASCII 和当前迁移空壳的中文字符，并同时注册为 CanvasKit 的默认 `Roboto` 回退，避免引擎请求远程默认字体；随附原始 `OFL.txt`，采用 SIL Open Font License 1.1。新增 Flutter 文案时必须同步扩展该子集并通过可执行程序演示，避免缺字回退到远程字体。

Flutter 页面每两秒探测一次健康接口。宿主停止或当前会话失效后，页面显示“本机程序已停止”，提示用户重新启动本机程序。

## 直接依赖

| 工程 | 依赖 | 当前约束 | 用途 |
| --- | --- | --- | --- |
| Windows 宿主 | `shelf` | `^1.4.2` | Dart 团队维护的 HTTP 中间件与服务接口。 |
| Windows 宿主 | `shelf_static` | `^1.1.3` | Dart 团队维护的本地静态资源处理器。 |
| Windows 宿主 | `path` | `^1.9.1` | 跨平台解析构建产物和运行目录。 |
| Flutter Web | `http` | `^1.6.0` | Dart 团队维护的健康检查客户端，并提供可注入测试接缝。 |

以上四个包均采用 BSD-3-Clause 许可证。单实例使用 Dart SDK 的 `RandomAccessFile.lockSync(FileLock.exclusive)`，没有额外引入 Windows FFI 包。

## 验证

```powershell
npm run verify:migration-baseline
```

宿主测试覆盖随机回环端口、端口释放、静态资源、单实例激活、浏览器失败回退、启动凭据重启失效，以及 Host、Origin、会话和 CSRF 校验。Flutter 测试覆盖健康检查成功/失败和主机停止提示。验证脚本还会构建 Flutter Web、编译 Windows exe、执行 `--check`，并回归 Dart 契约、JavaScript 测试和黄金行为评测。
