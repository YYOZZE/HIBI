# GitHub 登录与 Star 门禁（无自建后端）

自 **3.3.8** 起，客户端以 **GitHub OAuth Device Flow** 作为账号体系，并要求用户已 **Star** 仓库 [`YYOZZE/HIBI`](https://github.com/YYOZZE/HIBI)。无需自建登录服务器。

> **Client ID 详细技术笔记**（含「勿建 GitHub App」、表单对照、发版注入、排障）：  
> [`GITHUB_OAUTH_CLIENT_ID.md`](./GITHUB_OAUTH_CLIENT_ID.md)

---

## 警告：请建 OAuth App，不要建 GitHub App

| 页面标题 | 是否正确 |
|----------|----------|
| **Register a new OAuth application** / **OAuth Apps** | ✅ 正确 |
| **Register new GitHub App** / **Create GitHub App**（含 Webhook、Permissions、Install） | ❌ 取消，换入口 |

直达：**https://github.com/settings/developers** → 选 **OAuth Apps** → **New OAuth App**。

---

## 创建 OAuth App（推荐照抄）

1. Application name：`HIBI-2023`（或 `HIBI`）
2. Homepage URL：`https://github.com/YYOZZE/HIBI`
3. Authorization callback URL：`http://127.0.0.1`
4. 点 **Register application**
5. 详情页勾选 **Enable Device Flow** 并保存
6. 复制 **Client ID**（不要创建/使用 Client Secret）

若你已在 GitHub App 表单里填了名字和主页：点 **Cancel**，把同样信息填到上面的 OAuth App 即可。Webhook、Expire tokens、Only on this account 等均为 GitHub App 项，希比当前实现不使用。

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

## 流程

1. App 向 `https://github.com/login/device/code` 申请 `user_code`（请求体带 `client_id`）
2. 用户在浏览器打开验证页并输入代码
3. App 轮询拿到 `access_token`，调用 `GET /user`
4. 调用 `GET /user/starred/YYOZZE/HIBI`：`204` 已 Star，`404` 未 Star
5. 未 Star → 引导打开仓库 Star，并提供「重新检查」
6. Token 优先写入 `flutter_secure_storage`，并同步一份到 SharedPreferences 以便恢复

---

## 相关代码

| 文件 | 作用 |
|------|------|
| `lib/config/github_oauth_config.dart` | client_id / 仓库常量 |
| `lib/features/auth/services/github_oauth_service.dart` | Device Flow + Star API |
| `lib/features/auth/github_login_page.dart` | 登录 / Star 引导 UI |
| `lib/app/initial_app_loader.dart` | 启动门禁 |
| `lib/features/auth/services/auth_repository.dart` | `loginWithGitHub` / 持久化 |
