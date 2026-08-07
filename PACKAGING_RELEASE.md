# 希比 HIBI · 打包与发布说明

本文档说明 **jideshi_hibi**（Flutter）在 **iOS（iPhone / iPad / Mac）**、**Android**、**Windows**、**Linux** 上的构建、签名与发布要点。发布前请同步检查 `lib/config/api_config.dart` 等是否指向生产后端。

---

## 一、通用准备

### 1.1 环境与仓库

| 项 | 说明 |
|----|------|
| Flutter SDK | 建议与 `pubspec.yaml` 中 `sdk: ^3.5.4` 匹配的稳定版通道 |
| 依赖 | `flutter pub get`；国内网络见根目录 `setup_pub_mirror_once.ps1` |
| 版本号 | `pubspec.yaml` 的 `version: x.y.z+build`：`x.y.z` 为对用户展示版本，`build` 为 Android versionCode / iOS CFBundleVersion 等 |

### 1.2 正式发布前检查

- [ ] `api_config.dart` 中 `assistantApiBaseUrl`、`authApiBaseUrl` 等为**生产 HTTPS 地址**（勿带调试端口或未加密 HTTP，上架常被拒或限流）。
- [ ] 后端已部署且 CORS/HTTPS 正常（见 `backend_jideshi_hibi_app/AUTH_SYNC_DEPLOY.md`）。
- [ ] `flutter analyze` 无阻塞错误；建议在真机各平台 smoke test（登录、助理、传输、思维画布）。

### 1.3 统一构建命令形态

```bash
# 清理后构建（可选，遇奇怪缓存问题时使用）
flutter clean && flutter pub get

# 指定版本（覆盖 pubspec 中的 version）
flutter build <target> --build-name=1.0.1 --build-number=42
```

---

## 二、Android

### 2.1 输出物

| 类型 | 命令 | 用途 |
|------|------|------|
| APK | `flutter build apk --release` | 内测分发、非商店渠道 |
| App Bundle | `flutter build appbundle --release` | **Google Play 上架**必填 AAB |

产物路径示例：

- APK：`build/app/outputs/flutter-apk/app-release.apk`
- AAB：`build/app/outputs/bundle/release/app-release.aab`

### 2.2 签名（Release）

1. 生成或使用已有 keystore（勿提交仓库）。
2. 配置 `android/key.properties`（勿提交），在 `android/app/build.gradle` 中引用 `signingConfigs.release`。
3. 首次 Play 上架需确定 **包名** `applicationId`（`android/app/build.gradle`），后续不可随意更改。

### 2.3 权限与特性

- 传输、网络、存储等权限已在 `AndroidManifest.xml` 中声明；若加新敏感权限，上架说明需同步更新。
- 局域网发现使用 UDP，部分_ROM 需用户授予「本地网络」或关闭省电限制。

### 2.4 上架

- Google Play Console 上传 AAB，填写资料、隐私政策链接、数据安全表单等。
- 国内商店（华为/小米/OV 等）通常也要 release 签名 APK 或各自要求的格式，按各商店文档操作。

---

## 三、iOS（iPhone / iPad / Mac）

> **说明**：Flutter 构建 iOS 产物**必须在 macOS + Xcode** 下完成；Windows/Linux 无法直接出 ipa。

### 3.1 支持目标

- **iPhone**：常规手机布局；已做底部导航与键盘避让。
- **iPad**：同一套 UI 自适应；若需分屏/多窗口可在 Xcode 中开启相应 capability。
- **Mac（macOS）**：若工程已启用 macOS 桌面目标，可用 `flutter build macos`；App Store 的 Mac 应用与 iOS 是**不同产品**，需单独建档与截图。

### 3.2 构建步骤（Release）

```bash
cd <项目根>
flutter build ios --release --no-codesign   # 仅生成未签名产物，供 Xcode Archive
# 或直接在 Xcode 中：打开 ios/Runner.xcworkspace → Product → Archive
```

签名与上架：

1. Apple Developer 创建 **App ID**、**Distribution 证书**、**Provisioning Profile**（App Store / Ad Hoc）。
2. Xcode 中选择 **Team**、**Generic iOS Device** 或真机 → **Archive** → **Distribute App**。
3. **TestFlight**：上传后内测；**App Store**：提交审核。

### 3.3 版本与兼容性

- `ios/Runner/Info.plist` 中 `CFBundleShortVersionString` / `CFBundleVersion` 由 Flutter 根据 `pubspec.yaml` 写入，保持与 Android 语义一致可减少沟通成本。
- 最低系统版本在 Xcode 工程 **Deployment Target** 中设置；提高最低版可减少旧系统兼容成本。

### 3.4 上架注意

- 若使用相机/相册/网络/本地网络，须在 App Store Connect **隐私**中逐项申报。
- 登录/账号体系若采集个人信息，需隐私政策 URL。

---

## 四、Windows

### 4.1 构建 Release 目录

```bash
cd <项目根>
flutter build windows --release
```

产物目录：`build/windows/x64/runner/Release/`

| 内容 | 说明 |
|------|------|
| `jideshi_hibi.exe` | 主程序（`windows/CMakeLists.txt` 中 `BINARY_NAME`） |
| 同目录 dll | `flutter_windows.dll`、各插件 dll，必须与 exe 同目录 |
| `data/` | Flutter 资源，整目录不可缺 |

绿色分发：将 **整个 Release 文件夹** 打成 zip 分发即可。

### 4.2 安装包（Inno Setup）— 当前用法（2025-03 定稿）

使用 **Inno Setup 6** 打成 **单一 exe**，输出到交付目录，便于双击安装到 `Program Files` 并写入卸载信息。

| 项 | 说明 |
|----|------|
| **打包工具** | [Inno Setup 6](https://jrsoftware.org/isinfo.php)；`winget install JRSoftware.InnoSetup` |
| **ISCC** | `%LOCALAPPDATA%\Programs\Inno Setup 6\ISCC.exe` |
| **脚本** | 交付：`C:\Users\a1306\Desktop\hibi-2024\LVvaovaoZ100B\Hibi2024_setup.iss`；仓库备份：`windows/Hibi2024_setup.iss` |
| **输出** | `Hibi2024_Setup_<MyAppVersion>.exe`（与 `#define MyAppVersion` 一致） |
| **快捷方式** | 中文 UI → `希比-2024`；非中文 UI → `HIBI-2024`（`[Code]` 用 `GetUserDefaultUILanguage` 判定，`[Icons]` 带 `Check`） |
| **`SetupIconFile`** | 指向仓库内 `windows\runner\resources\app_icon.ico`，**仅在 ISCC 编译时**由 Inno 嵌入；换 logo 后需重新 `flutter build windows`（或先用 Pillow/`flutter_launcher_icons` 更新该 ico）再 ISCC。 |
| **交付说明** | 同目录 `README_安装包说明.txt`（UTF-8 BOM）：安装步骤 + **禁止后处理** 提醒。 |

**推荐一键（仅此，不要对 Setup.exe 做任何后处理）：**

```powershell
powershell -ExecutionPolicy Bypass -File c:\ALI_Z14\.TSING_important\Tsingcoop_products\pd\jideshi_hibi\tools\build_windows_installer.ps1
```

等价手动：

```powershell
cd c:\ALI_Z14\.TSING_important\Tsingcoop_products\pd\jideshi_hibi
flutter build windows --release
& "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe" "C:\Users\a1306\Desktop\hibi-2024\LVvaovaoZ100B\Hibi2024_setup.iss"
```

**脚本内需按需修改**：`#define SourceDir`（Release 路径）、`#define MyAppVersion`（与 `pubspec.yaml` 对齐）。`ArchitecturesInstallIn64BitMode=x64compatible` 避免 Inno 6.7+ 对 `x64` 的弃用警告。

---

#### 为何禁止 Resource Hacker / rcedit 改 Setup.exe？

Inno **单文件**安装包 = **PE 段 + 尾部追加的压缩安装数据**（大块数据接在同一个 `.exe` 后面）。  
用 Resource Hacker、rcedit、`UpdateResource` 等工具改图标/资源时，往往**只回写 PE 部分**，**尾部数据被截断**，exe 体积会从约 **20MB 级** 掉到 **1MB 级**，运行即报错：

> **The setup files are corrupted. Please obtain a new copy of the program.**

这与 PyInstaller onefile 被改资源后只剩 bootloader、归档丢失是同一类现象（工具不认 append 在 PE 后的数据）。  
**结论**：编完安装包后**不得**再改 `Hibi2024_Setup_*.exe`。若资源管理器里仍是地球标，可接受，或改发 **zip 绿色包** / **MSIX** 等不把大数据 append 进同一 exe 的方案。

**已废弃**：曾用 Resource Hacker 覆盖 `ICONGROUP,0,` 换文件图标，会导致上述损坏；`tools/patch_setup_icon.ps1` 已删除，请勿恢复。

---

**ISCC 报 *The system cannot find the file specified***：多为 `.iss` 路径不存在或 `#define SourceDir` / `#define AppIcon` 指向了不存在的路径；可从仓库拷贝 `windows/Hibi2024_setup.iss` 到交付目录并改正路径后重编。

### 4.3 其他分发方式

| 方式 | 说明 |
|------|------|
| Zip 绿色包 | 仅打包 `Release` 目录；无安装向导 |
| MSIX | 需证书签名，适合企业/商店 |
| 微软商店 | 需 MSIX + 开发者账号 |

### 4.4 传输功能

- Windows 防火墙可能拦截 UDP 62637–62639；应用内已有防火墙脚本与说明（`TRANSFER_DISCOVERY_NOTES.md`）。发布说明中可提示用户放行或「通过 IP 发送」兜底。

---

## 五、Linux

### 5.1 环境依赖

构建机需安装 GTK 等开发库（依发行版而定），例如 Ubuntu：

```bash
sudo apt-get install clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev
```

### 5.2 构建

```bash
flutter build linux --release
```

产物目录：`build/linux/x64/release/bundle/`

- 可执行文件在 `bundle/` 下，连同 `lib/`、`data/` 一起打包分发。
- 不同发行版 glibc 版本可能不兼容，尽量在**较老 LTS** 上构建以提高兼容性，或使用容器固定环境。

### 5.3 分发

- **tar.gz**：用户解压后运行可执行文件；可附带 `.desktop` 与图标做菜单集成。
- **Snap / Flatpak / deb / rpm**：按团队维护成本选择一种即可。

---

## 六、发布检查清单（简表）

| 平台 | 构建命令 | 签名/证书 | 商店/分发 |
|------|----------|-----------|-----------|
| Android | `flutter build appbundle --release` | Keystore + key.properties | Play / 国内应用市场 |
| iOS | Xcode Archive | Apple Distribution | TestFlight / App Store |
| Windows | `tools/build_windows_installer.ps1` 或 build + ISCC（见 4.2） | 可选签名 | **Hibi2024_Setup_*.exe**（勿后改 exe）或 Zip |
| Linux | `flutter build linux --release` | 可选 | tar.gz / 包管理器 |

---

## 七、相关文档

| 文档 | 内容 |
|------|------|
| [README.md](README.md) | 项目总览、结构、问题时间线 |
| [安卓真机调试.md](安卓真机调试.md) | USB/无线调试 |
| [backend_jideshi_hibi_app/AUTH_SYNC_DEPLOY.md](backend_jideshi_hibi_app/AUTH_SYNC_DEPLOY.md) | 后端 HTTPS、Docker 卷 |
| [lib/features/transfer/TRANSFER_DISCOVERY_NOTES.md](lib/features/transfer/TRANSFER_DISCOVERY_NOTES.md) | Windows 防火墙与端口 |
| `tools/build_windows_installer.ps1` | Windows 安装包一键编出（无 Resource Hacker/rcedit） |
| 交付目录 `README_安装包说明.txt` | 本地路径 `...\LVvaovaoZ100B\`，与 4.2 禁止后处理一致 |

---

## 八、版本与记录建议

每次对外发版建议在本文件或 CHANGELOG 中追加一行：

- 日期、版本号、平台、构建命令、签名/上架结果、已知问题（如某 ROM 传输发现失败）。

便于后续审计与回归。
