# 栖语安全检查记录（2026-09-12）

2026-09-14 阅读说明：以下检查正文及 2026-09-13 交付记录保留各自时点的结论。后续独立复查又确认六项问题，协调实测追加第07项；历史“已修复”不表示后续问题已全部覆盖。当前产品状态、历史勘误和验收证据见文末「累计复查交付（2026-09-14）」。

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

2026-09-14 历史勘误：上述“尚未执行”为旧报告写作时状态，旧09后续已有两轮双轴报告。旧九票共留存 54 份报告，轮数为 4/3/3/3/3/2/3/3/2；这些静态文件不能单独证明当时代理身份或所有验收真实执行。Git 历史确认旧09报告提交为 `6c9c446607bdaba8a0757699bdab1de02bf8c799`，此前最后产品提交为 `7f5397ec70658b6e56c36857d08af29febec013e`；下表旧09的提交据此勘正，与本次报告提交区分。依据为本地 [历史提交核对](../../.scratch/security-followup-2026-09-13/logs/final-report-history-commit-check.md)及[旧实施复查](../../.scratch/security-implementation-review-20260913.md)。

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
| 09 集成验收与报告更新 | `6c9c446` | 全量验证、安卓构建与合并 manifest 检查，更新本报告 | — |

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

2026-09-14 证据勘误：旧实施复查确认，上述覆盖率只重算了既有文件，不能证明在旧最终产品上重新采集；旧 Windows 最终验证的完整原始输出也未保留。因此本节 1654 项、四个覆盖率数字及下述 69.39 MB APK 仅保留为旧日期记录，不充当本轮最终验收。2026-09-12 的 1571 项测试和依赖公告核对同样只对应原检查时点。

`scripts/verify-release-baseline.ps1` 完整发布门禁退出码 0（四包分析测试、Windows 打包校验与启动冒烟通过，产物 qiyu-windows-x64-0.1.0.zip）。

安卓 release 构建：`scripts/build-android-apk.ps1` 退出码 0，产出已签名 APK（版本 0.1.0(1)，69.39 MB，证书指纹与 `docs/engineering/android-release-build.md` 指纹表一致）。合并 manifest 从最终 APK 用 aapt2 反解核对：`allowBackup="false"`、`dataExtractionRules="@xml/data_extraction_rules"`、`fullBackupContent="@xml/backup_rules"` 三属性齐备；包内规则文件在云备份、设备迁移、跨平台迁移各节对 root/file/database/sharedpref 四域逐项排除；合并结果无第三方库注入的覆盖冲突，也无任何 `tools:replace` 冲突解决标记。

### 规范冲突的处置现状

《栖语system prompt/硬规则与优先级.md》的「运行层细则」至今仍写着流式输出首个字立即显示与服务端规则兜底召回；代码与仓库 AGENTS.md 维持完整安全校验后交付、模型隐藏动作触发召回。本轮加固按已批准的计划保持当前行为、不改外部笔记，因此两份文档的口径差异仍然存在，统一口径仍未裁定，待用户确认。

2026-09-14 状态补充：本轮已明确获准保持完整安全校验后交付及模型隐藏动作触发召回，无需再次等待行为授权。外部笔记未同步，口径差异仍保留；本次文档更新不修改笔记，也不将其写成已统一。

### 仍未验证项

- 真实安卓真机上的设备迁移（D2D）、跨平台迁移与覆盖升级未执行（本环境无真机）；合并 manifest 检查只在构建产物层面完成，不等于真机行为验证。真机冒烟清单见 [android-release-build.md](android-release-build.md)。
- 真实云模型攻击测试、浏览器自动化安全测试、持续占用型资源压测均未执行。
- 依赖核验停留在检查当日口径：本次未重新审计传递依赖、Flutter/Dart SDK、Gradle 与原生依赖。

## 累计复查交付（2026-09-14）

本轮总范围为 `6c9c446607bdaba8a0757699bdab1de02bf8c799` 至冻结产品 `de4ab02ed27f81b5561c5ff252091cd3798c3728`。范围包含独立复查的六项问题及真实 Host 合成探针追加的已完成旧回复重放问题，共七票；与上节旧九票分别编号。本次报告提交仅更新本文档，产品验证对象仍是该冻结产品树。

### 七票产品闭环

| 本轮工单 | 最终产品审查目标 SHA | 产品审查轮数 | 最后一轮规范轴 / 需求轴 |
| --- | --- | --- | --- |
| 01 JSON 凭据缺口 | `19144fc1a041ddf7bd18df3f8014f6b4cb0370ec` | 18 | 0 / 0 |
| 02 旧 pending 重试 | `a49604f2d2f5d09d85644cf58649414eafce1269` | 2 | 0 / 0 |
| 03 召回索引关键词 | `666a7f52624afb65373ca9aabf9a21b3c51f59aa` | 3 | 0 / 0 |
| 04 旧记忆 reveal | `7e6ffad2dd2136ae176ed22acc566717b384962d` | 3 | 0 / 0 |
| 05 ZIP 目录预算 | `03ea795ec2ace91047304c88a6b4892803621030` | 3 | 0 / 0 |
| 06 正常完成帧 | `988540dff09672d22c653106cd9aafe1d0b6c69a` | 2 | 0 / 0 |
| 07 已完成旧回复重放 | `de4ab02ed27f81b5561c5ff252091cd3798c3728` | 2 | 0 / 0 |

每票按至少两轮换人双轴执行，有效发现交原执行者修正；上表的 0 是报告发现数，不是审查进程退出码。闭环不要求连续两轮零发现。流程与身份记录见本地 `logs/01-review-process-closure.md`、`02-review-process-closure.md`、`03-review-process-audit.md` 至 `07-review-process-audit.md`，对应各票最终两轴报告位于 `reviews/`。第01首轮规范轴原生全文未归档、需求轴缺 `AGENT_EXIT` 的历史局限保留，不以报告数量补证。

第07首轮两轴各报 1P1，均为跨 messages 的 JSON 键值或 PEM 标记与正文丢失上下文。修正后第2轮两轴均为 0。**本次文档提交后的第3轮全新双轴仍待协调者安排**，需审查第07累计产品与文档差异；此处只确认产品闭环，不预填文档审查或整体任务完成。

### 修复结果与正常功能对照

本轮只处理已确认的凭据遗漏、安全资源异常路径和被安全改动破坏的兼容性。人格、记忆口语协议、模型触发召回、安全校验后交付、配置及 UI 保持现行行为，未作历史数据批量迁移。

- **01** 补齐已有凭据规则在 JSON 边界的遗漏。公共回归覆盖普通聊天、正常 JSON、非凭据数字、空值及占位文本；按既有语义区分接受结果与公开脱敏，避免扩大拒绝范围。曾获授权更正少量已证实错误的期望：一条本票新增占位后缀的接受期望，以及九条字面 note 契约的输出；后九条保持 Core 接受判定，修正错误的 JSON 引号/正文输出并遮蔽真实凭据。不能表述为“从未修改旧 expectation”。依据为 `logs/01-r9-fix-implementation.md`、`01-r11-fix-implementation.md` 及后者所列逐例输出。
- **02** 旧 pending 的原请求在重启后可重试，真正内容冲突仍拒绝；正常请求幂等与取消语义保持。已完成旧回复的公开脱敏另由07覆盖，没有把原02的修复范围扩大解释。[16 项回归及原始记录索引](../../.scratch/security-followup-2026-09-13/logs/02-implementation.md)。
- **03** 在召回索引关键词入口补齐既有凭据过滤，正常关键词和非凭据数字对照保持，召回仍由模型隐藏动作触发。[32 项受控索引回归及原始记录索引](../../.scratch/security-followup-2026-09-13/logs/03-r2-fix-implementation.md)。
- **04** 旧记忆 reveal 对外遮蔽凭据，普通敏感经历仍可按现行口语协议揭示；未用凭据过滤替换原有揭示语义。[13 项服务/真实 Host 回归及原始记录索引](../../.scratch/security-followup-2026-09-13/logs/04-r2-fix-implementation.md)。
- **05** ZIP 目录元数据计入预算，保留普通预览/导入、可选目录签名记录、传统编码注释及恰在预算内的组合；越界拒绝不产生导入副作用，原 schema、摘要与冲突语义保持。[5 项组合预算边界及完整所属包记录索引](../../.scratch/security-followup-2026-09-13/logs/05-r2-fix.md)。
- **06** 正常原生完成标记到达即结束，不再等待连接 EOF；包括 Anthropic 工具入口。提前 EOF、超时/原生错误、取消和传输预算继续受约束，未以取消预算换取正常完成兼容性。[104 项聚焦及原始记录索引](../../.scratch/security-followup-2026-09-13/logs/06-r1-fix-implementation.md)。
- **07** 已完成旧回复在完整逻辑上下文应用既有过滤，messages 与 text-only 均覆盖，delta 拼接、最终 message 与 restore 使用一致安全内容。普通消息边界、单条内部换行及 source/fallback/mode/safety/state 保持；重复、重启和取消对照保持事件序及单次 done。Provider 调用为零，不重新生成或人格校验，不改旧文件、不 appendTurn，也不重复隐藏动作或记忆节奏。正式跨消息 JSON、PEM 用例分别先以漏洞断言 exit 1，再同接缝 exit 0；观察探针 exit 0 未充当正式红绿。

上述对照由各票实施记录及最终两轴报告索引到公共测试和原始输出；07详见 [初次实施](../../.scratch/security-followup-2026-09-13/logs/07-implementation.md)与[完整上下文修正](../../.scratch/security-followup-2026-09-13/logs/07-fix1-implementation.md)。它们记录了中间版本，最终验收以以下冻结产品证据为准。既知笔记差异按已授权方案保留，外部笔记没有同步。

### 最终累计验证

以下证据均存于本地 `.scratch/security-followup-2026-09-13/`，不随本文档提交入库。核对依据是完整 raw、真实子进程退出码、受测源码清单和提交关联，不以“进程退出 0”代替具体断言或资源人工核对。

| 包 | 完整发布门禁测试 | 新采集行覆盖率 | 既有水位 |
| --- | --- | --- | --- |
| `qiyu_behavior_core` | 1092 项通过 | 89.09%（857/962） | 88% |
| `qiyu_local_host` | 1906 项通过 | 93.52%（9285/9928） | 92% |
| `qiyu_windows_host` | 28 项通过 | 93.59%（219/234） | 91% |
| `qiyu_flutter` | 704 项通过 | 93.77%（6279/6696） | 91% |

完整发布门禁四包合计 **3730 项**，另有浏览器 **19 项**通过；四包 analyze 均为 `No issues found`。发布策略、Flutter Web 构建及资源检查、Windows 生命周期测试、构建打包、包校验、自检和启动冒烟全部通过，完整门禁真实退出码为 0，不依赖 Node/npm。

门禁记录为 [07-fix1-release.result.json](../../.scratch/security-followup-2026-09-13/logs/07-fix1-release.result.json)，完整输出为同名前缀的 `.stdout.raw.log` / `.stderr.raw.log`。执行时 HEAD 是 `c844ee49d879cbc3c4ba88e1104c1902158feb56` 加修正工作树补丁；运行前后源码不变。随后 [07-fix1-post-commit-check.json](../../.scratch/security-followup-2026-09-13/logs/07-fix1-post-commit-check.json) 核对源码、四文件 Git blob 及累计补丁与 `de4ab02` 完全一致。因此累计验收复用这次同树门禁，未重复运行相同最终版本。

- 受测全源码清单 SHA-256：`09cedd07ec173fd9ed23ac92499a93c515174728f4552190932e9b151b22dd6e`。
- 第07固定起点 `988540d` 至冻结产品的受测/提交累计 patch SHA-256：`f78206649fb44418d81a712c43f8055eed3e5edad04610428f9ddd6887bbcb6c`；完整清单、逐文件哈希及 patch 原件保留在该 RunId 的记录中。

覆盖率于 2026-09-14 对 `de4ab02` **重新采集**，独立 RunId 为 `final-coverage-20260914-105300-8a789167422746f299dd5f99bbe4193c`。其 [coverage.json](../../.scratch/security-followup-2026-09-13/logs/final-coverage-20260914-105300-8a789167422746f299dd5f99bbe4193c/coverage.json) 记录 `succeeded`、`StableTrackedTree=true`，并绑定四份新 LCOV 的路径与哈希；同目录四包 `.log` 记录上表实际计数及全部适用 TEST/FORMAT/GATE 步骤 exit 0。四包均超过原水位，浏览器用例不计入覆盖率。这些数值与上节旧覆盖率分别保留。

### 新签名 APK 与资源核对

正式 `scripts/build-android-apk.ps1` 于 2026-09-14 对 `de4ab02` 执行成功。独立 RunId 为 `final-apk-build-20260914-105513-63ae7ee8c23442da84abb3fbcb398d83`；[build.json](../../.scratch/security-followup-2026-09-13/logs/final-apk-build-20260914-105513-63ae7ee8c23442da84abb3fbcb398d83/build.json) 及同目录 `build.log` 记录真实 exit 0、`succeeded`、`StableTrackedTree=true`。新产物为 `apps/qiyu_flutter/build/app/outputs/flutter-apk/app-release.apk`，版本 **0.1.0(1)**，大小 **72921347 字节**，APK SHA-256 为 `568f77b48c8f8f029ef27c729c6fc82613361657bbcf39ebff0bf43b57dfb48a`。构建日志 SHA-256 为 `1d9290c229830249719a3ddb84bf6cf5f49dac86df7b21edbd2eaef7fb38a230`。历史已有的 `CupertinoIcons` 字体提示仍出现，构建通过不表示零提示。

该新 APK 的检查 RunId 为 `final-apk-inspection-20260914-110537-ccdb4a7c714f43f89e6ca359461f72fa`。[inspection.json](../../.scratch/security-followup-2026-09-13/logs/final-apk-inspection-20260914-110537-ccdb4a7c714f43f89e6ca359461f72fa/inspection.json) 绑定上述构建记录及相同 APK 哈希，`inspection.log` 保留签名、badging、Manifest、资源表与两份编译 XML 的原始转储；[resource-review.md](../../.scratch/security-followup-2026-09-13/logs/final-apk-inspection-20260914-110537-ccdb4a7c714f43f89e6ca359461f72fa/resource-review.md) 记录随后实际人工核对通过：

- `apksigner` exit 0，v2 签名通过、单一签名者，证书 SHA-256 为 `74c1dadc57d233c83290c9d1469d36b38406153ccd90c43d3ae1e3eb7f5c52d7`，与既有发布身份一致。
- 应用标识 `dev.qiyu.app`，`versionName=0.1.0`、`versionCode=1`，`allowBackup=false`。
- `fullBackupContent=@0x7f0e0000` 映射到 `xml/backup_rules`、实际包内 `res/Qq.xml`；其 `full-backup-content` 排除 root/file/database/sharedpref 四域，path 均为 `.`。
- `dataExtractionRules=@0x7f0e0001` 映射到 `xml/data_extraction_rules`、实际包内 `res/4j.xml`；cloud-backup、device-transfer、cross-platform-transfer 三段均排除上述四域，path 均为 `.`，跨平台段为 `platform="ios"`。
- 五次 `aapt2` 调用均真实 exit 0。JSON 中的 `ready-for-resource-review` / `ResourceReview=pending` 仅为转储阶段状态，通过结论来自上述原始转储与随后人工核对记录。

首次辅助检查 `final-apk-inspection-20260914-105745-949814a121bc458fb804fd6d5e18da15` 因假设 APK 内仍使用源码资源文件名而失败，失败记录保留。确认资源表映射后只修正 scratch 辅助脚本，对同一 APK 复查通过；没有修改产品或重建、替换 APK，也没有把首次失败写成成功。

### 结论与剩余边界

本轮七项已确认发现已完成处理，上述冻结产品树的分析、测试、完整发布门禁、新采集覆盖率以及新签名 APK 的签名和资源核对均通过。本次仅补录正式报告，不修改产品、不重复测试或构建；报告提交 SHA 及相对产品 SHA 只含本文档的 Git 差异由本地 `logs/07-final-report-implementation.md` 记录。第07文档后的新双轴仍待执行，不能据此宣称所有任务已结束或所有潜在安全问题已消除。

真机 D2D、跨平台迁移、覆盖升级、真实云模型攻击、浏览器自动化安全测试、持续资源压测及完整供应链审计仍未验证。合成 Host/假模型回归、19 项普通浏览器测试及 APK 反解分别不能替代这些验收；17 个直接依赖的公告核对仍限定在 2026-09-12，未冒充本轮重新核验。外部设计笔记的既知口径差异和未同步状态继续保留。
