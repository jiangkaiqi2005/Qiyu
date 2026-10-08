# 侧边栏切换页面时整页动画跳一下

## 现象

点左侧边栏的导航项（历史 / 记忆中心 / 设置，以及回到对话页）时，栖语整个页面的动画都要跳一下：壳与背景的动画像被重放，页面切换本身也带着明显的整页过渡。观感不优雅，需要修掉。

## 已侦察到的结构事实（供起点参考，结论以实测为准）

- `lib/app.dart` 的 `qiyuRoutes()` 共 9 条路由；四条挂壳路由（`/chat`、`/history`、`/memory`、`/settings`）各自在 builder 里新建 `QiyuShell(child: ...)`。侧边栏导航走 `go`（决策日志第五轮 #7），路由一换，整个 `QiyuShell` 的 State 被销毁重建，壳上所有动画随之重放。
- `QiyuShell`（`lib/features/shell/qiyu_shell.dart`）持 `SingleTickerProviderStateMixin` + 抽屉 `AnimationController` + 多处 `AnimatedContainer`。
- `lib/features/chat/local_chat_view.dart` 约 1007 行附近有背景淡入用的 `AnimationController` + `FadeTransition`。
- 路由过渡本身是 GoRouter 默认的 MaterialPage 过渡，也是「整页跳」的一部分。

## 验收判据

1. 在四条挂壳路由之间来回切换，侧边栏、品牌图标、背景、连接状态视觉上保持稳定：不重放、不跳闪。
2. 补回归用例锁住这个稳定（例如壳的 State 跨导航存活、或切换时壳层无可观察的动画重放），反证做过——把修复退回原状，用例当场判红。
3. 导航语义一项不动：侧边栏与抽屉仍是 `go`，聊天页工具条仍是 `push`，页内详情仍是 `openInFront`；壳仍只挂那四条顶层页，详情子页（某一天、某条记忆、诊断、隐私）仍不挂壳、自带页内返回；离页/换页停播（决策日志 #11）不受影响。
4. 若引入或保留任何过渡，遵守 design-system §9：时长取 `qiyuMotion()` / `QiyuMotion` 既有档位，reduced-motion 下一律立即到位；不凭观感自造新档位、新色值、新间距（裸色与裸间距有棘轮用例扫描）。
5. 既有测试全绿：`apps/qiyu_flutter` 下 `flutter analyze` 与 `flutter test`（约 300 条）。`test/accessibility_test.dart` 与 `test/qiyu_shell_test.dart` 直接消费 `qiyuRoutes()` 与 `QiyuShell`，改动结构时这些断言要跟着改得**仍然锁住原行为**（壳挂在哪四条路径上、抽屉品牌槽语义等），不是删掉断言绕过去。

## 范围红线

- 只动这一件事。不顺带重构、不顺带格式化未触碰的文件、不改主题、不改其它页面视觉。
- 修法的方向自己判断并实测验证；「把壳提到路由之上使其 State 跨导航存活、并压掉或收敛壳页之间的路由过渡」是当前结构下最可能成立的方向，但不是命令——若有更小、更能守住现有断言的修法，用它。
