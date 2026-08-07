# 希比 HIBI（jideshi_hibi）

三端互通助手应用：日程、数字助理、局域网传输、思维画布、账户同步。客户端 **Flutter**（Windows / Android / iOS 等），后端 **Python FastAPI**，可选 SQLite 用户与同步。

---

## 一、技术栈与架构概览

| 层级 | 技术 | 说明 |
|------|------|------|
| 客户端 | Flutter 3.x、Dart 3.5+ | 单仓库多平台；`MaterialApp` + 深色紫系主题 |
| 状态与存储 | `SharedPreferences`、`path_provider` | Token / 用户信息；业务数据落盘到应用文档目录 |
| 网络 | `http` | 助理对话、注册登录、同步 pull/push |
| 后端 | Python 3、FastAPI、uvicorn | `/api/chat`、认证与同步挂载在同应用或可拆分 |
| 后端存储 | SQLite（`hibi_users.db`） | users / sessions / user_data（mind、schedule、assistant JSON） |
| 大模型 | httpx 调用 OpenAI 兼容接口 | 豆包 / 通义 / OpenAI 等，由 `.env` 的 `MODEL_BASE_URL` 决定 |

```
┌─────────────────────────────────────────────────────────────────┐
│                        Flutter App                               │
│  MainShell → 思维 | 日程 | 助理 | 传输 | 个人中心                  │
│  ├── 本地 JSON / 多账号目录 hibi_accounts/<key>/                  │
│  ├── AuthRepository + UserSyncService（登录后 pull/push）         │
│  └── Feature 模块见下表「功能与数据」                              │
└───────────────────────────┬─────────────────────────────────────┘
                            │ HTTP
┌───────────────────────────▼─────────────────────────────────────┐
│              backend_jideshi_hibi_app (api_only_app)             │
│  POST /api/chat  → 大模型                                       │
│  POST /api/auth/register|login|logout                           │
│  GET  /api/sync/pull  /  POST /api/sync/push   + Bearer token   │
│  SQLite + HIBI_DATA_DIR 卷持久化                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 二、功能模块与数据落点

| 模块 | 路径（lib） | 本地数据 | 后端/同步 |
|------|-------------|----------|-----------|
| 思维节点 | `features/mind/` | `hibi_accounts/<key>/hibi_mind_nodes.json` | sync mind |
| 日程 | `features/schedule/` | `hibi_accounts/<key>/hibi_schedule_events.json` | sync schedule |
| 数字助理 | `features/assistant/` | `hibi_accounts/<key>/hibi_assistant/`（agents + messages_*.json） | sync assistant |
| 文件传输 | `features/transfer/` | 接收目录可配置；发现 UDP 62637± | 无服务端存储 |
| 账户 | `features/auth/` | `SharedPreferences` + 上表目录按账号隔离 | 见 AUTH_SPEC / AUTH_SYNC_DEPLOY |

**多账号隔离**：未登录使用 `hibi_accounts/local/`；登录后用 `sanitize(userId)` 子目录，切换账号不删盘内其他账号副本，仅切换活动目录并 reload，避免串数据。

---

## 三、数据结构要点

### 3.1 客户端（按账号目录）

- **思维**：节点列表 JSON，画布内方块/连线等序列化在同结构内（见 `MIND_NODE_SPEC.md`）。
- **日程**：`ScheduleEvent` 列表；与思维方块提醒通过 `ScheduleEventStore.mindBlockEventId` 关联。
- **助理**：`assistant_agents.json` + 每个 agent 一个 `messages_<agentId>.json`；单条 `ChatMessage` 含 `id`、`role`、`content`、`timestamp`，支持长按复制/删除/多选删除。
- **传输**：`TransferRecord` 内存列表；发现广播 JSON 含 `platform` 等。

### 3.2 后端 SQLite（`hibi_auth_sync.py`）

- **users**：id、phone_or_email、password_hash、salt、nickname…
- **sessions**：token、user_id、过期时间逻辑
- **user_data**：`(user_id, data_key)` → payload 文本，`data_key` ∈ mind / schedule / assistant

邀请码常量：`tsinghibi2024`（可后续改环境变量）。

### 3.3 同步合并策略（客户端 `sync_merge.dart`）

- **mind**：按 id 合并，`updatedAt` 新者胜。
- **schedule**：按 id，本地已存在则偏向保留本地。
- **assistant**：agents 本地优先；messages 按角色+时间+内容去重拼接。

---

## 四、前后端逻辑摘要

1. **不强制登录**：未登录可全功能使用，个人中心显示「本地账户」，点头像再进登录/注册。
2. **注册**：需邀请码；成功后 `setActiveUser` → pull → push，数据写入当前账号目录。
3. **退出/换账号**：先 push 当前 token →（可选）logout API → `cancelPendingPush` → 活动目录切回 `local` → reload，**不删除**其他账号目录。
4. **助理发消息**：前端组 `message` + `history` + `agent_name` / `agent_role` → POST `/api/chat` → 回复写入本地 messages 文件。
5. **传输**：UDP 发现 + TCP 传文件/文本；接收端 body 必须缓冲后再写入文件（见传输笔记），否则会得到空文件。

配置入口：`lib/config/api_config.dart`（`assistantApiBaseUrl`、`authApiBaseUrl` 等）。

---

## 五、UI / 视觉原则

- 全局 **FrostedBackground**（图三 + blur + 蒙层）；顶栏一律透明去 tint，避免 Windows 黑条。
- 卡片统一 **AppGlassStyles**（半透明 + 描边 + 圆角 16）；详见 `lib/app/UI_STYLE.md`。
- 思维画布：方块 **BackdropFilter** 轻毛玻璃；连线线宽/箭头/把手缩小以减轻视觉重量（见 `MIND_NODE_SPEC.md`）。

---

## 六、运行与部署

```bash
flutter pub get
flutter run
```

- **Pub 镜像 / 安卓调试**：根目录 `setup_pub_mirror_once.ps1`、`安卓真机调试.md`。
- **后端（仅 ECS）**：不在本机运行后端。部署与重启见 `backend_jideshi_hibi_app/README.md`、`sync_to_server.ps1`；Docker 部署须挂卷 `-v ...:/app/data`，见 `AUTH_SYNC_DEPLOY.md`。
- **阿里云部署**：`backend_jideshi_hibi_app/DEPLOY_ALIYUN.md`、`后端初步部署.md`。
- **Windows 安装包（Inno）**：`tools/build_windows_installer.ps1` + `PACKAGING_RELEASE.md` 第四节；**禁止**对编好的 `Hibi2024_Setup_*.exe` 做 Resource Hacker/rcedit，否则安装数据被截断报 corrupted。

---

## 七、文档索引（按主题）

| 文档 | 内容 |
|------|------|
| `lib/features/auth/AUTH_SPEC.md` | 前端认证与同步约定，供后端对接 |
| `backend_jideshi_hibi_app/AUTH_SYNC_DEPLOY.md` | 注册登录、SQLite、Docker 持久化、接口列表 |
| `lib/features/mind/MIND_NODE_SPEC.md` | 画布、方块/连线、缩放、贴边、工具栏 |
| `lib/features/transfer/TRANSFER_DISCOVERY_NOTES.md` | UDP 端口、防火墙、空文件修复、传输记录 |
| `lib/features/assistant/智能体对话原理.md` | /api/chat 组包、后端拼 prompt、本地复制删除多选 |
| `lib/app/UI_STYLE.md` | 毛玻璃与主题统一 |
| `backend_jideshi_hibi_app/豆包401问题修复记录.md` | MODEL_BASE_URL 指向错误导致 401 |
| `后端git管理.md` | 后端仓库与脚本换行等 |
| `应用简介-客户版.md` | **面向客户/用户的简单功能说明**（中文，无技术细节） |
| `APP_INTRO_FOR_CUSTOMERS_EN.md` | **Same intro in English** for customers / store copy |
| `版本管理.md` | **版本管理**：各版本（如 V1.0.1）修复的 Bug 与变更记录 |
| `主题功能.md` | **主题功能**：hibi / 暗色 / 亮色主题技术原理与实现说明 |
| `PACKAGING_RELEASE.md` | **iOS / Android / Windows / Linux 打包与发布**；Windows Inno 单文件安装包**禁止编译后改 exe**（见 4.2） |
| `tools/build_windows_installer.ps1` | 仅 `flutter build windows --release` + ISCC，无后处理 |

---

## 八、重要问题与修复（按时间线梳理）

> 便于后人排查：现象 → 原因 → 方案 → 代码/文档位置。

| 时间/阶段 | 现象 | 原因 | 处理 |
|-----------|------|------|------|
| 传输 | 收到文件 0 字节 | body 用 broadcast 流，接受后才订阅，已发数据丢失 | 接收改内存缓冲 + `Completer`，再写入文件；`transfer_server.dart` |
| 传输 | Windows 发现不到设备 | UDP 62637 防火墙/保留端口 errno 10013 | 端口回退 62637–62639、三端口广播、防火墙脚本与说明；`TRANSFER_DISCOVERY_NOTES.md` |
| 思维画布 | 横屏工具栏溢出 | 固定高度 Column 超出 | 左右工具栏 `SingleChildScrollView`；后改为 `LayoutBuilder` + `minHeight` + `Center` 上下居中 |
| 思维画布 | 双指缩放元素飞走 | 缩放未以双指中心为 pivot | pivot 公式修正 `_pan = center - scale * canvasUnderFingers`；见 MIND_NODE_SPEC |
| 账户 | 换账号后看到别人数据 | 本地单路径，logout 前未隔离 | 多账号目录 `hibi_accounts/<id>/` + 切换仅 reload；`AccountStoragePaths` |
| 后端 | 删容器后用户没了 | DB 在容器内未挂卷 | `HIBI_DATA_DIR` + `-v host/data:/app/data`；`server_redeploy.sh` |
| 后端 | 豆包 Key 却报 401 | 容器仍用 dashscope 的 `MODEL_BASE_URL` | 用 `--env-file .env` 重建容器；`豆包401问题修复记录.md` |
| 部署 | Linux 上 `.sh` 无法执行 | Windows CRLF shebang | `.gitattributes` `*.sh eol=lf`；或用 LF 重写脚本 |
| 日程 | 编辑页顶栏发黑、无删除 | AppBar 实底 + 无删除入口 | 毛玻璃卡片 + 删除确认 + `schedule_page` pop 类型区分 |
| UI | 各页 Card/顶栏不统一 | 默认 Material 实色 | `AppTheme` + `AppGlassStyles` 统一；`UI_STYLE.md` |
| 助理 | 无法复制/删单条/批量删 | 无长按菜单、无稳定消息 id | `ChatMessage.id`、Repository 按 id 删除、长按 bottom sheet + 多选模式 |
| Windows 安装 | Setup.exe 报 setup files corrupted | Resource Hacker/rcedit 只写 PE，截断 Inno 尾部压缩数据 | **禁止**后处理；仅用 ISCC 重编；`PACKAGING_RELEASE.md` 4.2、`README_安装包说明.txt` |
| 思维白板 V1.0.1 | 电脑端返回后笔记没了；手机端打开用本地空/旧数据覆盖云端 | 保存未 await 即返回；先 push 再 pull 且思维未从盘重载 | 返回前 await 待保存；左侧加「保存」+ 失败提示；先 pull 再推、MindRepository 单例 + pull 后 reload；`版本管理.md` |

---

## 九、仓库结构（精简）

```
jideshi_hibi/
├── lib/
│   ├── main.dart
│   ├── app/                 # 主题、主壳、FrostedBackground、AppGlassStyles、InitialAppLoader
│   ├── config/              # api_config
│   └── features/
│       ├── auth/            # 登录注册、同步、AccountStoragePaths
│       ├── mind/            # 画布、节点、MIND_NODE_SPEC
│       ├── schedule/        # 日程、编辑页
│       ├── assistant/       # 智能体、对话页、智能体对话原理
│       ├── transfer/        # 发现、收发、TRANSFER_DISCOVERY_NOTES
│       └── profile/         # 个人中心、设置
├── backend_jideshi_hibi_app/
│   ├── api_only_app.py      # FastAPI 入口（chat + auth + sync）
│   ├── hibi_auth_sync.py    # SQLite 用户与同步存储
│   ├── Dockerfile           # 含 data 目录与卷说明
│   └── AUTH_SYNC_DEPLOY.md
├── tools/
│   └── build_windows_installer.ps1   # Inno 安装包：仅 flutter build + ISCC
├── README.md                # 本文件
├── PACKAGING_RELEASE.md     # 各平台打包；Windows 4.2 含禁止后处理说明
├── 安卓真机调试.md
├── 后端初步部署.md
└── setup_pub_mirror_once.ps1
```

---

## 十、版本与维护

- **应用版本**：`pubspec.yaml` → `version: 1.0.0+1`（可按需要改 build-name/number）。
- **后续扩展**：刷新 token、WebSocket 真实时同步、画布协作等可在 AUTH_SPEC / MIND_NODE_SPEC 旁另起 ADR 或 spec 增量记录。

如有新增大改，建议在本 README **第八节** 追加一行「时间 + 现象 + 原因 + 处理 + 文档/路径」，保持时间线可读。
