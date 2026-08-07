# 全应用 UI / 视觉统一说明

## 原则

- **背景**：主壳与全屏二级页统一使用 `FrostedBackground`（图三 + 模糊 + 深色蒙层），`Scaffold.backgroundColor` 一律 `Colors.transparent`。
- **顶栏**：`AppBar` 必须显式 `backgroundColor: transparent`、`surfaceTintColor: Colors.transparent`、`elevation: 0`，避免 Windows 等平台出现整块黑/灰顶栏。
- **卡片/分组**：不再使用默认实心 `Card` 作主容器；统一用 **`AppGlassStyles.section`** 或 **`AppGlassStyles.listCard`**（`app/app_glass_styles.dart`）：
  - 半透明 `Colors.white.withOpacity(0.06)` + `outline` 细描边 + 圆角 **16**。
- **对话框 / 底栏**：`AlertDialog` 建议 `backgroundColor: colorScheme.surfaceContainerHigh` + `surfaceTintColor: transparent`；底部弹层依赖主题 `bottomSheetTheme`（半透明紫 + 顶圆角 20）。

## 主题入口

- **`app/app_theme.dart`**：`AppTheme.dark` 已统一：
  - `appBarTheme.surfaceTintColor` 透明
  - `cardTheme` 与毛玻璃一致的半透明 + 描边 + 圆角 16（遗留 `Card` 也会更接近整体风格）
  - `dialogTheme` / `bottomSheetTheme` 半透明 + 圆角
  - `inputDecorationTheme` 全局 `filled: true`、`fillColor` 轻微透亮、圆角 12

## 代码用法

```dart
import '../../app/app_glass_styles.dart';

// 块级内容（设置分组、传输区块、表单分区）
AppGlassStyles.section(
  context,
  padding: EdgeInsets.all(16),
  child: Column(...),
);

// 列表项一条（思维/助理/设备列表）
AppGlassStyles.listCard(
  context,
  margin: EdgeInsets.only(bottom: 10),
  child: ListTile(...),
);
```

登录/注册页表单卡片仍可用 **`AuthFormStyles.glassPanel`**（圆角 20，略大更柔和），与上述属于同一视觉系。

## 已替换的主要页面

- 个人中心 / 设置：顶栏透明 + 设置分组用 `AppGlassStyles.section`
- 思维列表、助理列表：列表项用 `listCard`
- 传输页：发送区、传输记录、附近设备、待接收等原 `Card` 已改为 section/listCard
- 思维详情、日程编辑：毛玻璃区块 + 透明顶栏

画布页（`mind_canvas_page`）内仍有大量 `Card` 作悬浮面板，后续可按块逐步换成 `AppGlassStyles.section`，以免一次改动面过大。
