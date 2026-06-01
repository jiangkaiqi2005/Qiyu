# 栖语 Web 设计系统规范 (Design System)

本文档规范了“栖语” Web 产品的视觉基线与核心 UI 规范。

## 1. 颜色与材质 (Color & Palette)

为了营造深夜安静、温暖且具有陪伴感的神秘夜晚氛围，栖语采用了一套极富质感的 Harmonious Palette：

- **底色 (Night/Night Base)**: `#11100e` (柔和暗黑底色，融合了极弱的棕色调)
- **纸页 (Panel)**: `#1b1916` (84% 饱和度玻璃卡片材质)
- **字色 (Ink/Primary)**: `#efece4` (暖白，不刺眼的象牙色)
- **次要字色 (Muted)**: `#9f998d` (沙岩灰)
- **强调色 (Accent)**: `#d8a94b` (温暖的金黄色，象征夜里的一盏油灯)
- **用户气泡 (User Bubble)**: `#2d2921` (温暖沉稳的深褐金)
- **描边 (Line)**: `#3a3429` (古铜金细丝)

## 2. 经典排版 (Typography)

- **主字体**: `LXGW WenKai` (霞鹜文楷)。这是一款兼具古典与温暖气息的极佳硬笔楷体，极其匹配“栖语”深夜的陪伴质感。
- **备用字体**: `Microsoft YaHei`, `PingFang SC`, `serif`
- **标题级别**: 
  - `h1`: 24px, 强调色, 字间距增加 1px, 带有细微的底边下划线。
  - `subtitle`: 15px, 沙岩灰。

## 3. 页面布局与导航 (App Shell & Navigation)

- **大屏 (Desktop)**: 双栏布局，左侧为 `240px` 宽的高级隐藏侧边栏 (`.app-sidebar`)，右侧为全屏视窗。
- **小屏 (Mobile)**: 顶栏状态条 (`.app-header-bar`) + 底部流线导航栏 (`.app-bottom-nav`)。在小于 `480px` 时，为精简空间隐藏底部导航文字，仅保留加大版图标。
- **无障碍设计 (Accessibility)**:
  - 首要元素设置 `a.skip-link` 以跳过全局侧边导航。
  - 所有按钮与输入框获得焦点时显示 `outline: 2px solid var(--accent); outline-offset: 3px;`。
  - 支持 `prefers-reduced-motion` 媒体查询，开启后瞬间关闭全部过渡与渐显动效。

## 4. 气泡与输入规范 (Chat Elements)

- **栖语说**: 靠左，细微描边，左上侧倒角为 2px，具有流线指向性。
- **我说**: 靠右，暖灰金底，右上侧倒角为 2px。
