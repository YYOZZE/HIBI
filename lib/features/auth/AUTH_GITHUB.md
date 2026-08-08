# GitHub 登录与 Star 门禁（无自建后端）

自 **3.3.8** 起，客户端以 **GitHub OAuth Device Flow** 作为账号体系，并要求用户已 **Star** 仓库 [`YYOZZE/HIBI`](https://github.com/YYOZZE/HIBI)。无需自建登录服务器。

自 **3.3.10** 起：登录页在 App **内嵌 WebView** 打开 GitHub 验证页（密码只在 GitHub 网页输入）；失败时回退系统浏览器。HTTP 超时加长，错误提示为中文。

自 **3.3.11** 起：点「使用 GitHub 登录」后**立刻**打开内嵌页到 `https://github.com/login`（用户能看到账号密码框），同时并行申请 Device Flow 设备码；码就绪后再跳转验证页。HTTP 使用环境代理（`HTTPS_PROXY` 等），申请码失败会重试；网络不通时提示检查代理/VPN，并提供「在系统浏览器打开 GitHub」兜底。**不**经第三方加速反代 OAuth（避免 token 泄露）。

> **Client ID 详细技术笔记**（含「勿建 GitHub App」、表单对照、发版注入、排障）：  
> [`GITHUB_OAUTH_CLIENT_ID.md`](./GITHUB_OAUTH_CLIENT_ID.md)

---

## 为何 App 内没有「GitHub 账号密码」输入框？

GitHub **禁止**第三方应用收集用户名/密码（也不安全）。正确方式是：用户在 **github.com** 网页完成登录与授权，App 只拿到 OAuth token。

希比流程对用户的直觉应是：

1. 点「使用 GitHub 登录」
2. 在 App 内嵌页（或系统浏览器）用 GitHub 账号密码登录并授权
3. 回到希比，按提示 Star 仓库后继续使用

---

## 警告：请建 OAuth App，不要建 GitHub App

| 页面标题 | 是否正确 |
|----------|----------|
| **Register a new OAuth application** / **OAuth Apps** | ✅ 正确 |
| **Register new GitHub App** / **Create GitHub App**（含 Webhook、Permissions、Install） | ❌ 取消，换入口 |

直达：**https://github.com/settings/developers** → 选 **OAuth Apps** → **New OAuth App**。

**务必在 OAuth App 详情页勾选 Enable Device Flow 并保存**，否则申请设备码会失败。

---

## 创建 OAuth App（推荐照抄）

1. Application name：`HIBI-2023`（或 `HIBI`）
2. Homepage URL：`https://github.com/YYOZZE/HIBI`
3. Authorization callback URL：`http://127.0.0.1`
4. 点 **Register application**
5. 详情页勾选 **Enable Device Flow** 并保存
6. 复制 **Client ID**（不要创建/使用 Client Secret）

---

## 配置 Client ID

任选其一：

```bash
# 推荐：构建时注入
flutter run --dart-define=GITHUB_CLIENT_ID=Ov23liXXXXXXXX
flutter build apk --release --dart-define=GITHUB_CLIENT_ID=Ov23liXXXXXXXX
flutter build windows --release --dart-define=GITHUB_CLIENT_ID=Ov23liXXXXXXXX
```

自 **3.3.9** 起，仓库内 `lib/config/github_oauth_config.dart` 的 `defaultClientId` **已写入正式 Client ID**，直接 `flutter build` / 安装官方包即可登录。仍可用 `--dart-define=GITHUB_CLIENT_ID=...` 覆盖。

**不要**把 Client Secret 放进客户端。

---

## 流程（3.3.11）

1. 用户点「使用 GitHub 登录」→ **立刻**内嵌 WebView 打开 `https://github.com/login`（可见账号密码框）
2. **并行**向 `https://github.com/login/device/code` 申请 `user_code`（请求体带 `client_id`；失败最多重试 3 次）
3. 设备码就绪后，WebView 跳转验证页（优先 `verification_uri_complete`）；内嵌失败或拦截则外跳系统浏览器
4. 用户在 GitHub 网页登录并授权；App 轮询拿到 `access_token`，调用 `GET /user`
5. 调用 `GET /user/starred/YYOZZE/HIBI`：`204` 已 Star，`404` 未 Star
6. 未 Star → 引导打开仓库 Star，并提供「重新检查」
7. **持久化（不存密码）**：`access_token` 写入 `flutter_secure_storage`，并备份到 SharedPreferences / 会话快照；用户资料与 Star 缓存一并落盘。冷启动自动恢复；有有效 token 且 Star 仍有效 → 直接进主界面。token 401 或用户取消 Star 才再要求授权/补 Star。

网络：单次连接超时约 20s、请求超时约 45s；HttpClient 启用 `findProxyFromEnvironment`（尊重 `HTTPS_PROXY`/`HTTP_PROXY`/`ALL_PROXY`）。失败时展示中文说明（检查代理/VPN），并提供「在系统浏览器打开」与重试。OAuth 端点**不**走第三方 GitHub 加速镜像。

> 升级安装一般**不会**清掉本机登录态。若每次更新都要重新在网页输密码，属于异常（已在 3.3.10 加固双写与恢复）。

### 方案对照（已选型 B）

| 方案 | 说明 | 结论 |
|------|------|------|
| A. Authorization Code + loopback | 需回调/本机监听，配置更重 | 未采用 |
| **B. 内嵌 WebView + Device Flow** | 验证页嵌进 App，外层继续轮询 | **已落地** |
| C. 仅外跳系统浏览器 | 兜底 | 内嵌失败时使用 |

---

## 相关代码

| 文件 | 作用 |
|------|------|
| `lib/config/github_oauth_config.dart` | client_id / 仓库常量 |
| `lib/features/auth/services/github_oauth_service.dart` | Device Flow + Star API + 友好错误 |
| `lib/features/auth/widgets/github_device_webview.dart` | 内嵌 GitHub 验证页 |
| `lib/features/auth/github_login_page.dart` | 登录 / Star 引导 UI |
| `lib/app/initial_app_loader.dart` | 启动门禁 |
| `lib/features/auth/services/auth_repository.dart` | `loginWithGitHub` / 持久化 |
