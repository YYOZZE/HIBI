# 账户登录 · 技术说明（供后端对接）

本文档说明希比 HIBI 前端账户模块的流程、数据与接口约定，便于后端实现或联调。

---

## 1. 功能概览

| 功能       | 说明 |
|------------|------|
| **登录**   | 账号（手机号/邮箱）+ 密码，成功后进入主界面并持久化 token 与用户信息 |
| **注册**   | 账号 + 密码 + 确认密码 + 昵称（选填），成功后同登录，直接进入主界面 |
| **退出登录** | 清除本地 token 与用户信息，返回登录页；可选调用服务端退出接口使 token 失效 |
| **更换账户** | 与退出登录一致：清除本地后回到登录页，用户可输入其他账号登录 |

---

## 2. 前端流程简述

1. **启动**：应用启动后**始终进入主壳**，不强制登录。从本地读取 token 等仅用于恢复已登录态；未登录时在个人中心显示「本地账户」，用户**点击头像**再进入登录/注册。
2. **登录/注册**：调用后端接口，拿到 `token` 及用户信息后写入本地，并通知全局状态，根节点重建为主壳。
3. **退出 / 更换账户**：先 **push** 当前账号目录数据到服务端，再 **切换活动目录到 `local`** 并 **重载** 思维/日程/助理（从对应账号子目录读写）。**不删除**其他账号目录，本机可保留多账号离线副本；通过 `hibi_accounts/<userId>/` 与 `hibi_accounts/local/` 隔离，避免串数据。然后清除 token、回到登录页。

前端**不实现**刷新 token（若后端需要，可后续约定 refresh 接口与拦截器）。

---

## 3. 后端接口约定

基础路径由前端配置 `ApiConfig.authApiBaseUrl`（可与智能体等服务同服或独立）。以下为路径与请求/响应约定。

### 3.1 登录

- **路径**：`POST /api/auth/login`
- **请求体**（JSON）：

| 字段               | 类型   | 必填 | 说明         |
|--------------------|--------|------|--------------|
| `phone_or_email`   | string | 是   | 手机号或邮箱 |
| `password`         | string | 是   | 密码         |
| `captcha_challenge_id` | string | 是* | 图形认证一次性挑战 ID（推荐） |
| `lot_number`       | string | 是*  | 图形认证流水号 |
| `captcha_output`   | string | 是*  | 图形认证输出参数 |
| `pass_token`       | string | 是*  | 图形认证通过标识 |
| `gen_time`         | string | 是*  | 图形认证通过时间戳 |

- **成功**：HTTP 200，响应体（JSON）建议包含：

| 字段             | 类型   | 说明                          |
|------------------|--------|-------------------------------|
| `token`          | string | 访问令牌，必填                |
| `user_id`        | string | 用户唯一标识                  |
| `phone_or_email` | string | 与请求一致，用于展示          |
| `nickname`       | string | 可选，展示用昵称              |

前端会解析 `user_id` / `userId`、`phone_or_email` / `phoneOrEmail`、`nickname`，与 `token` 一并持久化。

- **失败**：非 200 或业务错误时，响应体可包含 `message` 或 `error`，前端会提示给用户。

\* 当后端 `/api/auth/captcha_config` 返回 `configured=true` 时必填。

### 3.2 注册

- **路径**：`POST /api/auth/register`
- **请求体**（JSON）：

| 字段               | 类型   | 必填 | 说明           |
|--------------------|--------|------|----------------|
| `invite_code`      | string | 否   | 邀请码（已关闭强制校验，可不传） |
| `phone_or_email`   | string | 是   | 手机号或邮箱   |
| `password`         | string | 是   | 密码           |
| `nickname`         | string | 否   | 昵称，选填     |
| `captcha_challenge_id` | string | 是** | 图形认证一次性挑战 ID（推荐） |
| `lot_number`       | string | 是** | 图形认证流水号 |
| `captcha_output`   | string | 是** | 图形认证输出参数 |
| `pass_token`       | string | 是** | 图形认证通过标识 |
| `gen_time`         | string | 是** | 图形认证通过时间戳 |

\* 当后端 `/api/auth/captcha_config` 返回 `configured=true` 时必填。

- **成功**：HTTP 200，响应体与登录一致（含 `token`、`user_id`、`phone_or_email`、`nickname` 等），前端按登录逻辑写入本地并进入主壳。
- **失败**：非 200 或业务错误时，同上，前端提示 `message` / `error`。

### 3.3 图形认证配置查询

- **路径**：`GET /api/auth/captcha_config`
- **成功**：HTTP 200，响应体：

| 字段         | 类型   | 说明 |
|--------------|--------|------|
| `configured` | bool   | 服务端是否启用图形认证 |
| `app_id`     | string | Alicaptcha appId（前端初始化 SDK 使用） |
| `sdk_url`    | string | 前端加载 `ct4.js` 的地址（可由后端托管） |

### 3.4 图形认证挑战（推荐主流链路）

- **创建挑战**：`POST /api/auth/captcha/challenge`，请求 `{ "platform": "web|android|ios|harmony" }`  
  响应包含：`challenge_id`、`app_id`、`sdk_url`、`expire_in`
- **校验挑战**：`POST /api/auth/captcha/verify`，请求包含  
  `challenge_id` + `lot_number/captcha_output/pass_token/gen_time`  
  成功后返回 `{ "ok": true }`
- **查询状态（调试）**：`GET /api/auth/captcha/challenge_status?challenge_id=...`

### 3.5 用户数据同步（登录后拉取 / 退出前上传）

- **拉取**：`GET /api/sync/pull`，Header `Authorization: Bearer <token>`  
  响应：`mind`、`schedule`、`assistant` 可为 JSON 或 `null`。客户端写入 **当前登录账号专属目录**：`Documents/hibi_accounts/<sanitize(userId)>/` 下同名文件与 `hibi_assistant/`，未登录使用 `hibi_accounts/local/`。旧版根目录单文件会在首次以 local 使用时 **迁移进 local**，避免丢数据。
- **推送**：`POST /api/sync/push`，Body 同上；只打包 **当前活动目录**，退出登录前客户端先 push 再 logout。

详见后端仓库 `AUTH_SYNC_DEPLOY.md`。

### 3.6 退出（可选）

- **路径**：`POST /api/auth/logout`
- **请求头**：`Authorization: Bearer <token>`
- **说明**：前端在「退出登录」「更换账户」时会清除本地 token；若配置了账户后端，会顺带请求本接口，便于服务端使 token 失效。后端可只做 token 拉黑或删除，返回 200 即可；前端不依赖响应体。

---

## 4. 前端实现位置（供联调参考）

| 内容           | 路径 |
|----------------|------|
| 登录/注册/退出接口抽象 | `lib/features/auth/services/auth_api.dart` |
| HTTP 实现（与上述约定一致） | `lib/features/auth/services/http_auth_api.dart` |
| 账户状态与本地持久化 | `lib/features/auth/services/auth_repository.dart` |
| 登录页         | `lib/features/auth/login_page.dart` |
| 注册页         | `lib/features/auth/register_page.dart` |
| 个人中心（退出/更换账户） | `lib/features/profile/profile_page.dart` |
| 账户后端 baseUrl 配置 | `lib/config/api_config.dart`（`authApiBaseUrl`） |

未配置 `authApiBaseUrl` 或设为空时，前端使用**本地 Mock**：任意账号密码可“登录/注册”，仅写本地，无真实校验，便于前端单独开发与演示。

---

## 5. 安全与扩展建议

- 密码建议在后端做强度校验；传输层建议 HTTPS。
- 若需刷新 token，可后续约定 `POST /api/auth/refresh` 及请求/响应格式，前端在请求失败 401 时尝试刷新再重试。
- 如需手机验证码登录、第三方登录等，可在现有登录/注册流程上扩展接口与前端页面。
