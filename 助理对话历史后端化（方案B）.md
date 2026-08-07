# 助理对话历史后端化（方案 B）说明

本文记录：在“已登录用户”场景下，把智能体对话历史升级为 **服务端权威存储**（会话/消息表 + 分页拉取），客户端仅做缓存与展示，从而避免“本地合并覆盖导致历史丢失/只剩一条”的问题，并为后续分页、搜索、多端一致打基础。

---

## 1. 目标与原则

- **目标**：同一个账号、同一个智能体（agent）下的每轮对话，均以服务端为准保存；App 进入聊天页可直接拉取真实历史。
- **原则**：
  - **分页**：不一次性拉全量，避免数据包无限增长。
  - **幂等**：客户端上报 `client_msg_id`（可选），服务端按会话去重，避免重发重复入库。
  - **鉴权隔离**：所有会话/消息查询严格按当前登录用户 `user_id` 过滤。
  - **客户端缓存**：仍可写入本地 `AssistantRepository`，用于离线展示与减少首屏等待，但最终以服务端为准。

---

## 2. 后端实现（FastAPI + SQLite）

### 2.1 数据表

在 `hibi_users.db`（同 `hibi_auth_sync.DB_PATH`）新增两张表：

- **`assistant_conversations`**：会话表
  - `id`（`conv_...`）
  - `user_id`
  - `agent_id`
  - `title`
  - `created_at` / `updated_at` / `last_message_at`
  - `UNIQUE(user_id, agent_id)`：同账号同 agent 复用同一会话（可后续扩展为多会话）

- **`assistant_messages`**：消息表
  - `id`（自增）
  - `conversation_id`
  - `user_id`
  - `agent_id`
  - `role`（`user|assistant|system`）
  - `content`
  - `created_at`
  - `client_msg_id`（可选，用于幂等去重）

对应初始化逻辑在 `backend_jideshi_hibi_app/api_only_app.py`：
- `_init_assistant_chat_db()`

### 2.2 接口

#### 1）获取/创建会话

- **GET** `\`/api/assistant/conversation\``
- **Query**：`agent_id`（必填）、`title`（可选）
- **Auth**：`Authorization: Bearer <token>`
- **返回**：

```json
{ "conversation_id": "conv_xxxxxxxxxxxxxxxx" }
```

> **兼容旧历史（迁移）**：接口内部会检查该会话在新表中是否已有消息；若为空，则尝试从旧同步包 `user_data['assistant']` 中将该 `agent_id` 的历史消息导入 `assistant_messages`，保证“聊天页打开即见历史”。

#### 2）分页拉取消息

- **GET** `\`/api/assistant/conversations/{conversation_id}/messages\``
- **Query**：
  - `limit`（默认 50，最大 200）
  - `before_id`（可选，向更早翻页的游标；传入后返回 `id < before_id` 的更早消息）
- **返回**：

```json
{
  "conversation_id": "conv_xxx",
  "messages": [
    { "id": 101, "role": "user", "content": "…", "created_at": 1710000000.0 },
    { "id": 102, "role": "assistant", "content": "…", "created_at": 1710000001.2 }
  ],
  "next_before_id": "101"
}
```

> `messages` 在服务端已按时间**正序**返回，前端可直接渲染。

### 2.3 `/api/chat` 落库（核心）

在 `POST /api/chat` 中：
- 若请求带 `Authorization` 且解析出 `user_id`，并且 body 里有 `agent_id`：
  - `get_or_create_conversation_id(user_id, agent_id)`
  - 依次插入 `user` 与 `assistant` 两条消息到 `assistant_messages`
  - 响应附带 `conversation_id`（便于前端缓存/调试）

---

## 3. 客户端实现（Flutter）

### 3.1 API 扩展

在 `lib/features/assistant/services/assistant_api.dart` 增加两项能力：
- `getOrCreateConversationId`
- `listConversationMessages`

`HttpAssistantApi` 对接上述两个后端接口。

### 3.2 聊天页加载逻辑

在 `AgentChatPage._loadMessages()`：
- **登录态优先**：拿到 token 后先调用后端接口拉取最近 N 条历史；
- 拉到的消息写入本地 `AssistantRepository` 作为缓存（消息 id 使用 `srv_` 前缀避免与本地消息 id 冲突）；
- 再走 `repository.loadMessages(agentId)` 刷新 UI。

---

## 4. 常见问题与扩展方向

- **消息量无限增长**：依赖分页 + 服务端按会话做清理策略（可加“仅保留最近 6 个月”或“用户手动清空会话”）。
- **多设备同时发消息**：用 `client_msg_id` 幂等，必要时服务端再加唯一索引 `(conversation_id, client_msg_id)`。
- **多会话**：当前实现按 `(user_id, agent_id)` 固定 1 个会话；后续可放开 UNIQUE，改成显式创建会话并返回会话列表。
- **搜索**：可在 `assistant_messages(content)` 上做 FTS（SQLite FTS5）以支持关键词检索。

