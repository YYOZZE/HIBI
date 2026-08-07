# 用户注册/登录与用户数据同步 · 后端原理与部署更新说明

本文档说明 `hibi_auth_sync` + `api_only_app` 中新增账户与同步能力，便于后端开发与运维更新。

---

## 1. 功能概览

| 能力 | 说明 |
|------|------|
| **邀请码注册** | 常量 `INVITE_CODE = "tsinghibi2024"`，仅当请求中 `invite_code` 与之完全一致才允许注册。后续可改为环境变量 `HIBI_INVITE_CODE` 或多码表。 |
| **用户库** | SQLite 单文件 `hibi_users.db`（与 `api_only_app.py` 同目录），表：`users`、`sessions`、`user_data`。 |
| **登录态** | 注册/登录成功后返回 `token`（随机 URL-safe 字符串），写入表 `sessions`；请求头 `Authorization: Bearer <token>` 校验用户。Token 默认有效期 30 天（见 `TOKEN_EXPIRE_SECONDS`）。 |
| **数据同步** | 每用户三份 JSON：`mind`（思维节点列表，等同本地 `hibi_mind_nodes.json`）、`schedule`（日程列表）、`assistant`（`{ agents, messages }`）。登录后前端 **pull** 写本地；退出/切换账户前 **push** 上传。 |

---

## 2. 数据库结构（SQLite）

### 2.1 `users`

| 字段 | 类型 | 说明 |
|------|------|------|
| id | TEXT PK | 用户 ID（hex） |
| phone_or_email | TEXT UNIQUE | 登录账号，存小写 |
| password_hash | TEXT | SHA256(salt + password) |
| salt | TEXT | 随机盐 |
| nickname | TEXT | 可空 |
| created_at | REAL | Unix 时间戳 |

### 2.2 `sessions`

| 字段 | 类型 | 说明 |
|------|------|------|
| token | TEXT PK | 即前端持有的 token |
| user_id | TEXT FK | 关联 users.id |
| created_at | REAL | 签发时间，用于过期判断 |

### 2.3 `user_data`

| 字段 | 类型 | 说明 |
|------|------|------|
| user_id | TEXT | 用户 ID |
| data_key | TEXT | `mind` / `schedule` / `assistant` |
| payload | TEXT | JSON 字符串 |
| updated_at | REAL | 更新时间 |

主键 `(user_id, data_key)`，push 时 UPSERT。

---

## 3. HTTP 接口

### 3.1 注册 `POST /api/auth/register`

- Body JSON：`phone_or_email`、`password`、`nickname`（可选）、**`invite_code`**（必填，当前须为 `tsinghibi2024`）。
- 成功 200：`token`、`user_id`、`phone_or_email`、`nickname`。
- 邀请码错误 400：`{"message":"邀请码无效"}`  
- 账号已存在 400：`{"message":"该账号已注册"}`

### 3.2 登录 `POST /api/auth/login`

- Body：`phone_or_email`、`password`
- 成功 200：同注册响应；失败 401

### 3.3 退出 `POST /api/auth/logout`

- Header：`Authorization: Bearer <token>`  
- 删除 session；前端推送同步应在调用 logout **之前**完成（由客户端顺序保证）。

### 3.4 拉取同步 `GET /api/sync/pull`

- Header：`Authorization: Bearer <token>`
- 200：`{ "mind": [...] | null, "schedule": [...] | null, "assistant": { "agents": [...], "messages": { "agentId": [...] } } | null }`  
- 无数据则为 `null`，前端可不覆盖本地。

### 3.5 推送同步 `POST /api/sync/push`

- Header：`Authorization: Bearer <token>`
- Body JSON：可选键 `mind`、`schedule`、`assistant`；值为 **JSON 对象**（服务端再 `json.dumps` 存入 SQLite）。
- 200：`{"ok": true}`

---

## 4. 「删容器丢库」是什么意思？如何避免？

- **含义**：SQLite 文件默认在**容器内部**。执行 `docker rm` 再 `docker run` 新容器时，新容器是空文件系统，**原来的 hibi_users.db 会随旧容器一起消失**，已注册用户与已推送的同步 JSON 都会没掉。
- **做法**：把库放到**宿主机目录**，用卷挂载进容器：
  - 镜像内已设 `HIBI_DATA_DIR=/app/data`，`hibi_auth_sync.py` 会把 `hibi_users.db` 建在 `/app/data/`。
  - 启动时增加：`-v /root/jideshi_hibi_backend/data:/app/data`（路径按你服务器实际目录改）。
  - 以后重建容器只要不删宿主机上的 `data` 目录，用户与数据都在。

项目内 `server_redeploy.sh` 已改为自动 `mkdir -p data` 并带上上述 `-v`。

---

## 5. 部署与更新

### 5.1 依赖

现有 `requirements.txt` 已含 FastAPI/uvicorn，**无需新增依赖**（SQLite 为 Python 标准库）。

### 5.2 首次部署

1. 上传/更新 `api_only_app.py`、`hibi_auth_sync.py`。
2. 启动后首次请求会自动 `init_db()` 创建 `hibi_users.db`。
3. 确保 `PORT` 与 Flutter `authApiBaseUrl` / `assistantApiBaseUrl` 一致（可同源）。

### 5.3 更新已有服务

- 替换上述两个文件后重启进程即可；**未改表结构时**无需迁移。
- 若以后改表结构，需自行写迁移脚本或备份后删库重建（会丢用户与同步数据）。

### 5.4 备份

- 定期备份 `hibi_users.db`（含账号与三份业务 JSON）。
- 大模型相关仍仅依赖 `.env`，与账号库分离。

### 5.5 修改邀请码

- 编辑 `hibi_auth_sync.py` 顶部 `INVITE_CODE`，或改为读取 `os.getenv("HIBI_INVITE_CODE", "tsinghibi2024")` 后重启。

---

## 6. 安全建议（后续可增强）

- 生产环境建议 **HTTPS** + 反向代理。
- 密码现为 SHA256+盐；可升级为 bcrypt/argon2。
- 可对 `push` 做体积限制与校验，防止恶意大包。
- 多设备冲突合并未做，当前策略为 **最后一次 push 覆盖**。

---

## 7. 与 Flutter 的对应关系

登录后拉取不会整文件覆盖本地：思维节点按 id + `updatedAt` 合并；日程按 id 合并（同 id 保留本地）；助理 agents 同 id 保留本地、messages 按条去重拼接。合并后会再 push 一次，把本地阶段产生的数据写回服务端。

| 后端 data_key | 本地文件/目录 |
|---------------|----------------|
| mind | `hibi_mind_nodes.json` |
| schedule | `hibi_schedule_events.json` |
| assistant | `hibi_assistant/assistant_agents.json` + `messages_<agentId>.json` |

前端实现：`lib/features/auth/services/user_sync_service.dart`；登录/注册成功后自动 pull，logout 前自动 push。
