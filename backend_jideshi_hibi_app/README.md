# 希比 HIBI 智能体对话后端

与 Flutter 应用 `jideshi_hibi` 的「助理」功能对接，提供 `POST /api/chat` 智能体对话接口。

**约定：本后端仅在 ECS 上运行，不在本机启动或调试。** 代码通过 `sync_to_server.ps1` 同步到 ECS，重启使用 ECS 上的 systemd（`jideshi-hibi-api`）或 Docker。

## 技术栈

- Python 3 + FastAPI + uvicorn
- httpx 调用 OpenAI 兼容大模型（通义/豆包/OpenAI 等）

## 部署（仅 ECS）

1. 本机执行 `.\backend_jideshi_hibi_app\sync_to_server.ps1`，将代码同步到 ECS（脚本会顺带在 ECS 上执行重启）。
2. 接口文档：`http://<ECS 地址>:7861/docs`（当前 ECS：121.41.6.21:7861）。

## 环境变量（.env）

| 变量 | 说明 |
|------|------|
| MODEL_BASE_URL | 大模型 API 根地址（如通义兼容模式） |
| MODEL_API_KEY | API Key |
| MODEL_ID | 模型名（如 qwen-plus、gpt-3.5-turbo） |
| PORT | 服务端口，默认 7861 |

## 接口说明

- **POST /api/auth/register**、**POST /api/auth/login**、**POST /api/auth/logout**  
  用户注册/登录/登出，邀请码见 `hibi_auth_sync.py` 中 `INVITE_CODE`。
- **GET /api/sync/pull**（需 Bearer token）  
  拉取该账号的 mind、schedule、assistant、**settings**（含主题 themeId）。
- **POST /api/sync/push**（需 Bearer token）  
  上传 mind、schedule、assistant、**settings**；主题选择会随 sync 同步到云端，换设备登录后自动恢复。
- **POST /api/chat**  
  - 请求体：`message` 或 `userMessage`（必填）、`history`（可选，多轮）、`agent_name`、`agent_role`（可选，用于生成智能体 system prompt）。  
  - 响应：`{ "reply": string, "memory_connected": false, "memory_full": false }`。

## ECS 上运行方式

- **systemd**（推荐）：服务名 `jideshi-hibi-api`，配置见 `jideshi-hibi-api.service`；`.env` 放在 `/root/jideshi_hibi_backend/`，改完后 `systemctl restart jideshi-hibi-api`。
- **Docker**：见 `DEPLOY_ALIYUN.md`、`云服务器更新说明.md`。

Flutter 端 `api_config.dart` 中 `assistantApiBaseUrl` 指向 ECS（如 `http://121.41.6.21:7861`）。
