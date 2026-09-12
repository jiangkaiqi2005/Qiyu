# 栖语安全检查记录（2026-09-12）

检查基线为 `f37257c`，开始检查时工作区干净。本次未修改产品代码；使用源码审查、现有测试、临时复现和官方资料核验。确认 2 项 P1、3 项 P2，另记录 3 个可靠性优化点与 1 处规范冲突。

这里的 P1 表示应优先处理的凭据或隐私边界问题，P2 表示需要修复的条件性风险。这些问题不等同于已发生真实泄露，也不表示远程未认证用户能够直接访问 Host。

## 已确认的问题

### 1. P1：常见秘密格式绕过脱敏，落盘后进入后续模型上下文

位置：[markdown_memory_repository.dart:681](E:/Agent/Qiyu/packages/qiyu_local_host/lib/src/markdown_memory_repository.dart:681)、[私钥规则:693](E:/Agent/Qiyu/packages/qiyu_local_host/lib/src/markdown_memory_repository.dart:693)。

现有键值正则要求字段名后直接出现冒号或等号，无法识别 JSON 中字段名的结束引号。Cookie 规则在第一个分号停止。私钥规则要求 `BEGIN` 与 `PRIVATE KEY` 之间另有类型，遗漏常见的 PKCS#8 `BEGIN PRIVATE KEY`。

使用完全虚构的数据复现：

| 输入 | 实际结果 |
| --- | --- |
| `{"password":"audit-only-password"}` | 原样保留 |
| `Cookie: theme=dark; sid=audit-only-cookie` | 仅第一项被替换，`sid` 仍保留 |
| `-----BEGIN PRIVATE KEY-----` 包围的合成文本 | 原样保留 |

进一步通过真实进程内 Host 的 `/api/chat` 发送 JSON 样例：会话接口读回原密码；下一轮发送普通消息时，假模型捕获的历史上下文仍含该密码。后续 Provider 若配置为外部服务，该内容会随历史上下文发送。

这违反笔记《栖语记忆/Memory.md》的 secrets 不入库要求。建议补齐结构化键值、整行 Cookie、常见 PEM 格式，并在落盘及上下文装配处共用明确的秘密过滤规则。补回归时同时覆盖正常文本、常见秘密格式及下一轮上下文，避免只测试单个脱敏函数。

证据等级：端到端复现；没有使用真实密码、Cookie 或私钥。

2026-09-13 注：本问题已修复，见文末「修复交付（2026-09-13）」。

### 2. P1：被拒绝的模型回复仍能执行解除冻结等隐藏动作

位置：[local_chat_service.dart:415](E:/Agent/Qiyu/packages/qiyu_local_host/lib/src/local_chat_service.dart:415)、[动作执行入口:449](E:/Agent/Qiyu/packages/qiyu_local_host/lib/src/local_chat_service.dart:449)、[解除冻结:702](E:/Agent/Qiyu/packages/qiyu_local_host/lib/src/local_chat_service.dart:702)。

隐藏动作在候选回复校验前保存到 `hiddenActions`。行为核心拒绝可见回复并回退本地输出后，代码仍调用 `_applyHiddenActions`。`consumeWindow: outcome.source == ReplySource.llm` 仅控制整理窗口，未阻止控制动作执行。

复现流程：先冻结合成话题；用户仅发送“我到家了”；假模型返回禁用话术“我理解你的感受”，附带合法格式的 `memory_unfreeze` 动作。实际可见回复为本地“嗯”，`fallbackReason=forbidden_phrases`，冻结记录数量却从 1 变为 0。用户没有提出解除冻结。

建议拒绝候选回复时同时丢弃其隐藏动作，特别是解除限制、删除等改变用户控制的动作；另为解除控制增加对当前用户明确意图的验证。单纯验证动作 JSON 的格式和字段无法证明用户授权。测试需断言安全回退后控制文件和派生记忆均保持预期状态。

证据等级：端到端复现；仅改动临时目录中的合成冻结记录。

2026-09-13 注：本问题已修复，见文末「修复交付（2026-09-13）」。

### 3. P2：共享配置文件的并发写入能恢复已经删除的 API Key

位置：[provider_config.dart:674](E:/Agent/Qiyu/packages/qiyu_local_host/lib/src/provider_config.dart:674)、[段级保存:758](E:/Agent/Qiyu/packages/qiyu_local_host/lib/src/provider_config.dart:758)。

聊天配置与语音、搜索、代理配置共用 `provider.json`。各保存操作都先读取整份文件，在内存中修改自己的字段，再原子替换整份文件。原子替换保障单次写入完整，却没有保护整个读改写过程。

在现有 `AtomicTextWriter` 接缝注入屏障，复现确定的执行顺序：删除聊天 Key 的保存与搜索设置保存都读到旧文件；先完成 Key 删除，读回确认 Key 已清空；随后完成搜索设置保存，旧 Key 随旧文件副本重新写回。两个操作均正常返回。

建议让共享仓储串行执行完整的读改写过程，覆盖聊天保存、遗忘 Key 和全部子段保存。锁应覆盖读取之前至写入结束，不能仅包住 `rename`。回归应交错执行遗忘凭据与无关设置保存，并验证各段及 Key 均不回退。

证据等级：仓储层确定性交错复现；未使用真实凭据。

2026-09-13 注：本问题已修复，见文末「修复交付（2026-09-13）」。

### 4. P2：安卓 `allowBackup=false` 不能完整兑现禁止设备迁移的承诺

位置：[AndroidManifest.xml:12](E:/Agent/Qiyu/apps/qiyu_flutter/android/app/src/main/AndroidManifest.xml:12)、[数据目录装配:50](E:/Agent/Qiyu/apps/qiyu_flutter/lib/features/baseline/host_bootstrap_io.dart:50)。

Manifest 注释声称 `allowBackup=false` 同时覆盖 Android 12+ 的云备份和 D2D 迁移，因此无需其他配置。Android 官方说明恰好指出：部分厂商设备上，该属性只禁用云备份，无法禁用设备间迁移。应使用 `dataExtractionRules` 分别配置迁移和备份的排除范围。[Android 官方备份文档](https://developer.android.com/identity/data/autobackup)

实际运行数据位于应用 support 私有目录，包含记忆以及明文保存 Key 的 `provider.json`，不是默认排除的缓存目录。因此不能仅凭当前属性声称这些数据不会迁移。

建议为 Android 12+ 明确配置设备迁移排除规则，并按支持的旧版本补相应备份规则；检查合并后的 release manifest，再做真实设备迁移验证。不能把所有设备的数据泄露作为既成事实。

证据等级：源码与官方平台文档核验；未进行安卓真机迁移复现。

2026-09-13 注：排除规则已修复并经构建产物核对，真机迁移仍未验证，见文末「修复交付（2026-09-13）」。

### 5. P2：备份解压体积检查发生得过晚

位置：[memory_backup.dart:434](E:/Agent/Qiyu/packages/qiyu_local_host/lib/src/memory_backup.dart:434)。

验证器先通过 `entry.content` 解压整项并复制为 `Uint8List`，随后才累计长度、与 1 GiB 上限比较。检查当前锁定的 `archive 4.2.0` 源码可确认，读取 deflate 条目内容会进行内存解压，未在这条调用中传入应用层输出预算。因此小体积、高压缩率的包能在被拒绝之前消耗大量内存；请求体大小限制无法限制解压后的体积。

触发条件是用户通过已有会话预览或导入不可信备份，并非未认证远程请求。安卓内存更紧张，且当前同步解压会阻塞运行它的 isolate。

建议先检查条目数量、允许路径和声明大小，再使用受实际输出预算约束的解压方式；声明大小不能替代真实累计计数。预算应同时限制单项和总量，避免整项额外复制，并评估将解压移出 UI/Host 所在 isolate。压缩包元信息解析也应受资源限制。

证据等级：应用与当前依赖源码确认。未运行会耗尽内存的压缩炸弹，也未测量真实设备崩溃阈值。

2026-09-13 注：本问题已修复，见文末「修复交付（2026-09-13）」。

## 其他值得优化的地方

1. **备份导入、回滚与后台写入需要统一排他边界。** [backup_routes.dart:66](E:/Agent/Qiyu/packages/qiyu_local_host/lib/src/backup_routes.dart:66) 和第 84 行直接执行导入、回滚，同文件的清除操作则经 `runExclusively` 等待聊天与后台任务。建议让会改写整套数据的操作遵守同一边界，并验证导入期间的在途聊天、日终整理和再次导入。本次仅确认调用路径差异，未复现具体的数据丢失。

   2026-09-13 注：已按本项修复，见文末「修复交付（2026-09-13）」。

2. **回滚失败时应如实报告恢复状态。** [memory_backup.dart:838](E:/Agent/Qiyu/packages/qiyu_local_host/lib/src/memory_backup.dart:838) 捕获恢复异常后仍返回“本机数据已恢复到导入前的状态”。建议按恢复成功或失败返回不同结果，并保留可供后续恢复的快照信息。本次仅作源码检查，未注入双重写入故障。

   2026-09-13 注：已按本项修复，见文末「修复交付（2026-09-13）」。

3. **Provider 原始传输层也应有限长和总时限。** [model_gateway.dart:512](E:/Agent/Qiyu/packages/qiyu_local_host/lib/src/model_gateway.dart:512) 整段收集错误响应，第 535 行通过 `LineSplitter` 缓冲流。聊天服务的 8192 runes 上限作用于已解析的文本增量，不能保护未换行的大数据或持续发送的无效事件。建议在解码、分行前限制字节数与单帧长度，并设置整体请求期限。本次未做持续占用型压测。

   2026-09-13 注：已按本项修复，见文末「修复交付（2026-09-13）」。

## 已有保护与验证结果

本次核对的实现包含：Host 绑定 `127.0.0.1`、精确 Host 检查、一次性启动凭据、HttpOnly/SameSite Cookie、API 会话与同源/CSRF 检查、CSP、禁止 Provider HTTP 自动重定向，以及正常 Provider 协议路径上的完成标记检查与本地回退。未在本次检查中复现未认证 API 访问。

| 验证 | 结果 |
| --- | --- |
| `packages/qiyu_behavior_core`：`dart test` | 69 项通过 |
| `packages/qiyu_local_host`：`dart test` | 770 项通过 |
| `apps/qiyu_windows_host`：`dart test` | 28 项通过 |
| `apps/qiyu_flutter`：`flutter test` | 704 项通过 |
| `packages/qiyu_local_host`：`dart analyze` | 无问题 |
| 合成数据复现 | 第 1、2、3 项确认 |

四包共 1571 项既有测试通过。临时复现脚本使用假模型与临时数据目录，没有向 Provider 发出真实请求。脚本及日志留在本机 `.scratch/security-audit-probes.dart`、`.scratch/security-audit-probes.log`；未把复现问题的脚本加入正式回归套件。

另按四包 lockfile 查询了 17 个直接生产依赖的 pub.dev 公告，返回的公告未命中当前锁定版本。`archive 4.2.0` 高于两条历史公告的修复版本 `3.3.8`，`http 1.6.0` 高于其历史公告修复版本 `0.13.3`。这不能替代传递依赖、Flutter/Dart SDK、Gradle 或原生依赖的完整供应链审计。[archive 公告接口](https://pub.dev/api/packages/archive/advisories)、[http 公告接口](https://pub.dev/api/packages/http/advisories)

## 规范冲突与检查边界

笔记《栖语system prompt/硬规则与优先级.md》的“运行层细则”仍要求首个原始字立即显示和规则兜底召回。仓库 AGENTS.md 与实际代码则采用完整安全校验后交付、模型隐藏动作触发召回。已在检查过程中报告差异，本次未自行裁定、同步或改变行为。后续应由用户确认统一口径。

知识图谱用于代码定位，但相关覆盖元数据提示文件发生变化，聊天编排还有解析缺口；报告中的关键结论均回到当前源码或执行结果核对，没有用图谱缺少结果来证明不存在风险。

本次未修改行为、构建发布包或运行完整 release 门禁；没有做真实云模型攻击测试、浏览器自动化安全测试、真实安卓迁移或耗尽资源压测。建议优先修复秘密脱敏和隐藏动作执行边界，其次处理配置写入竞争、安卓迁移规则和受限解压。

2026-09-13 注：上述门禁与安卓构建已在修复完成后补跑，结果见文末「修复交付（2026-09-13）」；列出的未执行检查除门禁与构建外仍然未执行。

## 修复交付（2026-09-13）

本节由集成验收补充。正文其余部分保留 2026-09-12 检查当日原貌，不作改写。

上文确认的 2 项 P1、3 项 P2 与 3 个优化点，随后按九张工单逐项修复，全部提交在 develop 分支本地完成（总基线 `f37257c`，至本节更新时 HEAD 为 `7f5397e`，未推送）。每张工单由独立执行者实施，并经至少两轮全新的规范轴与需求轴双轴审查（票 01 四轮，票 02、03、04、05、07、08 各三轮，票 06 两轮），全部有效问题清零。本票（09）自身的独立双轴审查在本次报告更新时尚未执行。

### 提交清单

| 工单 | 提交 | 交付内容 | 对应本报告发现 |
| --- | --- | --- | --- |
| 01 秘密脱敏闭环 | `6de1d85`、`a6f183a`、`9266d03`、`c524579` | 补齐 JSON 键值、整行 Cookie 与常见 PEM 的脱敏，覆盖新写入、旧数据读取、模型上下文与备份导出 | 问题 1（P1） |
| 02 隐藏动作执行边界 | `9017594`、`04621b9`、`588d4fb`、`a49de90`、`9f96c3d`、`7c89a8b` | 只有完整且被接受的模型回复才能提交隐藏动作，被拒、失败、取消三路均不执行解除冻结、删除、写入等动作 | 问题 2（P1） |
| 03 配置写入原子事务 | `a8c5412`、`e4e357c` | 共享 `provider.json` 的全部读改写经串行事务入口，删除 Key 不再被并发保存写回 | 问题 3（P2） |
| 04 安卓备份与迁移排除 | `a4f04f7`、`38af694` | 新增云备份、设备迁移与跨平台迁移的逐域排除规则，Android 12+ 与 7–11 两套规则齐备 | 问题 4（P2） |
| 05 备份受限解压 | `45388e3` | 备份预览与导入改为先校验目录与声明值，再按条目数、单项、总量与目录元数据预算逐块解压 | 问题 5（P2） |
| 06 备份与后台写入隔离 | `c6b4df0`、`7dbbd19` | 导出、导入、回滚、清除共用维护独占边界，等待在途聊天与后台整理，期间新任务排队 | 优化点 1 |
| 07 恢复状态如实反馈 | `78d4b75` | 恢复写回或必要清理失败时返回 restore-incomplete，不再声称已恢复，快照保留可再次恢复 | 优化点 2 |
| 08 Provider 传输预算 | `0ee9e92`、`efa9b20`、`7f5397e` | 模型响应在解码分行前限制单帧 1 MiB、单响应 16 MiB、错误体 64 KiB，并设整体期限，五种终态统一关闭连接 | 优化点 3 |
| 09 集成验收与报告更新 | 本提交 | 全量验证、安卓构建与合并 manifest 检查，更新本报告 | — |

### 最终验证结果

2026-09-13 在 HEAD `7f5397e` 实测：

| 验证 | 结果 |
| --- | --- |
| 四包 `dart analyze` / `flutter analyze` | 均无问题 |
| `packages/qiyu_behavior_core`：`dart test` | 72 项通过 |
| `packages/qiyu_local_host`：`dart test` | 850 项通过 |
| `apps/qiyu_windows_host`：`dart test` | 28 项通过 |
| `apps/qiyu_flutter`：`flutter test` | 704 项通过 |

四包共 1654 项测试通过（检查时点为 1571 项，新增用例均来自上述修复的回归）。

覆盖率按 `scripts/coverage_gate.dart` 门禁核对（采集方式与持续集成一致），均不低于既有水位：行为核心 90.50%（水位 88）、Windows 宿主 93.59%（水位 91）、本机服务 93.24%（水位 92）、应用界面 93.77%（水位 91）。

`scripts/verify-release-baseline.ps1` 完整发布门禁退出码 0（四包分析测试、Windows 打包校验与启动冒烟通过，产物 qiyu-windows-x64-0.1.0.zip）。

安卓 release 构建：`scripts/build-android-apk.ps1` 退出码 0，产出已签名 APK（版本 0.1.0(1)，69.39 MB，证书指纹与 `docs/engineering/android-release-build.md` 指纹表一致）。合并 manifest 从最终 APK 用 aapt2 反解核对：`allowBackup="false"`、`dataExtractionRules="@xml/data_extraction_rules"`、`fullBackupContent="@xml/backup_rules"` 三属性齐备；包内规则文件在云备份、设备迁移、跨平台迁移各节对 root/file/database/sharedpref 四域逐项排除；合并结果无第三方库注入的覆盖冲突，也无任何 `tools:replace` 冲突解决标记。

### 规范冲突的处置现状

《栖语system prompt/硬规则与优先级.md》的「运行层细则」至今仍写着流式输出首个字立即显示与服务端规则兜底召回；代码与仓库 AGENTS.md 维持完整安全校验后交付、模型隐藏动作触发召回。本轮加固按已批准的计划保持当前行为、不改外部笔记，因此两份文档的口径差异仍然存在，统一口径仍未裁定，待用户确认。

### 仍未验证项

- 真实安卓真机上的设备迁移（D2D）、跨平台迁移与覆盖升级未执行（本环境无真机）；合并 manifest 检查只在构建产物层面完成，不等于真机行为验证。真机冒烟清单见 [android-release-build.md](android-release-build.md)。
- 真实云模型攻击测试、浏览器自动化安全测试、持续占用型资源压测均未执行。
- 依赖核验停留在检查当日口径：本次未重新审计传递依赖、Flutter/Dart SDK、Gradle 与原生依赖。
