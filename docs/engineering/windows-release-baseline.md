# Windows Release 1 基线

Ticket 26 结束迁移期。当前产品入口只有 Flutter Web UI、Dart Windows Host 与纯 Dart 行为核心；旧 Node 服务、旧 DOM 页面、旧专用配置及其测试已经退出产品轨道。`contracts/qiyu_behavior_contracts.json` 作为语言无关、运行时无关的行为契约继续保留。

## 首发能力证据矩阵

能力成立需要同时具备生产入口、可观察结果与回归证据；测试数量本身不作为能力证明。

| 能力 | Release 1 承接位置 | 用户或系统可观察结果 | 关键回归证据 |
| --- | --- | --- | --- |
| 聊天与安全 | `QiyuBehaviorCore.reply`、`LocalChatService.deliver`、`POST /api/chat` | 离线回复可用；危机/医疗/法律/金融在 Provider 前本地分流；非法候选降级 | `qiyu_behavior_core_test.dart`、`local_chat_service_test.dart` |
| Provider | `ProviderModelGateway`、`ProviderSettingsService` | OpenAI-compatible、Anthropic、Ollama 的设置、连接测试、流式终止、超时、取消与脱敏错误 | `model_gateway_test.dart`、`provider_settings_service_test.dart` |
| Markdown 记忆 | `MarkdownMemoryRepository`、episode/open-loop/relationship/PersonaTree 服务 | sessions 脱敏追加，episode、热层、controls 与索引落盘并跨重启恢复 | 对应 repository、episode、controls、relationship、persona 合约测试 |
| Dream | `DreamService` 与聊天后的后台任务链 | 只有晚安且距上次成功至少 7 天才重组；草稿通过四关后原子采用，失败保持 pending | `dream_test.dart`、`local_chat_service_test.dart` 的 Dream 接线用例 |
| 历史 | Host history API、Flutter History client/view | 按日查看本机 sessions，刷新和宿主重启后仍能恢复 | `local_data_service_test.dart`、Flutter history tests |
| 设置与凭据 | Provider config repository、Windows Credential Manager adapter、Flutter Settings | 页面只见掩码；替换/忘记 Key；切换 scope 不复用旧 Key | provider config/settings/credential tests 与候选包重启验收 |
| 备份与恢复 | `MemoryBackupService`、backup API、Flutter backup client | 导出 Markdown 快照；导入先预览与校验；可回滚；损坏先隔离再恢复 | `memory_backup_test.dart`、`memory_recovery_test.dart`、候选包备份恢复验收 |
| 诊断 | `DeveloperDiagnosticsService`、设置/隐私/诊断页面 | 普通用户只见可理解状态；开发者模式只见脱敏来源、结果与延迟 | `developer_diagnostics_test.dart`、Flutter settings/accessibility tests |
| 行为契约 | `contracts/qiyu_behavior_contracts.json`、纯 Dart Core | 本地少回应、晚安收束、安全绕过、候选清洗、人格边界和降级结果稳定 | Dart Core 直接读取全部 fixture；发布门禁强制保留该引用 |

## 删除前行为对拍

在基线 `4a5d24f765700451156f58e80a099935f43f87e7` 上，删除前旧门禁通过：旧 JS 测试 158/158、旧 golden 10/10；同一次门禁中 Dart Core 对同一份 `qiyu_behavior_contracts.json` 的 10/10 必要结果全部一致。契约覆盖普通本地回复、晚安、安全绕过 Provider、违禁话术降级、合法模型回复、隐藏结构清洗、召回动作隐藏、控制结构拒绝、人格依赖边界和医疗建议边界。

旧 golden 中依赖 `sessionCount + memories[] + localStorage turns` 的关系推断没有照搬。它们由 Spec 明确替换为 Markdown episodes/relationship/PersonaTree 的日终语义判断与阶段棘轮；这是有意的领域模型升级，不是静默漂移。旧 DOM/PWA、Node 设置文件和 localStorage 历史同样按 Spec 退出，Release 1 不迁移旧 localStorage。

## 当前门禁

从仓库根目录直接运行：

```powershell
& .\scripts\verify-release-baseline.ps1
```

构包可单独运行：

```powershell
& .\scripts\build-windows-bundle.ps1
```

两个入口只调用 PowerShell、Dart 和 Flutter。最终候选包自身只包含编译后的 Windows Host、Flutter Web 资源、人格宪法、安装/卸载脚本和许可证；普通用户机器不需要任何开发 SDK。

## 平台边界

Release 1 只验收 Windows 本机 Web。iOS 与 Android 后续复用 Flutter UI、纯 Dart 行为核心和记忆领域规则，但不属于本基线；本票不实现移动端、云同步、远程托管或旧 localStorage 迁移。
