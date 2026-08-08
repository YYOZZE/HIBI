# GitHub OAuth Client ID 技术笔记（希比 HIBI）

本文说明：**Client ID 是什么、怎么拿到、如何与 App 配合、构建/发版时怎么注入**。  
配套短文见同目录 [`AUTH_GITHUB.md`](./AUTH_GITHUB.md)；配置常量见 `lib/config/github_oauth_config.dart`。

自 **3.3.8** 起，希比用 **GitHub OAuth Device Flow** 做账号门禁（无自建登录后端），并要求用户已 **Star** 仓库 [`YYOZZE/HIBI`](https://github.com/YYOZZE/HIBI)。

---

## 1. Client ID 是什么

| 概念 | 说明 |
|------|------|
| **OAuth App** | 你在 GitHub「开发者设置」里注册的一个「应用身份」。用户授权时，GitHub 会显示该应用名称。 |
| **Client ID** | 该 OAuth App 的**公开标识**（常见形如 `Ov23li…`）。客户端请求设备码、换取 token 时都要带上它。 |
| **Client Secret** | 该 OAuth App 的**私密密钥**。传统 Web 后端换 token 时使用。 |

希比当前方案：

- 使用 **Device Flow**（设备码登录），**只需要 Client ID**。
- **不要把 Client Secret 写进 Flutter 客户端**（反编译即可泄露；Device Flow 也不需要它）。
- Client ID 本身可视为「半公开」：会出现在安装包字符串里；真正敏感的是用户授权后得到的 **access_token**。

没有配置 Client ID 时：App 无法向 GitHub 声明「我是哪个 OAuth 应用」，登录页会提示未配置，`GitHubOAuthConfig.isConfigured == false`。

---

## 2. 为什么需要它（和 App 的关系）

希比**没有自建账号服务器**。登录链路是：

```
App（带 Client ID）
  → GitHub（验证用户、发 token）
  → App（用 token 查 /user、查是否 Star）
  → 本地持久化 token / 用户信息 → 放行进主界面
```

Client ID 在此链路上的作用：

1. **身份声明**：告诉 GitHub「这是希比的 OAuth App 在发起 Device Flow」。
2. **授权绑定**：用户在浏览器里看到的应用名、授权记录，都挂在这一个 OAuth App 下。
3. **换取 token**：`device/code` 与 `oauth/access_token` 两次请求都必须带同一 `client_id`。
4. **后续 API**：拿到 token 之后，查用户与 Star **不再需要** Client ID，只需要 `Authorization: Bearer <token>`。

---

## 3. 怎么拿到 Client ID（逐步操作）

### 3.0 先别走错入口（重要）

GitHub「开发者设置」里有两种完全不同的东西：

| 类型 | 入口 | 希比 3.3.8 是否要用 |
|------|------|---------------------|
| **OAuth Apps** | Settings → Developer settings → **OAuth Apps** | **要用（推荐）** |
| **GitHub Apps** | Settings → Developer settings → **GitHub Apps** | **不要用**（权限/安装模型不同，且当前客户端按 OAuth + `scope=read:user` 实现） |

若页面标题是 **Register new GitHub App** / **Create GitHub App**（带 Webhook、Repository permissions、Where can this GitHub App be installed 等），说明进错了：

1. 点 **Cancel** 放弃该表单（或稍后删除误建的 GitHub App）。
2. 改走下面的 **OAuth Apps** 流程。

对照：你截图里已填的 `HIBI-2023`、Homepage `https://github.com/YYOZZE/HIBI` 可以原样用到 OAuth App；但 **Callback / Device Flow / Webhook / Permissions / Any account** 那一套是 GitHub App 字段，**不能**按截图直接点 Create 就当 Client ID 给希比用。

---

### 3.1 前置条件

- 使用维护仓库的账号（如 `@YYOZZE`）登录 [github.com](https://github.com)。
- 准备好应用显示名（如 `HIBI-2023`）与主页 `https://github.com/YYOZZE/HIBI`。

---

### 3.2 正确入口：新建 OAuth App

1. 打开（需已登录）：  
   **https://github.com/settings/developers**
2. 顶部/左侧点 **OAuth Apps**（不要点 GitHub Apps）。
3. 点 **New OAuth App**（文案是 *Register a new OAuth application*）。

若地址栏是 `.../settings/apps/new`，那是 GitHub App，请退回上一步。

---

### 3.3 OAuth App 表单怎么填

| 字段 | 填什么 | 说明 |
|------|--------|------|
| **Application name** | `HIBI-2023`（或 `HIBI`） | 用户授权页上显示的名字 |
| **Homepage URL** | `https://github.com/YYOZZE/HIBI` | 应用主页 |
| **Application description** | 可选，如「希比客户端登录」 | 可不填 |
| **Authorization callback URL** | `http://127.0.0.1` | 表单必填；Device Flow **实际不走回调**，填本地地址即可 |

点 **Register application**。

---

### 3.4 创建后：打开 Device Flow 并复制 Client ID

进入该 OAuth App 的详情页：

1. 找到 **Enable Device Flow** → **勾选并 Update / Save**（必开，否则 App 申请设备码会失败）。
2. 页面上方复制 **Client ID**（常见形如 `Ov23li…`）。
3. **Client secrets**：不要生成、不要写入 Flutter、不要提交 git。Device Flow **不需要** Secret。

把 Client ID 交给构建（见 §4），例如：

```bash
flutter run --dart-define=GITHUB_CLIENT_ID=粘贴你的ClientID
```

---

### 3.5 若你已经打开了「GitHub App」表单（对照截图）

按当前希比实现：**建议 Cancel，改创建 OAuth App**。  
若仅作对照，截图里各选项应理解为：

| 截图项 | 你现在的状态 | 希比结论 |
|--------|--------------|----------|
| GitHub App name = `HIBI-2023` | 已填 | 名字可保留到 OAuth App |
| Homepage URL | 已填仓库地址 | 正确，OAuth 同样填这个 |
| Callback URL | 空 | 若误建 GitHub App 可填 `http://127.0.0.1`；正确路径是 OAuth 的 Authorization callback URL |
| Expire user authorization tokens | 勾选 | OAuth Device Flow 一般不管这项；误建时可忽略 |
| Request user authorization during installation | 未勾 | 与希比无关 |
| **Enable Device Flow** | **未勾** | 无论 OAuth / GitHub App，希比都**必须勾选** |
| Webhook Active | 勾选且 URL 空 | **无后端应取消勾选**；希比不收 webhook |
| User / Repo permissions、Subscribe to events | GitHub App 专用 | OAuth App **没有**这套；Star 检查靠用户 token + `read:user` |
| Only on this account @YYOZZE | 已选 | 若误建 GitHub App 且想给所有用户登录，应选 **Any account**；但正确做法仍是改用 OAuth App（任意 GitHub 用户都可授权，无需「安装到账号」） |

**结论：点 Cancel → 去 OAuth Apps → New OAuth App。**

---

### 3.6（可选）修改 / 轮换

- 可随时在 OAuth App 设置里改名称、主页、开关 Device Flow。
- 怀疑滥用：让用户撤销对该 OAuth App 的授权，或删除/重建 OAuth App（需同步更换安装包内 Client ID 并重新发版）。

---

## 4. 和 App 如何配合

### 4.1 配置落点

| 方式 | 做法 | 适用 |
|------|------|------|
| **A. 构建注入（推荐）** | `--dart-define=GITHUB_CLIENT_ID=你的ClientID` | 正式发版、CI、本机 release |
| **B. 源码占位** | 改 `lib/config/github_oauth_config.dart` 的 `defaultClientId` | 本地调试；注意是否提交到公开仓库 |

编译期解析逻辑（摘要）：

```dart
// lib/config/github_oauth_config.dart
static const String defaultClientId = ''; // 或填入调试用 ID

static const String clientId = String.fromEnvironment(
  'GITHUB_CLIENT_ID',
  defaultValue: defaultClientId,
);

static bool get isConfigured => clientId.trim().isNotEmpty;
```

- `String.fromEnvironment` 在 **编译期** 写入常量；改 dart-define 后必须重新 `run` / `build`，热重载无效。
- 未配置时：`GitHubLoginPage` 直接提示，不会发起网络请求。

### 4.2 本机 / 发版命令示例

```bash
# 调试
flutter run --dart-define=GITHUB_CLIENT_ID=Ov23liXXXXXXXX

# Android
flutter build apk --release --dart-define=GITHUB_CLIENT_ID=Ov23liXXXXXXXX

# Windows
flutter build windows --release --dart-define=GITHUB_CLIENT_ID=Ov23liXXXXXXXX
```

打 Inno Setup 安装包前，须先用带 `GITHUB_CLIENT_ID` 的命令完成 `flutter build windows --release`，否则 Setup 内嵌的 exe **没有** Client ID。

PowerShell 示例：

```powershell
$cid = "Ov23liXXXXXXXX"   # 换成你的 Client ID
flutter build apk --release --dart-define=GITHUB_CLIENT_ID=$cid
flutter build windows --release --dart-define=GITHUB_CLIENT_ID=$cid
& "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe" "windows\Hibi2024_setup.iss"
```

### 4.3 运行时完整配合流程

```
┌─────────────┐     client_id      ┌──────────────────────────────┐
│  希比 App    │ ─────────────────► │ GitHub login/device/code     │
│             │ ◄───────────────── │ 返回 device_code / user_code │
└──────┬──────┘                    └──────────────────────────────┘
       │ 展示 user_code，打开浏览器
       ▼
┌──────────────────────────────┐
│ github.com/login/device      │  用户登录 GitHub 并输入 user_code
│ 授权给「HIBI」OAuth App       │
└──────────────┬───────────────┘
               │
┌──────────────▼───────────────┐     client_id + device_code
│ App 轮询 access_token        │ ─────────────────────────────►
│ login/oauth/access_token     │ ◄──── access_token
└──────────────┬───────────────┘
               │
               ├─ GET api.github.com/user          → 登录名 / 头像
               ├─ GET .../user/starred/YYOZZE/HIBI → 204 已 Star / 404 未 Star
               ├─ 未 Star → 引导 Star，点「我已 Star」再查
               └─ 已 Star → AuthRepository 落盘 → MainShell
```

关键请求体中的 Client ID：

| 步骤 | URL | Body 中的 Client ID |
|------|-----|---------------------|
| 申请设备码 | `POST https://github.com/login/device/code` | `client_id` + `scope=read:user` |
| 轮询 token | `POST https://github.com/login/oauth/access_token` | `client_id` + `device_code` + `grant_type=urn:ietf:params:oauth:grant-type:device_code` |

Star 校验（**不带** Client ID）：

```http
GET /user/starred/YYOZZE/HIBI
Authorization: Bearer <access_token>
Accept: application/vnd.github+json
```

- `204` → 已 Star，允许使用  
- `404` → 未 Star，留在门禁页  
- `401/403` → token 无效，需重新登录  

### 4.4 代码协作关系

| 文件 | 与 Client ID 的关系 |
|------|---------------------|
| `lib/config/github_oauth_config.dart` | 编译期读取 / 占位；仓库名、scope、Star URL |
| `lib/features/auth/services/github_oauth_service.dart` | 所有带 `client_id` 的 HTTP；token 安全存储 |
| `lib/features/auth/github_login_page.dart` | UI；未配置时提示；引导 Star |
| `lib/features/auth/services/auth_repository.dart` | `loginWithGitHub`；启动时恢复 token 并复查 Star |
| `lib/app/initial_app_loader.dart` | 门禁：`isGitHub && starred` 才进 `MainShell`；前台恢复时刷新 Star |

Scope 当前为 `read:user`（读公开资料 + 用 token 查 starred）。一般**不需要** `repo` 私有仓库权限。

### 4.5 启动门禁（配合结果）

```
有本地 GitHub 用户 && Star 通过  →  MainShell（正常使用）
否则                             →  GitHubLoginPage（登录 / 去 Star）
```

App 从后台回到前台时，会对已登录用户再次 `refreshGitHubStarStatus()`：若用户取消 Star，会重新拦在登录门禁。

---

## 5. 安全与合规要点

| 项 | 建议 |
|----|------|
| Client Secret | **禁止**进入客户端、git、Release 附件 |
| Client ID | 可进安装包；公开仓库若写入 `defaultClientId`，等于公开该 OAuth App 的 ID（通常可接受） |
| access_token | 优先 `flutter_secure_storage`；登出时清除 |
| 最小权限 | 保持 `read:user`；不要随意加大 scope |
| 用户感知 | 授权页应能看清应用名与仓库主页，避免钓鱼感 |
| 无后端 | token 校验与 Star 检查均在客户端直连 GitHub；不经过希比自建服务器 |

---

## 6. 排障清单

| 现象 | 可能原因 | 处理 |
|------|----------|------|
| 登录页提示未配置 Client ID | 构建未带 `GITHUB_CLIENT_ID`，且 `defaultClientId` 为空 | 按 §4.2 重新构建 |
| 拿到的是 GitHub App 的 Client ID，登录异常 | 建错成 **GitHub Apps** | 改建 **OAuth Apps**，用 OAuth 的 Client ID 重新构建 |
| 获取设备码失败 / 超时 | 未开 Device Flow；Client ID 打错；网络拦 GitHub | OAuth App **必须**打开 Device Flow；检查 ID；确认可访问 github.com；3.3.11 起先开登录页再申请码、环境代理/重试，并提供系统浏览器兜底 |
| 内嵌登录页打不开 / GitHub 提示不支持浏览器 | WebView UA 被拦截或 WebView2 未就绪 | 点「系统浏览器」外开完成授权；Windows 需可用 WebView2 |
| 一直「等待授权」 | 用户未在浏览器确认；码过期 | 重新发起登录；在时限内输入 user_code |
| `access_denied` | 用户点了拒绝 | 重新登录并允许 |
| 已登录但进不去 | 未 Star `YYOZZE/HIBI` | 打开仓库点 Star，再点「我已 Star」 |
| 热重载后仍未配置 | dart-define 仅编译期生效 | 完整重启 / 重新 build |
| 发版安装包仍提示未配置 | ISCC 打的是**未注入** ID 的旧 Release 目录 | 先带 define 的 `flutter build windows`，再 ISCC |

可用浏览器验证 Device Flow 是否对你的 Client ID 开放：能成功 `POST /login/device/code` 即说明 App 侧配置方向正确。

---

## 7. 与「传统账号密码 / 自建后端」对比

| | 希比 GitHub Device Flow | 传统自建后端 OAuth |
|--|-------------------------|-------------------|
| Client ID | 在 App 内 | 常在后端 |
| Client Secret | **不用** | 后端保管 |
| 回调 URL | 形式必填，流程不依赖 | 后端 callback 必需 |
| 账号数据 | GitHub 用户 + 本地 token | 自建 users 表 |
| Star 门禁 | 客户端调 GitHub API | 也可放后端代查 |

设计取舍：用 GitHub 当 IdP + Star 当「许可」，换取**零登录服务器**；代价是发版包必须正确打入 Client ID，且用户需能访问 GitHub。

---

## 8. 维护者检查清单（发版前）

- [ ] GitHub OAuth App 已创建，**Device Flow 已启用**
- [ ] 已复制 Client ID，构建命令带 `--dart-define=GITHUB_CLIENT_ID=...`
- [ ] 本机 `flutter run` 能走完：设备码 → 授权 → Star → 进主界面
- [ ] 未把 Client Secret 写入任何源码或脚本
- [ ] Windows / Android release 均用同一 Client ID 构建后再打包上传

---

## 9. 相关链接

- GitHub 创建 OAuth App：`https://github.com/settings/developers`
- Device Flow 文档：`https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps#device-flow`
- 检查是否 Star：`GET /user/starred/{owner}/{repo}`  
  `https://docs.github.com/en/rest/activity/starring#check-if-a-repository-is-starred-by-the-authenticated-user`
- 本仓库：`https://github.com/YYOZZE/HIBI`
- 短版操作说明：[`AUTH_GITHUB.md`](./AUTH_GITHUB.md)
