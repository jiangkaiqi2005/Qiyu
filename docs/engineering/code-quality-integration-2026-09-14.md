# 2026-09-14 代码质量集成验收记录

**状态：第 08 票已完成；自动门禁通过，独立双轴评审按用户最新指令免除（未执行，不视为审查通过）。**

## 固定范围

本次接续机器本地 `code-quality-2026-09-14` 交接，不重做已完成的 01–07。

- 专题差异基线：`120871ca818433db3bd87a5d34e663988bfb2268`。
- 本次所有测试与构建的源码提交：`c650a80b292f91e5f224e94645964cf3a6e9cfb6`。
- 验证分支：`chore/code-quality-2026-09-14`，从上述 `develop` 提交建立。
- 干净短路径 worktree：`E:/QiyuQA-0914`；原工作区 `E:/Agent/Qiyu` 保持在 `develop`。
- 01–07 的实现和既有独立审查已在源码提交内。本次没有修改生产代码、测试、依赖锁文件或行为契约；入库变更仅此验收记录，不以空提交制造实现进度。

验收后提交本记录产生的文档提交不是测试时的 HEAD。测试、覆盖率和构建均明确关联上面的源码提交，不声称在之后的文档提交重跑了全量检查。

## 实际环境与四包门禁

Windows PowerShell；Flutter **3.44.8**、Dart **3.12.2**，可执行文件位于 `D:/Flutter/flutter/bin`。各包使用新的覆盖率目录，没有复用原工作区的 coverage。

| 包 | 分析 | 全量测试 | 实测行覆盖率 | 门槛 | 结果 |
| --- | --- | ---: | ---: | ---: | --- |
| `packages/qiyu_behavior_core` | 无问题 | 1,136 | 90.35%（918/1,016） | 88% | 通过 |
| `packages/qiyu_local_host` | 无问题 | 1,984 | 93.98%（9,535/10,146） | 92% | 通过 |
| `apps/qiyu_windows_host` | 无问题 | 28 | 93.59%（219/234） | 91% | 通过 |
| `apps/qiyu_flutter` | 无问题 | 769 | 94.04%（6,356/6,759） | 91% | 通过 |

四包合计 **3,917 项测试**；完整发布脚本随后再次运行四包测试，未将重复执行次数叠加为新增用例。门槛保持当前 CI 水位，没有降低。

## 命令、退出码与证据

以下命令均实际执行。三个 Dart 包分别运行 `dart pub get`、`dart analyze`、`dart test --coverage=coverage --reporter expanded`，随后运行：

```powershell
dart run coverage:format_coverage --lcov --packages=.dart_tool/package_config.json --report-on=lib --in=coverage --out=coverage/lcov.info
dart run ../../scripts/coverage_gate.dart --lcov coverage/lcov.info --min <该包门槛> --label <包名>
```

Flutter 包运行 `flutter pub get`、`flutter analyze`、`flutter test --coverage --reporter expanded`，并以 `dart ../../scripts/coverage_gate.dart --lcov coverage/lcov.info --min 91 --label flutter` 校验。上述最终有效命令退出码均为 **0**。

原始日志在验证 worktree 的 `.scratch/qa08/`，并归档到原仓库本地 tracker 的 `execution/08-artifacts/`。每项 `.exit.json` 记录真实命令、工作目录、UTC 起止时间、起止源码 SHA、退出码与日志位置；不以包装脚本的退出码替代单项结果。

主要日志前缀为 `core-*`、`local-host-*`、`windows-host-*`、`flutter-*`；最终 Flutter 覆盖率使用 `flutter-test-coverage-env-fixed` 与 `flutter-coverage-gate-env-fixed`。完整发布和安卓结果分别为 `release-baseline`、`android-debug`。

### 保留的失败与环境归因

第一次 Flutter 覆盖率命令退出 1，测试尚未开始：远程终端未继承 `PROGRAMFILES(X86)`。紧随其后的覆盖率门禁退出 2，因为没有生成 lcov；这不是产品测试失败或覆盖率不足。仅在验证进程内从 Windows 特殊目录补回环境变量，未修改用户或系统环境设置：

```powershell
[Environment]::SetEnvironmentVariable('PROGRAMFILES(X86)', [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFilesX86), 'Process')
```

补齐后 Flutter 全量测试和覆盖率门禁均退出 0；原失败日志保留。首批 PowerShell 日志中的部分中文存在解码乱码，后续 runner 使用 UTF-8，完整发布日志重新记录了四包全部测试名称。所有数字、退出码和摘要按实际输出核对。

收尾一次文件保护校验误将清单相对路径解析到干净验证 worktree，产生 81 项差异；以 `E:/Agent/Qiyu` 显式解析后重新检查为 **81 项、0 变化**。错误报告保留为 `preexisting-path-resolution-error.json`，有效结果为 `preexisting-final.json`，未据此覆盖或还原任何用户文件。

## Windows、浏览器与 Android

在仓库根实际运行原脚本，未修改或跳过其步骤：

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -File scripts\verify-release-baseline.ps1
```

**退出 0**；运行时间为 2026-09-14 14:16:16–14:19:37 UTC，日志最后为 `Release baseline verification passed without Node/npm`。

| 检查 | 实际结果 |
| --- | --- |
| 发布策略及四包分析/测试 | 通过 |
| 三个真实浏览器侧测试文件 | 共 **19 项通过**，使用测试专用临时浏览器配置，不操作用户浏览器窗口 |
| `flutter build web --wasm --no-web-resources-cdn` | 通过；WASM、JavaScript、Skwasm/CanvasKit 与静态资源检查通过 |
| Windows 包生命周期 | 隔离目录中的安装、升级、卸载安全检查通过；未安装到用户应用目录 |
| Windows Host 编译与 bundle | 通过；候选包校验通过，版本 0.1.0、76 文件、x64 |
| Host 自检和启动冒烟 | 通过；使用独立 runtime/memory 及 `--no-browser`，仅 loopback |
| `flutter build apk --debug` | 退出 **0**；2026-09-14 14:19:37–14:21:45 UTC，未安装到设备 |

三个浏览器文件为 `voice_player_platform_web_test.dart`、`settings_collapse_platform_web_test.dart`、`backup_platform_web_test.dart`，分别验证真实 Web Audio、折叠偏好持久化、Blob 下载接缝。它们不计入上表的四包覆盖率，也不等同于完整应用的人工浏览器验收。

浏览器测试使用 headless 和临时 user-data-dir；本次没有鼠标、键盘、桌面窗口自动化，没有改变网课页面。包生命周期仅使用脚本生成的临时目录和测试专用凭据。产品链路测试为脚本模型、受控传输或本地降级，未使用真实用户记忆、真实 Provider 密钥或付费产品模型。

## F1–F6 的当前集成证据

以下测试均包含在本次同一源码提交的全量运行中；不是拼接 01–07 的历史通过数。路径以仓库为根。

| 发现 | 源码连接与实际验证入口 |
| --- | --- |
| F1 记忆提交边界 | `memory_commit.dart` 区分维护准入、短提交和内容快照。LocalHost 的 `memory_commit_boundary_test.dart` 覆盖旧 Dream、内容恢复后的版本变化、同时间同大小编辑、控制已保存而派生清理未结束、部分写失败、后续恢复；`maintenance_admission_test.dart` 验证真实 Host 的导入/回滚/清除快照包含在途称呼写入，以及聊天禁提与 export 排空无互等。服务集合交错测试和真实 HTTP 维护测试分别提供证据，不将所有场景称作单一端到端测试。 |
| F2 发送与草稿 | `qiyu_composer.dart` 以发送结果和草稿版本判断回填，文字与转写共用收尾。Flutter 的 `local_chat_view_test.dart` 包含“历史已有同文，本轮受理前失败仍恢复原稿”、文字/语音受理后失败保留 requestId、编辑又删空与失效会话不回填；`local_chat_view_model_test.dart` 验证受理重试复用原 requestId；`voice_chat_view_test.dart` 验证转写只提交一次及排队/打断。 |
| F3 HTTP 契约 | LocalHost 的 `model_gateway_native_completion_test.dart`、`model_gateway_transfer_budget_test.dart` 覆盖三种 Provider 原生完成、提前 EOF、错误、取消、建立阶段与静默响应期限、传输预算；同一全量套件还运行 `anysearch_client_test.dart`、`provider_proxy_test.dart` 及 STT/TTS、Volc ASR/TTS 回归。文字请求统一 `post`，二进制响应保持独立入口。 |
| F4 共享禁提 | `memory_ban.dart` 的 `MemoryBanExecution` 先写 controls，再分别清理 loops/persona；`memory_actions.dart` 与聊天服务复用同一实现。`shared_memory_ban_test.dart` 通过真实聊天和记忆中心 HTTP 入口覆盖控制失败、独立/双重清理失败、稳定 ID 与重复请求；维护交错另见 F1。 |
| F5 类型化事件与唯一组装 | Core 的行为契约消费测试验证九类事件合法/非法 wire。Flutter 的 `host_delivery_parser_test.dart` 使用真实 Host 事件；`chat_delivery_flow_test.dart` 将 NDJSON 送入实际 gateway，验证便捷 send 与 ViewModel 的多段结果、逐段一次朗读、缺字段/错误顺序、第二段取消/error/EOF、迟到段和会话切换。源码只有一个 `ChatDeliveryAssembly` 实现，两个消费入口复用它。 |
| F6 安全类别与提示 | `service_error_pipeline_test.dart` 的 13 场景使用受控 Provider HTTP → 真实 ProviderModelGateway → 临时 Host → 实际 Flutter parser/页面，覆盖 401/403、模型404、429、400/422/路由404、500/503、超时/断网/TLS/DNS，断言落盘、299ms/300ms、同会话一次及敏感哨兵不泄漏。`service_error_delivery_test.dart` 覆盖重启重放与语音公开码；`local_chat_view_test.dart` 验证直接去设置、延迟中切会话与旧事件无类别；`voice_chat_view_test.dart` 验证离页停止朗读并清队。 |

### 遗留层检查

固定命令 `git diff 120871ca818433db3bd87a5d34e663988bfb2268...HEAD` 对应 73 个文件、4,908 行新增、1,286 行删除；`git diff --check` 退出 0。

对所有已跟踪 Dart 文件执行下列源码搜索，退出 **1（无匹配）**：

```text
CancellableProviderHttpClient|BoundedProviderHttpClient|postCancellable|postStream|banTitle|latestFallbackDetail|ChatDeliveryEvent\(
```

同时核对了两个 `ChatDeliveryAssembly` 消费入口、UI/聊天的 `MemoryBanExecution` 接线及语音精确错误码分支；没有仅凭符号搜索推断所有语义重复均不存在。搜索命令、退出码和当前调用清单保存在 `legacy-symbol-search.*`、`current-integration-call-sites.txt`。

## 审查状态与残余限制

此前主执行者已完成命令执行、日志核对和上述关键接线的源码检查；只读实施检查子任务曾在认证阶段返回401、退出1，没有完成。本次重新核对21份最终有效门禁元数据，全部退出0且起止源码SHA均为c650a80，并确认之后只有文档变化。未启动新的Claude任务或独立评审，旧认证失败保留为历史。

用户本轮明确要求不再启动双轴评审。第08票依据已核验的同版本自动门禁及F1–F6源码/测试证据完成收口，状态为completed；Standards与Spec记为waived_by_user（未执行），不记作审查通过或0发现。此次仅更新文档，不运行Claude子任务、不重跑测试；先前401保留为历史，不声称本轮验证了新的Claude配置。

当前会话亦无可调用的知识图谱查询工具；上述接线结论来自当前源码、已跟踪文件搜索和实际测试，没有声称做过图谱 coverage/freshness 检查，未操作 `.codebase-memory`。

独立双轴评审不再是第08票的完成条件；既有自动证据与人工/真机未验范围仍分别保留。若后续改变生产代码或测试，仍须在新的源码提交采集相应门禁。

本专题规格、索引及issues目录只定义01–08共八票。用户同时提及的第09票尚未定位到本专题定义；其他专题存在同号工单，未擅自选择、修改或计为完成，待提供其标题或所属专题。

没有执行 Android 真机、Windows 干净 VM、操作系统重启、实体麦克风/扬声器体验或完整页面人工验收。Android debug 构建不代表 release 签名或上架验证；自动发布门禁通过不等于已经发布。

已知旧文档差异保持可见：`docs/adr/0002-tts-post-delivery-synthesis.md:3` 将 message 称作已落盘，但当前 Host 的顺序为 `message → appendTurn → state → done`。本专题与 AGENTS 明确以 done 判完成；此前已报告，本次不擅自修改旧 ADR。Dream 当前最小间隔仍为 3 天，本次没有更改节奏。

## 本地构建产物

以下相对路径均位于 `E:/QiyuQA-0914`，由本次源码提交构建，仅保存在本机，不随验收文档提交或发布：

| 产物 | 字节数 | SHA-256 |
| --- | ---: | --- |
| `apps/qiyu_windows_host/build/qiyu-windows-x64-0.1.0.zip` | 28,876,980 | `D44A961BAD61458BF7B4D5015A56EFE74AD11C006D6F61A4358D639B704B2F56` |
| `apps/qiyu_flutter/build/app/outputs/flutter-apk/app-debug.apk` | 168,616,845 | `336C9C16B1958E60C0BECC36A79F1E9A9C62CF886DC42BCC6739771BBCFCF7E5` |

Windows 解压包位于 `apps/qiyu_windows_host/build/windows-bundle`；Flutter Web 资源位于 `apps/qiyu_flutter/build/web`。完整产物清单及摘要见本地 `artifacts.json`。原工作区 81 个预有图标、设计、页面及配置文件摘要均保持不变；这些未提交改动没有纳入本次提交。
