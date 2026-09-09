# 安卓端内形态：原生编译＋进程内 loopback

2026-09-09 拷问裁定：栖语上安卓采用「手机自成一体」的端内形态——APK 内含行为核心、平台无关 Host 服务与原生编译的 Flutter UI，数据与密钥只存在手机上，跨设备只靠手动导出。UI 走 Flutter 原生编译（仓库特意隔离的 4 个 `*_platform_web.dart` 条件导入文件就是预留接缝）；Host 服务在 App 进程内 bind 127.0.0.1 随机端口，会话/Origin/CSRF/交付校验安全模型原样保留，不拆卡口。平台无关 Host 逻辑抽成 `qiyu_local_host` 纯 Dart 包，Windows 壳与安卓壳对称注入各自凭据仓（Windows 凭据管理器 / Android Keystore 支撑的安全存储）。

## Considered Options

- **WebView 套壳**：UI 零改动、最快见 APK，但麦克风权限桥接、返回键、下载监听这些活干完也是弃子，且 Flutter Web 包在 WebView 里启动重，长期留「网页套壳」债。
- **绕过 HTTP 直调行为核心**：省微秒级 loopback 开销，代价是拆掉安全校验卡口、Web 与安卓两端从此分叉——违反「页面绝不能看到未经安全校验的原始 token」不变量。
- **手机当远程显示器 / 云端 Host**：需要 PC 常开，或把密钥、原始对话、记忆送出设备，违反隐私优先红线。
- **不拆包、条件排除 Windows 代码**：「windows_host 跑在安卓上」名实不符，条件排除的结构扭曲会长期生息。

## Consequences

- 原生 http 客户端要自己接管会话 Cookie 与 Origin 头（浏览器原来免费提供）。
- 签名 keystore 从第一天自建并备份：换 keystore＝签名不匹配＝必须卸载重装＝私有目录数据全丢。
- 局域网 Ollama 需要 Android 明文 HTTP 白名单，只放行用户显式配置的私有网段地址。
- 豆包/火山直连零新增；OpenAI/Anthropic 需要 App 内代理配置。
- 不做后台常驻：记忆节奏靠启动补扫与空闲补办，与 PC 行为一致。
