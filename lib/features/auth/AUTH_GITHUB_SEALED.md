# GitHub 登录 / Star 门禁 — 功能封存笔记（V4.0.1）

> **本地账户目录 / 旧数据合并 SOP**：[`本地账户数据结构说明.md`](../../../本地账户数据结构说明.md)

自 **V4.0.1** 起，默认**绕过** GitHub 登录与 Star 门禁：打开 App 即进主壳，助理保持开放。  
相关代码与 UI **未删除**，仅由开关关闭，便于日后复开。

---

## 1. 当前默认行为（V4.0.1）

| 项 | 行为 |
|----|------|
| 启动 | 不展示 `GitHubLoginPage`；无会话则自动 `loginAsLocal()` |
| 主壳 | 直接进入 `MainShell` |
| 助理 | `canUseAssistant == true`（不要求 GitHub / Star） |
| 局域网同步 | **账号一致校验一并暂关**（握手里仍可带 `accountId`，但不因不一致拒绝；连接密码等逻辑保留） |
| GitHub 代码 | 保留（OAuth、WebView、Star API、登录页、导入旧账号等） |

开关位置：

```dart
// lib/config/auth_gate_config.dart
static const bool bypassGitHubLoginGate = true; // V4.0.1 默认
```

改为 `false` 并**完整重新编译**后，恢复下方「封存功能」行为。

---

## 2. 封存功能摘要（3.3.8–3.3.14 曾交付）

### 2.1 目标

- 无自建账号后端：用 **GitHub OAuth Device Flow** 做身份。
- 须 **Star** 仓库 `YYOZZE/HIBI` 才算 GitHub 路径登录成功。
- 支持 **本地账号** 进壳（助理关闭）；GitHub+Star 才开助理。
- 登录后可弹窗导入本机其他账号（local / 旧手机号目录）数据。

### 2.2 状态机（`AppAccessState`）

| 状态 | 条件 | 主壳 | 助理 |
|------|------|------|------|
| `notLoggedIn` | 无 token | 登录页 | — |
| `local` | `loginAsLocal` | ✅ | ❌（绕过关闭时） |
| `githubNeedStar` | GitHub token 且 Star≠204 | ❌ 引导 Star | ❌ |
| `githubOk` | GitHub + Star 204 | ✅ | ✅ |

绕过开启时：`canEnterShell` / `canUseAssistant` 在确保有本地会话后均为 true。

### 2.3 关键文件（勿删）

| 路径 | 作用 |
|------|------|
| `lib/config/auth_gate_config.dart` | **总开关** |
| `lib/config/github_oauth_config.dart` | Client ID、仓库、scope |
| `lib/features/auth/services/github_oauth_service.dart` | Device Flow、poll、Star API、系统浏览器外开 |
| `lib/features/auth/widgets/github_device_webview.dart` | 内嵌 WebView2 授权 |
| `lib/features/auth/github_login_page.dart` | 登录 UI（内嵌 / 系统浏览器 / 本地） |
| `lib/features/auth/services/auth_repository.dart` | 会话、门禁 getter、loginAsLocal / loginWithGitHub |
| `lib/app/initial_app_loader.dart` | `_GitHubAuthGate` |
| `lib/features/lan_sync/services/lan_sync_service.dart` | `accountsMatch`（绕过时恒 true） |
| `lib/features/assistant/assistant_page.dart` | 助理门禁占位 |
| `lib/features/auth/services/local_account_import_service.dart` | 旧账号导入弹窗 |
| `lib/features/auth/AUTH_GITHUB.md` | 短版运维说明 |
| `lib/features/auth/GITHUB_OAUTH_CLIENT_ID.md` | Client ID 详解 |

### 2.4 OAuth 配置要点

- 类型：**OAuth App**（不要建 GitHub App），启用 **Device Flow**。
- Client ID 已写入 `GitHubOAuthConfig.defaultClientId`（可用 `--dart-define=GITHUB_CLIENT_ID=` 覆盖）。
- **不要**把 Client Secret 放进客户端。
- Scope：`read:user`；Star：`GET /user/starred/YYOZZE/HIBI` → 204 / 404。

### 2.5 用户路径（复开后门禁）

1. 点「使用 GitHub 登录」→ 申请 device code → 内嵌 WebView 授权（或「用系统浏览器登录」）。
2. poll 拿到 `access_token` → 检查 Star。
3. 未 Star →「去 Star / 我已 Star」；已 Star → 进主壳，助理开放。
4. 「本地账号进入」→ 进壳，助理关闭（绕过关闭时）。

---

## 3. 如何复现 / 重新启用 GitHub 门禁

### 3.1 改开关

```dart
// lib/config/auth_gate_config.dart
static const bool bypassGitHubLoginGate = false;
```

### 3.2 构建

`String.fromEnvironment` / `const` 开关需**完整重启或 release 重编**，热重载不够：

```bash
flutter run -d windows
# 或
flutter build windows --release
flutter build apk --release
```

### 3.3 本机验证清单

- [ ] 冷启动出现 GitHub 登录页（非直接进主壳）
- [ ] 本地账号可进壳，助理显示需 GitHub
- [ ] 内嵌或系统浏览器完成 Authorize
- [ ] 未 Star 不能进主壳；Star 后可进且助理可用
- [ ] 退出当前账号后回到登录页
- [ ] （可选）本机其他账号数据导入弹窗
- [ ] 局域网：不同账号设备在关闭绕过时应提示「账号不一致」；开启绕过时可凭密码连接

### 3.4 常见坑（曾踩过）

| 现象 | 原因 / 处理 |
|------|-------------|
| 点 Authorize 没反应 | WebView 遮挡 / 二次 loadUrl；见 `github_device_webview.dart` |
| 验证码 not_found | 多轮 requestDeviceCode 码不一致；单次会话同源 |
| 系统浏览器不弹 | Windows `launchUrl` 失败 → `cmd start` / `explorer` 兜底 |
| 登录页按钮重叠 | 连接中勿与主按钮同显；见 3.3.14 |
| 建错 GitHub App | 必须用 **OAuth Apps** + Device Flow |

### 3.5 再关掉门禁

将 `bypassGitHubLoginGate` 改回 `true`，重新编译即可回到 V4.0.1「打开即进」体验。

---

## 4. 版本记录

| 版本 | 说明 |
|------|------|
| 3.3.8–3.3.14 | 落地并迭代 GitHub 登录、Star、本地账号、WebView、导入 |
| **4.0.1** | **封存门禁（开关绕过）**；行为回归打开即进；助理开放；LAN 账号校验暂关 |

---

## 5. 相关短文

- 日常配置：[`AUTH_GITHUB.md`](./AUTH_GITHUB.md)
- Client ID：[`GITHUB_OAUTH_CLIENT_ID.md`](./GITHUB_OAUTH_CLIENT_ID.md)
