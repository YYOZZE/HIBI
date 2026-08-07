# 生成 Setup 安装包（Inno Setup）

## 前提

1. 已安装 **Inno Setup 6**：https://jrsoftware.org/isinfo.php  
2. 已在本项目根目录执行：`flutter build windows`

## 步骤

1. 打开 **Inno Setup Compiler**（或命令行使用 `ISCC.exe`）。
2. 打开脚本：`windows\Hibi2024_setup.iss`。
3. 菜单 **Build → Compile**（或按 Ctrl+F9）。

## 命令行方式

若 Inno Setup 安装在默认路径，在项目根目录执行：

```bat
"C:\Program Files (x86)\Inno Setup 6\ISCC.exe" windows\Hibi2024_setup.iss
```

## 输出

安装包生成在脚本中配置的目录，例如：

`C:\Users\a1306\Desktop\hibi-2024\LVvaovaoZ100B\Hibi2024_Setup_1.2.1.exe`

版本号来自 `Hibi2024_setup.iss` 中的 `#define MyAppVersion "1.2.1"`，与 `pubspec.yaml` 的 version 保持一致（如 1.2.1+4）。
