# 聊天服务构造面收窄：记忆依赖族成 module，可空注入收敛为测试旋钮

本 ADR 记录交付服务接口收窄专题（票 10）的决定：`LocalChatService` 的构造参数从 20 个（1 个位置参数 + 19 个命名参数，其中 18 个可空）收窄为 12 个（1 个位置参数 + 11 个命名参数，其中 9 个可空），记忆族九个可空参数中八个收进必填的 `ChatMemoryModule`、一个死参数删除，「memoryControls 与 open-loops 必须同实例」的不变量从注释约定升级为构造期校验，约 20 处静默判空分支随可空性消除而收敛。功能行为零变化：必填化只把「忘注入依赖」的失败模式从「功能静默消失」改为「构造期报错」，正常装配路径的行为与收窄前一致。

## Context & Decision

1. **忘注入从静默消失改为构造期报错。** 收窄前，记忆族九个依赖（episodePipeline、openLoopStore、statePackReader、memoryControls、memoryActions、memoryCadence、memoryRecall、personaTree 与 relationshipLifecycle）都是独立可空参数，省略即静默关闭对应功能：不传 episodePipeline 就没有轮内整理与维护准入提交边界，不传 memoryCadence 就没有交付后节奏与维护排空，不传 memoryRecall 就没有轮内召回。这些静默降级没有诊断、没有报错，装配方漏传一个参数就得到一个「能跑但缺一块记忆」的聊天服务，且只有对功能清单足够熟悉的人才能察觉。收窄后其中八个收进必填的 `ChatMemoryModule`（构造参数 `required this.memory`，module 成员共八个），relationshipLifecycle 见决定 3 删除：忘注入是编译错误，注入了残缺的族是构造期 `ArgumentError`，两类错误都在启动前暴露。

2. **同实例不变量进类型。** 控制存储与开环存储的同实例约定（`MemoryControlsStore` 必须与 `OpenLoopStore.memoryControls` 是同一实例，两条写入链各持一个实例会互相覆盖）原先只活在字段注释里，靠装配方自觉。现在 `ChatMemoryModule` 构造函数用 `identical` 校验这一约束，错配即抛出（`chat_memory_module_test.dart` 覆盖正反两个方向）。开环热层与聊天即时控制两条写入链从此在类型层面不可能接错线。

3. **死参数删除。** `relationshipLifecycle` 自 ticket 20 把删除管线归入 `MemoryActionService` 后在聊天服务里已无任何消费点（删除即时清除关系证据行走 `memoryActions.deleteByScope` 内部持有的同一实例），本次连参数带字段一并删除，module 也不收它——依赖清单只留真实消费者。

4. **降级原因双回退合一。** 禁提执行器的取用原先是一条「late final + 两条回退」的降级链：优先 `memoryActions?.banExecution`，否则在 `openLoopStore != null` 时现场拼一个独立 `MemoryBanExecution`。双回退服务的正是「memoryActions 缺席但 openLoopStore 在场」这个收窄后不再可表示的状态——memoryActions 现在必在，取用收敛为 `memory.memoryActions.banExecution` 单一路径，`MemoryBanExecution` 的构造与既有测试不再受聊天服务内部的回退拼装影响。

5. **保留的可空旋钮清单（测试隔离语义，逐处理由）。** 收窄后 `LocalChatService` 只剩九处可空注入（providerPort、aliasClient、voiceStreamSynthesizer、requestDiagnostics、deliveryPause、recallWindowWait、voiceSessionGrace、clock、diagnosticsSink），全部属于「省略 = 明确的测试隔离形态」或有缺省值的旋钮：
   - `providerPort`（脚本化端口）：省略 = 纯本地规则回复，是行为基准（golden eval 锁定）的隔离形态；「未配置 Provider」的运行时状态由端口自身的 `prepareChatRequest` 返回 null 表达，两者语义不同——端口在场才会装配提示词与消费召回上下文，缺省则整段跳过，不可互相替代。
   - `aliasClient`（脚本化端口）：别名扩展是控制的增强不是门槛（裁定票 03），未配置或失败静默退回无别名，控制照常生效；省略 = 无别名扩展的最小控制路径。
   - `voiceStreamSynthesizer`（功能接缝）：未注入 = 纯文字流式，是与 done 时整段朗读并存的合法形态；语音流式接缝缺席只降级语音侧车，文字链路与数据完整性不受影响。
   - `requestDiagnostics`（诊断汇）：观测组件，null 即不记录；测试用它隔离诊断断言，生产恒注入。
   - `deliveryPause` / `recallWindowWait` / `voiceSessionGrace` / `clock` / `diagnosticsSink`（时序与出口旋钮）：构造初始化器里已收敛到生产缺省（`Future.delayed`、2 秒宽限、墙钟、stderr），可空只活在参数面上，测试注入小值或确定性替身。
   生产装配路径（`local_app_host.dart`）对上述每一项都显式传值，可空性只服务测试与「能力缺席」语义，不再承担「可能被忘注」的生产依赖。

6. **护栏测试保留，落点改为按包配置解析。** `secret_patterns_lockstep_test.dart` 原样保留：它钉死的是两份秘密特征表的 lockstep 红线（core 记忆提升闸门 8 条、host 落盘脱敏表 20 条，两侧有意不同），与构造面收窄无关，删掉等于解除单边改表的保护。其源码落点从「相对包根的硬编码相对路径」（注释自认 dart test 固定在包根目录运行）改为 `Isolate.resolvePackageUriSync` 按包配置解析——两包是路径依赖，解析结果就是仓内真源；仓库根的 contracts 契约 JSON 不在任何包内，从本包根逐级向上定位。落点解析收敛在 `test/support/repo_source_file.dart` 一处，同类的扫源护栏（`local_chat_service_test.dart` 的统一端口收口扫描）一并迁移；断言内容一字不改，从包内任意目录运行测试都不再假失败。

7. **测试构造面机械迁移。** 直构 `LocalChatService` 的五处测试（admission、isolation 夹具与 `local_chat_service_test.dart` 三处）随签名迁移：夹具已持有存储实例的（admission）就地组装 module，需要整族但此前只传部分成员的（isolation、chat_service_test）经 `test/support/chat_memory_test_module.dart` 按组合根同构的接线一次性备齐。迁移前「省略参数=功能关闭」的隔离语义由成员的缺省形态承接：召回编排器不配模型客户端时轮内循环静默跳过、节奏模块未接日终归档时各钩子空转、热层读取器读不到材料时对应块保持原值——既有测试断言零修改，全部测试在迁移后直接通过，无一处「实现修复」。

## Consequences

- 装配错误左移：漏注记忆依赖从「运行时功能静默缺失」变为「编译错误或构造期抛出」，聊天服务构造面从 20 参数 18 可空收敛到 12 参数 9 可空，且 9 个可空全部有明确的旋钮语义。
- 新增记忆类依赖时在 `ChatMemoryModule` 上加成员：所有装配点（组合根与测试夹具）在同一处补齐，编译器逐点点名，不再出现「服务加了字段、装配方不知道」的漂移窗口。
- 节奏、召回、热层在 module 必填后不再有「未注入」分支，其空转语义由成员自身的缺省形态表达（模型客户端未配置、日终归档未接线）；将来若某成员长出真实的「无此能力」生产形态，再评估是否回到可空参数，需另立决定。
- 护栏落点解析依赖路径依赖的包配置：包发布形态或 monorepo 外引用需要真源文件在位，测试对「仓内开发」场景的假设如实收缩。
- 仓库根契约 JSON 的读取点尚有六处沿用各自包根的相对路径：`qiyu_local_host` 侧 `local_chat_service_test.dart`（三处：约 1451、1605、6242 行的契约夹具消费——其中后一处与本票已迁移的扫源护栏共处一文件，同一文件内新旧落点并存的现状如实登记）、`markdown_memory_repository_test.dart`（28 行）、`memory_backup_test.dart`（485 行），以及 `qiyu_behavior_core` 侧 `qiyu_behavior_core_test.dart`（30 行，相对 core 包根向上定位）。范围裁剪决定不变（契约夹具数据加载而非扫源护栏，不属「从任意目录运行不假失败」的验收对象），留待契约测试下一票统一迁移。

## 后续工作

- **同实例类约束的扩展校验（后续票候选，本票不扩）。** `ChatMemoryModule` 目前只在构造期校验 memoryControls ↔ openLoopStore.memoryControls 一对同实例关系；其余成员之间的同源关系尚未校验，错配即绕开同一提交边界：`memoryActions` 内部持有的 memoryControls、openLoopStore、personaTree、episodePipeline 与 module 成员的同一性，`statePackReader` 与 `memoryRecall` 持有的 openLoopStore、`memoryRecall` 持有的 personaTree 与 episodePipeline、`personaTree` 内部持有的 episodePipeline（记录称呼的在线写路径经 `personaTree.episodePipeline.commits` 排队，异实例即绕开同一提交边界）与 module 成员的同一性。生产装配本就传同一批实例，风险只在测试夹具或未来装配点错配时出现；届时在 module 构造期补 `identical` 校验（模式与既有那对一致），另行立项。

## 偏离票面的登记

1. **参数计数勘误。** 票面写「21 个构造参数」，实测 20 个（1 位置 + 19 命名，可空 18），按实测执行；收窄后 12 个（1 位置 + 11 命名，可空 9）。
2. **relationshipLifecycle 改判删除。** 票面把它列在必填 module 的候选族里，代码核实它在聊天服务内零消费（删除管线自 ticket 20 起归 `memoryActions.deleteByScope`），从候选族移出并连参数带字段删除，module 成员八个。
3. **护栏落点范围扩展。** 票面点名 lockstep 测试的两个源码路径；实际同时修了该测试自身的 `../../contracts` 相对路径（不改则「从任意目录运行不再假失败」的验收不成立），并把 `local_chat_service_test.dart` 的统一端口收口扫源护栏一并迁到包配置解析（属票面「扫源码护栏测试保留并修落点」的范畴）。
4. **契约 JSON 读取点范围裁剪。** 上文 Consequences 登记的六处契约夹具读取点不在本票范围，留待契约测试下一票。
5. **尾随空格清理。** `local_chat_service_test.dart` 构造点编辑邻域 1 行的行尾随空格随编辑消失（构造点机械迁移的邻域格式清理，不涉断言）。
