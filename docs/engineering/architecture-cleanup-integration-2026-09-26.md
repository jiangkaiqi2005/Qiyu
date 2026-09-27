# 2026-09-26 修复与架构清理工程集成验收记录

**状态：工程 01–15 票全部收口（票 15 为文档修正与验收刷新）；自动门禁通过，真机冒烟按本工程批次闸门另行安排。**

## 基点与范围

- 全部票的代码终提交：`db64fd6`（补齐备份浏览器用例、清洗盲区用例与字体门禁）。
- 票 15 自身仅改文档与忽略清单，无代码面变化；`packages/` 下唯一改动是两处 doc comment 措辞修正（`hardRulesBlock` 与 `hiddenActionsProtocolBlock` 注释里同一句过期表述——日终归档与 Dream 实走专用 prompt，不注入这两个块；`git diff packages/` 可复核），与本记录同属文档面。
- 本记录取代 2026-09-14 的旧集成验收记录（旧记录属上一轮 code-quality 工程，内容见 Git 历史 `docs/engineering/code-quality-integration-2026-09-14.md`）。
- 下列所有数字均在本工作区采集，源码状态为 `db64fd6` ＋ 票 15 的文档面改动。

## 环境

Windows 11 x64；Flutter 3.44.8、Dart 3.12.2。运行门禁前确认栖语宿主未在运行（`Get-Process` 无 qiyu 相关进程），门禁自身拉起的启动冒烟进程由脚本自收自清。

## 四包分析、测试与覆盖率

四包 `dart analyze` / `flutter analyze` 均 0 issue。测试与覆盖率逐包实际执行，水位由 `scripts/coverage_gate.dart` 校验（Dart 三包 `dart test --coverage` ＋ `coverage:format_coverage` 出 lcov，Flutter 包 `flutter test --coverage`）；覆盖率运行先于发布门禁，两者在同一源码状态：

| 包 | 分析 | 测试 | 实测行覆盖率 | 门槛 | 结果 |
| --- | --- | ---: | ---: | ---: | --- |
| `packages/qiyu_behavior_core` | 0 issue | 1,237 | 93.38%（1170/1253） | 88% | 达标 |
| `packages/qiyu_local_host` | 0 issue | 2,431 | 94.59%（12026/12714） | 92% | 达标 |
| `apps/qiyu_windows_host` | 0 issue | 41 | 91.87%（260/283） | 91% | 达标 |
| `apps/qiyu_flutter` | 0 issue | 967 | 94.27%（7397/7847） | 91% | 达标 |

四包合计 **4,676 项测试**，全绿。水位保持 CI 现行阈值，没有降低。

## 全量发布门禁

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File scripts\verify-release-baseline.ps1
```

**退出码 0**；本机时间 2026-09-27 04:14:34–04:17:34，历时约 3 分钟，日志尾行 `Release baseline verification passed without Node/npm`。

| 检查 | 实际结果 |
| --- | --- |
| 双端版本一致 | 0.1.0（安卓完整版本 0.1.0+1） |
| 发布策略测试、字体子集内容校验 | 通过 |
| 四包分析/测试 | 上表 4,676 项全绿 |
| 浏览器侧用例 | 3 个文件共 **22 项通过**（`voice_player_platform_web_test.dart`、`settings_collapse_platform_web_test.dart`、`backup_platform_web_test.dart`；headless 真实浏览器＋临时 profile，不触碰用户浏览器窗口） |
| Flutter Web 构建（`--wasm --no-web-resources-cdn`） | 通过；随包资源清单检查通过 |
| Windows 包生命周期 | 隔离目录中安装、升级、卸载安全检查通过 |
| Windows bundle | 版本 0.1.0、79 文件、x64；`apps/qiyu_windows_host/build/qiyu-windows-x64-0.1.0.zip` |
| Host 自检与启动冒烟 | 通过（独立 runtime/memory、`--no-browser`、仅 loopback） |

浏览器侧用例不计入上表四包覆盖率。门禁脚本不含安卓构建步骤；安卓 release 构建与真机冒烟由 `docs/engineering/android-release-build.md` 的流程与清单负责。

## 未验证范围

- **安卓真机冒烟**：豆包双向朗读、千问 realtime 朗读、安卓语音（录音与朗读）均未上真机执行。这是本工程发版闸门的剩余项，需按 `docs/engineering/android-release-build.md` 清单以 release 包由本人上机逐项执行。
- Windows 干净虚拟机、真实整机重启、实体麦克风/扬声器体验与完整页面人工验收未执行。
- 门禁通过不等于已发布。
