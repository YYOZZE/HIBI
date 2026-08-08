# GitHub 登录与 Star 门禁（无自建后端）

自 **3.3.8** 起，客户端以 **GitHub OAuth Device Flow** 作为账号体系，并要求用户已 **Star** 仓库 [`YYOZZE/HIBI`](https://github.com/YYOZZE/HIBI)。无需自建登录服务器。

## 创建 OAuth App

1. 打开 GitHub → **Settings** → **Developer settings** → **OAuth Apps** → **New OAuth App**
2. 填写：
   - **Application name**：如 `HIBI`
   - **Homepage URL**：`https://github.com/YYOZZE/HIBI`
   - **Authorization callback URL**：`http://127.0.0.1`（Device Flow 不依赖回调，任意合法 URL 即可）
3. 若有 **Enable Device Flow** 开关，请打开
4. 复制 **Client ID**（**不要**把 Client Secret 放进客户端）

## 配置 Client ID

任选其一：

```bash
# 推荐：构建时注入
flutter run --dart-define=GITHUB_CLIENT_ID=Ov23liXXXXXXXX
flutter build apk --release --dart-define=GITHUB_CLIENT_ID=Ov23liXXXXXXXX
flutter build windows --release --dart-define=GITHUB_CLIENT_ID=Ov23liXXXXXXXX
```

或编辑 `lib/config/github_oauth_config.dart` 中的 `defaultClientId`（仅本地调试；勿提交真实密钥类信息，Client ID 本身可公开）。

## 流程

1. App 向 `https://github.com/login/device/code` 申请 `user_code`
2. 用户在浏览器打开验证页并输入代码
3. App 轮询拿到 `access_token`，调用 `GET /user`
4. 调用 `GET /user/starred/YYOZZE/HIBI`：`204` 已 Star，`404` 未 Star
5. 未 Star → 引导打开仓库 Star，并提供「重新检查」
6. Token 优先写入 `flutter_secure_storage`，并同步一份到 SharedPreferences 以便恢复

## 相关代码

| 文件 | 作用 |
|------|------|
| `lib/config/github_oauth_config.dart` | client_id / 仓库常量 |
| `lib/features/auth/services/github_oauth_service.dart` | Device Flow + Star API |
| `lib/features/auth/github_login_page.dart` | 登录 / Star 引导 UI |
| `lib/app/initial_app_loader.dart` | 启动门禁 |
| `lib/features/auth/services/auth_repository.dart` | `loginWithGitHub` / 持久化 |
