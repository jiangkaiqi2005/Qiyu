# Windows Release 1 发布清单

## 自动门禁

- [x] 纯 Dart 行为契约、Flutter Widget、Windows Host 单元与集成测试通过。
- [x] Flutter Web 优先使用本地 Skwasm，并保留本地 dart2js + CanvasKit 回退；字体和静态资源不引用远程 CDN。
- [x] Windows 安装、升级、保留数据卸载与永久删除数据卸载边界通过。
- [x] 候选包清单哈希、x64 架构、许可证、秘密扫描与旧 Node 产物排除通过。
- [x] 候选 exe 可从仓库外工作目录预检并启动真实 Flutter 页面。

## 产品能力

- [x] 未配置 Provider 时离线聊天可用；安全输入在任何 Provider 调用前本地处理。
- [x] OpenAI-compatible、Anthropic、Ollama 的配置、掩码 Key、连接测试和回复测试可用。
- [x] sessions、episodes、热层、PersonaTree、controls、索引、月压缩与 Dream 由 Markdown 主链路承接。
- [x] 历史、记忆中心、编辑/冻结/禁提/删除、敏感单次查看、备份与损坏恢复可用。
- [x] 诊断只显示脱敏类别与结果；普通用户不接触内部动作和提示词。

## Windows 候选验收

- [x] 首次启动、离线聊天、真实 Provider、强退重启、备份恢复和两种卸载策略在隔离数据目录完成。
- [x] 候选运行时 PATH 不含 Node、npm、Flutter 或 Dart。
- [x] Dream 以旧成功时间 + 晚安方式模拟满足七天间隔，并检查正式状态/草稿采用结果。
- [x] Host 只监听 `127.0.0.1`；异常 Host/Origin、缺失 CSRF、伪造会话和旧会话被拒绝。
- [ ] 独立干净 VM、真实整机重启：当前机器条件未执行，不以隔离目录或进程重启冒充。

## 明确不在 Release 1

- iOS、macOS、Linux 适配。
- 账号、远程托管、云同步与多设备合并。
- 旧 localStorage 对话、偏好与记忆迁移。

安卓壳（`apps/qiyu_flutter/android/`）按 ADR 0009 的端内形态属于 Release 1 正式组成：APK 内含行为核心、进程内本机服务与原生编译 UI，签名构建与真机冒烟清单见 `docs/engineering/android-release-build.md`。
