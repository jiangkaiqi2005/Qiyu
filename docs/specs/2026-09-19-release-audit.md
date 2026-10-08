# 栖语发布就绪 + 安全审计报告（2026-09-19，develop @ 2af0248）

## 结论：CONDITIONALLY READY（有条件就绪）

无 P0 发布阻断问题。安全面扎实（会话/CSRF/CSP/脱敏/备份校验全部成立，安全项无 P0/P1），全量门禁与双端发布物构建均通过。但存在 6 项 P1（安全分类变体绕过、两处首启/会话失效的用户困局、文档与发布物矛盾、规范与首见页冲突需裁定、真机冒烟未完成）应在首次交付普通用户前处理。

## 证据基座（全部实际运行，非静态推断）

- `verify-release-baseline.ps1` 全绿：四包 analyze/test（1654+ 项）、真实浏览器用例（语音播放/折叠存储/备份）、Flutter Web WASM 构建与资源核对、Windows 包构建 + 28 项文件哈希验证 + preflight + 真启动冒烟。
- 安卓 release APK 构建签名成功：0.1.0(1)，70MB，SHA-256 指纹 74c1dadc…c52d7。
- 主审亲验：Host 会话模型（256 位 CSPRNG、启动凭据一次性轮换、修改请求强制 Origin+CSRF、Host 头校验、CSP `default-src 'self'`+`frame-ancestors 'none'`）、安卓清单权限最小集与 allowBackup 双规则、版本四包一致、产品代码无 TODO/print/kDebugMode 残留。
- 三批子代理审计：模型输出与提示词安全、数据可靠性、安全剩余面、UX 与文档、性能泄漏、打包首启链路；重大发现均经主审对照源码复验。

## P0 发布阻断问题

无。

## P1 发布前应修复

1. **危机分类可被单字符变体绕过**（安全红线）：`behavior_core.dart:63` 危机正则是字面中文连续串，`sanitizeUserInput` 折叠空白后保留单空格——「不想 活了」「想si」「self-harm」均判 normal 直外呼 Provider，本地热线兜底回复不保证出现。无变体测试。修法：分类前归一化（去空白/全角/常见拼音映射）+ 变体 golden 用例。
2. **会话失效后困在「重试」死循环**：宿主每次启动轮换会话，隔夜旧标签页必 401；RootView 的 onboarding 读取失败先拦整树，落到「本机程序暂时不可用，请稍后重试」+ 重试按钮（`onboarding_view_model.dart:96`），重试永远失败，无「请重新启动栖语」可执行指引（聊天页本身文案是对的，但到不了）。
3. **Windows 启动失败无任何可见错误面**：自检失败 `throw StateError`、兜底仅 `stderr.writeln`（`bin/qiyu_windows_host.dart:27,69`），双击 exe 的用户只看到控制台一闪而过。修法：GUI 错误弹窗（MessageBox）或至少把失败原因写文件并提示。
4. **文档与发布物矛盾**：`README.zh-CN.md:141`「iOS 与 Android 留待后续」、`release-checklist.md:29`「明确不在 Release 1：Android」——安卓端内形态已交付且是发布物之一；README 完全没有安卓安装/使用章节。发布前必须更新（或明确安卓不入本次发布）。
5. **行为规范与首见页冲突（代码与笔记出入，按仓库约定上报待裁定）**：`behavior-spec.md:103`「首次运行不试聊……不提供试聊输入框」、同文档「兜底而非首屏：本地规则回复不作为首屏推荐体验」——实际 `first_meeting_view.dart:78-100` 未配置时主按钮是「先聊聊」直接进聊天。且本地规则引擎仅三分支（到家→「嗯」、累→「咋了」、其余一律「嗯？」，`behavior_core.dart:269-277`，golden 锁定），无 Key 用户全程收到单字循环。需要产品裁定：改按钮主次/改规范/扩充规则库。
6. **真机冒烟未完成**（仓库自身验收标准）：安卓冒烟清单（`android-release-build.md`）未勾选、Windows 真实浏览器全链路与首启观感未验。发布物已可测，差最后一步。

## P2 发布后处理（按主题归组）

**数据可靠性**
- 写入无 fsync：rename 提交后、惰性落盘前断电可产生「新尺寸+旧数据」文件（恢复扫描可部分抢救，最坏丢最后几轮）。
- provider.json 被 BOM/GBK 保存后，下次任意设置保存会整体重建文件、静默丢弃其余段（含 STT/TTS/AnySearch Key）（`provider_config.dart:870,712-721`）。
- 会话 Markdown 带 BOM 时整段被隔离出历史（标记正则行首锚定 vs 其他文件 trimLeft 口径不一，`memory_marker_codec.dart:20`）。
- 「活动窗口 180 天」只有常量与 UI 元数据，无任何清理实现——与 AGENTS.md 记载不符（按约定上报，待裁定口径），实际是会话无限增长。
- 备份导出不含恢复隔离区原件、读不出的文件静默跳过且清单无法区分。
- requestId 幂等只查当前段：跨天重试同消息会在两个段各留一份（日常刷新/重启场景已覆盖）。
- 备份导入/隔离恢复的 rename 无 Windows 共享冲突重试（主写入器有 20×50ms），杀毒占用时报错可重试、不丢数据。

**模型输出质量**
- OpenAI `finish_reason=length/content_filter`、Anthropic `max_tokens` 截断被当完整回复交付（`model_gateway.dart:1301,1374`，输出上限 512 tokens 有现实触发率）。
- `_collectModelCompletion` 流末兜底把「无终止标记的残余缓冲」当完整回复——当前网关出口全部先 yield done/failure，不可达，但不变量靠纪律不靠结构。
- 人格边界/禁语子串匹配误杀：复述用户原话「你说『我想你了』」、否定式「我不能一直在这里陪你」均整条拒绝回退「嗯？」。
- 联网搜索结果（不可信外部内容）无「这是数据不是指令」隔离条文，且记忆控制隐藏动作（memory_ban/delete）执行前不回查用户本轮是否真发起；叠加后恶意摘要可致记忆被静默禁提/删除（有备份可回滚，故 P2）。
- 记忆块（daily_state/long_memory/persona）进 system 段只过脱敏不过结构净化，被污染记忆可携带短指令（60 字上限内）。

**性能与资源（整晚挂机场景）**
- 每条流式 delta 整页重建 + `messages` getter 全量拷贝 + 气泡 Markdown 全量重解析——长会话流式期间成本随消息数线性涨（`local_chat_view_model.dart:126`、`local_chat_view.dart:528,1201`）。
- 每轮聊天 `openSession` 全量扫描解析整个 sessions 目录（`markdown_memory_repository.dart:531`），文件逐年累积后每条消息延迟线性变差；与上一条叠加。
- Host 状态轮询 2 秒周期无页面可见性门控（`host_status_monitor.dart:42`）：安卓整晚息屏仍每 2 秒 2 次 loopback 请求，影响功耗发热。
- 小泄漏/软锁：`VoiceOutputController` 无人调用 dispose（所有权断）；Web 录音 `stop()` 无超时兜底（onstop 丢失即软锁到刷新）；安卓播放 `done` 无兜底 Timer（Web 有）。
- 字体 13.9MB 同文件注册两个 family（可能双份加载）；APK 未 split-per-abi，三 ABI 全打进 70MB。

**打包观感**
- Windows exe 无图标（`.ico` 已设计未接线）、无版本信息、未签名——新机 SmartScreen 蓝警告是普通用户必遇摩擦；正式分发建议至少嵌图标+版本，最好代码签名。
- zip 顶层目录名 `windows-bundle`（非「栖语」）；APK 产物名固定 `app-release.apk` 不带版本；四 pubspec 版本无跨发布物一致性断言。
- 安卓 `main()` 先 await Host 装配再 runApp，装配失败即裸异常白屏（概率低）。
- PWA manifest 仍是 Flutter 模板描述/主题蓝；maskable 图标与普通同图；flutter service worker 在随机端口 origin 上按端口累积注册。
- CLI 参数（--no-browser 等）与浏览器最低版本要求无用户文档。

**UX 细节**
- 设置「保存到本机」成功零反馈；表单校验错误只走 4.4s 渐隐无字段级标记。
- API 错误文案直接给普通用户 HTTP 码（429/401/403/404）与 DNS/TLS 术语。
- 流式半途失败后重试成本高：用户气泡无复制、草稿不回填（acceptedIncomplete 路径）。
- README「按住麦克风」仅安卓成立（桌面是点击开始/再点结束）；README 缺数据位置（%USERPROFILE%\.qiyu）、备份入口、「卸载即丢、跨设备只能手动导出」关键告知；豆包/AnySearch 的 Key「去哪申请」零指引；联网搜索功能未写进 README。
- 记忆动作部分失败长文案走 5 秒渐隐偏紧；「先聊聊」进入后除工具条图标外无配模型再引导；Windows 控制台窗口无「请勿关闭」说明。
- 开发者诊断/清除预览返回本机路径（功能出口非错误出口，口径可收拢）；聊天内禁提部分失败只进 stderr 不进诊断缓冲。

**口径确认项（不计缺陷）**
- 日终归档会把当天危机轮文本（脱敏后）送 Provider 做「理解」——「non-normal 绝不外呼」按回复管线口径成立，全链路口径需确认（现有设计注释称定稿行为）。

## 已验证成立的核心不变量（正面证据摘要）

- 页面永不接触未清洗 token；半途 EOF/超时/原生错误必降级；取消只留可重试用户 turn；requestId 冲突显式报错。
- non-normal 回复管线内绝不外呼（爆炸网关测试钉住）；契约 JSON 与行为逐字同步被测试消费。
- 五个设置 GET 出口均无明文 Key；Key 主存 provider.json（文档化设计，Windows 用户目录 ACL / 安卓私有目录+备份排除）；scope 切换清旧 Key；错误出口全过脱敏允许列表；禁提覆盖全部出口；明文 http 收窄到私有网段 IP；备份导入校验链完整（路径穿越/sha256/回滚）；shelf_static 防穿越；安卓 loopback 数据面全在 256 位会话门后。
- 原子写覆盖全部持久化路径（含 provider.json），恢复扫描纪律完整，备份先快照后写失败回滚。
- 发布 zip 内容干净（无源码/凭据/Node）、哈希清单双向核对、防 CDN、禁止调试产物；安装/升级/卸载生命周期有测试覆盖；安卓 mipmap 自适应图标齐全。
- 订阅/定时器/句柄成对释放清单核对通过（除上列小项）；聊天 NDJSON 断连资源释放；后台任务限次防堆叠。

## 发布前 Checklist

**必办**
- [ ] P1-1 分类器归一化 + 变体 golden 用例，跑完整门禁
- [ ] P1-2 会话失效给出「请重新启动栖语」指引（替换重试死循环）
- [ ] P1-3 Windows 启动失败加 GUI 错误面（或落盘+明确提示）
- [ ] P1-4 README 中英双语补安卓章节、修正「留待后续」；release-checklist 同步
- [ ] P1-5 裁定「先聊聊 vs 不试聊/兜底而非首屏」冲突并同步 behavior-spec 与实现
- [ ] P1-6 安卓真机冒烟清单跑完 + Windows 真实浏览器全链路首启冒烟
- [ ] 把 APK 指纹 74c1dadc…c52d7 记入 `docs/engineering/android-release-build.md` 指纹表
- [ ] 处理工作树中 CLAUDE.md 软链删除（提交或恢复）
- [ ] P1 修复后重跑 `verify-release-baseline.ps1` + 重打 Windows 包与签名 APK

**建议办（快赢，各约半小时内）**
- [ ] provider.json 读取剥 BOM；会话标记正则容忍 BOM（两处各一行级修复）
- [ ] `finish_reason=length/content_filter`、`max_tokens` 判截断降级
- [ ] 设置保存成功轻提示；用户气泡加复制
- [ ] APK `--split-per-abi` 或按需收窄 ABI；APK 产物名带版本
- [ ] exe 嵌入 qiyu.ico + 版本信息（rcedit），zip 顶层目录改名「栖语」
- [ ] README 补：数据位置、备份入口与卸载告知、按住说话仅安卓、豆包/AnySearch Key 申请指引

**发布后跟踪**
- P2 其余各项按主题排期；真机断电/OneDrive/满盘/浏览器整晚挂机四项运行态演练；联网搜索注入与 recall 全选日期的红队样例。
