# 希比 HIBI 样式设计规范

本文档记录 App 的样式设计原理、参数与资源文件结构，便于后续做主题/换肤与视觉统一。

---

## 一、设计原则

- **深紫主色**：与「图三」背景图色系一致，统一紫色系（无蓝），营造沉浸感。
- **毛玻璃背景**：全局使用同一张背景图 + BackdropFilter 模糊 + 深色蒙层，各功能页不重复铺背景，由主壳统一提供。
- **透明 Scaffold**：功能页 `Scaffold.backgroundColor: Colors.transparent`，内容叠在主壳背景之上。
- **圆角统一**：卡片、按钮、输入框、对话框等主要圆角为 **6**，少数组件（如助理输入框）为 20 以区分。
- **高对比文字**：深色背景上使用浅色正文与标题，保证可读性。

---

## 二、全局背景（FrostedBackground）

| 项 | 值 | 说明 |
|----|-----|------|
| 背景图路径 | `xhb-image/3.png` | 整 App 唯一全屏背景图，与主色系一致 |
| 铺满方式 | `BoxFit.cover` | 保持比例铺满，不拉伸变形 |
| 模糊强度 | `blurSigma = 15` | `sigmaX: 15, sigmaY: 15`，约「50 档」毛玻璃感 |
| 蒙层 | `Colors.black.withOpacity(0.25)` | 轻微深色蒙层，统一色调 |
| 实现 | 底层 `Image.asset` + 上层 `BackdropFilter` + `Container(蒙层)` | 见 `lib/app/frosted_background.dart` |

**使用约定**：仅 **MainShell** 使用一层 `FrostedBackground`；思维/日程/助理/传输/我的等页不再单独铺背景，保证视觉一致。

---

## 三、主题色与 ColorScheme（AppTheme）

主题入口：`lib/app/app_theme.dart`，`ThemeData.dark`。

### 3.1 主色与表面色

| 变量/用途 | 色值 | 说明 |
|-----------|------|------|
| 主色 primary | `#1D1155` (`0xFF1D1155`) | 深紫，按钮、选中态、强调 |
| 主色上的文字/图标 onPrimary | `#E8E4F0` (`0xFFE8E4F0`) | 浅色，保证对比 |
| 更深底 surfaceDark | `#120A33` (`0xFF120A33`) | 对话框、深色块 |
| 玻璃表面 surfaceGlass | `0x1A1D1155` | 主色 10% 透明度，卡片、导航栏底 |
| 正文/标题 textPrimary | `#F0EEF5` (`0xFFF0EEF5`) | 高对比浅色 |
| 次要文字 textSecondary | `#D0CCE0` (`0xFFD0CCE0`) | 副标题、说明 |
| 错误色 error | `#E07A5F` (`0xFFE07A5F`) | 错误、删除等 |

### 3.2 ColorScheme 映射（Material 3 dark）

- `primary` / `onPrimary`：主色 / 主色上文字  
- `primaryContainer`：主色 60% 透明  
- `surface`：surfaceDark  
- `onSurface`：textPrimary  
- `surfaceContainerHighest`：主色 50% 透明  
- `onSurfaceVariant`：textSecondary  
- `outline`：主色 60% 透明  

### 3.3 组件主题摘要

- **AppBar**：透明底、无 elevation、标题 19sp/700、图标与标题用 textPrimary。  
- **NavigationBar**：背景 surfaceGlass、高度 64、指示器主色、圆角 6。  
- **Card**：背景 surfaceGlass、elevation 0、圆角 6。  
- **Dialog**：背景 surfaceDark 95% 透明、圆角 6。  
- **InputDecoration**：圆角 6 的 OutlineInputBorder。  
- **Button**：统一圆角 6（Filled/Outlined/Text/Segmented）。  
- **Divider**：主色 35% 透明、厚度 0.5。  
- **加载指示器**：`AppTheme.loadingIndicatorColor` = onSelected（浅色）。

---

## 四、圆角规范

| 圆角值 | 使用场景 |
|--------|----------|
| **6** | 卡片、按钮、输入框边框、对话框、导航栏指示器、白板工具栏、日程月历格子、列表项等 |
| **20** | 助理对话页底部输入栏外框（区分聊天输入） |
| **2** | 日程等部分小组件 |
| **dotSize/2** | 小圆点（如颜色选择器） |

主题内已统一：`BorderRadius.circular(6)`、`RoundedRectangleBorder(borderRadius: BorderRadius.circular(6))`。

---

## 五、模糊 / 毛玻璃参数

| 场景 | sigmaX / sigmaY | 蒙层 | 代码位置 |
|------|------------------|------|----------|
| 全局背景 | 15（FrostedBackground.blurSigma） | black 0.25 | `frosted_background.dart` |
| 底部导航栏 | 12 | black 0.2 | `main_shell.dart` |
| 助理对话输入栏 | 12 | surface 0.5 | `agent_chat_page.dart` _ChatInputBar |
| 白板画布背景 | 15（与 FrostedBackground 一致） | black 0.25 | `mind_canvas_page.dart` |

做主题时若要统一「毛玻璃强度」，可优先统一全局背景的 `blurSigma`，再按需调整导航栏与输入栏。

---

## 六、特殊页面样式参数

### 6.1 白板画布（思维节点）

| 项 | 值 |
|----|-----|
| 画布背景图 | 与全局一致 `xhb-image/3.png`，BoxFit.cover |
| 模糊 | FrostedBackground.blurSigma（15），蒙层 black 0.25 |
| Scaffold 回退色 | `0xFF1a1a2e`（无图时） |
| 方块背景 | `Color(0xFF2a2a3e).withOpacity(0.88)` |
| 连线颜色 | 白色约 95% 不透明度 |
| 网格点 | outline 0.26，拖拽高亮 primary 0.32 |

### 6.2 助理对话

| 项 | 值 |
|----|-----|
| 输入栏容器 | BackdropFilter 12 + surface 0.5，圆角 20 |
| 输入框 fillColor | surfaceContainerHighest 0.4 |
| 用户气泡 | primary 0.9 |
| 助手气泡 | surfaceContainerHighest 0.6，边框 outline 0.2 |
| 助手头像 | primary 0.6 |

### 6.3 加载页

- 全屏透明 Scaffold + FrostedBackground + 中央 48×48 CircularProgressIndicator。  
- 指示器颜色：`AppTheme.loadingIndicatorColor`，线宽 3。

---

## 七、资源文件与命名结构

### 7.1 资源目录结构（pubspec.yaml）

```yaml
flutter:
  assets:
    - xhb-image/3.png      # 全局背景图（主）
    - xhb-image/1_1.png   # 其他用途
    - assets/images/      # 通用图片目录（可放白板备用图等）
```

### 7.2 关键资源路径

| 路径 | 用途 |
|------|------|
| `xhb-image/3.png` | 主壳与白板画布全屏背景、加载页背景；预加载见 `initial_app_loader.dart`、进入白板前 `mind_page.dart` |
| `assets/images/` | 通用图片；当前主题下白板与主壳均使用 3.png，此处可放备用或未来主题图 |

### 7.3 样式相关代码文件

| 文件 | 职责 |
|------|------|
| `lib/app/app_theme.dart` | 主题色、ColorScheme、AppBar/Card/Dialog/Button 等主题 |
| `lib/app/frosted_background.dart` | 全局毛玻璃背景组件与 blurSigma 常量 |
| `lib/app/main_shell.dart` | 主壳布局、底部导航栏模糊与蒙层 |
| `lib/app/loading_page.dart` | 加载页布局与指示器样式 |
| `lib/features/mind/mind_canvas_page.dart` | 白板画布背景与画布内组件样式 |
| `lib/features/assistant/agent_chat_page.dart` | 对话页输入栏与气泡样式 |

---

## 八、后续主题设计建议

1. **换背景图**：替换 `xhb-image/3.png` 或增加主题分支在 FrostedBackground 内按主题选图。  
2. **换主色**：在 `AppTheme` 中替换 `_mainPurple` 及由它派生的 ColorScheme 与 surfaceGlass。  
3. **统一模糊**：修改 `FrostedBackground.blurSigma` 即可带动白板与文档约定；导航栏/输入栏需单独改 sigma 与蒙层。  
4. **亮色主题**：可新增 `AppTheme.light`，并切换 `brightness`、主色与文字色，背景图与蒙层需重新调参以保证对比度。  
5. **圆角**：当前以 6 为主，若做「圆角主题」可抽成常量（如 `AppRadius.card = 6`）在主题与组件中引用。

---

*文档版本与项目一致，随主题迭代可增补「主题枚举」与「换肤入口」等小节。*
