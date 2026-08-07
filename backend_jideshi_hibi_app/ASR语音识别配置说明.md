# 智能体语音转文字（ASR）配置说明（可复用版）

本文用于在其他项目快速复现「前端实时语音输入 + 后端豆包 SAUC 流式识别」能力，覆盖：

- 后端 `.env` 配置
- 前后端代码原理
- 部署与排障步骤
- 本项目踩坑与修复结论

---

## 1. 官方文档（基线）

- 大模型流式语音识别 API：<https://www.volcengine.com/docs/6561/1354869?lang=zh>
- 鉴权方法：<https://www.volcengine.com/docs/6561/107789>
- 控制台创建应用：<https://www.volcengine.com/docs/6561/163043>

---

## 2. 架构与数据流（复现必看）

### 2.1 端到端链路

1. Flutter 前端录音（16kHz、16bit、单声道）并实时切片。
2. 前端通过 WebSocket 调后端 `/api/asr/stream`。
3. 后端再作为客户端连接豆包 SAUC WebSocket（`bigmodel`）。
4. 后端把音频分包透传给豆包，并把 `partial/final` 回推前端。
5. 前端实时显示预览文字，松手后拿 `done` 作为最终文本。

### 2.2 仓库关键文件

| 说明 | 路径 |
|------|------|
| Flutter 流式 ASR 客户端 | `lib/features/assistant/services/asr_stream_service.dart` |
| Flutter 语音交互 UI | `lib/features/assistant/agent_chat_page.dart` |
| 后端路由与 WS 桥接 | `backend_jideshi_hibi_app/api_only_app.py` |
| 后端 ASR 业务封装 | `backend_jideshi_hibi_app/hibi_asr.py` |
| SAUC 协议编解码 | `backend_jideshi_hibi_app/hibi_sauc_protocol.py` |

---

## 3. ECS `.env` 配置（后端）

> 推荐路径：`/root/jideshi_hibi_backend/.env`

### 3.1 必填

| 变量 | 说明 |
|------|------|
| `ASR_APP_ID`（或兼容名 `ASR_APP_KEY`） | 控制台应用 APP ID |
| `ASR_TOKEN`（或兼容名 `ASR_ACCESS_KEY`） | 控制台 Access Token（不是 Secret Key） |
| `ASR_RESOURCE_ID` | 控制台该能力对应资源 ID（必须一致） |

### 3.2 推荐

| 变量 | 推荐值/说明 |
|------|-------------|
| `ASR_ENABLED` | `true` |
| `ASR_WS_URL` | `wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream`（非流式默认地址；流式时后端会自动换候选） |
| `ASR_INCLUDE_CONNECT_ID` | 建议 `0`（握手兼容性更稳） |

### 3.3 排障可选

| 变量 | 说明 |
|------|------|
| `ASR_SWAP_KEYS` | `1` 时交换 APP ID / Token，用于怀疑填反时临时排查 |
| `ASR_STREAM_DRAIN_RECV_TIMEOUT` | 流式收尾等待时间（秒），默认 22 |
| `ASR_USER_UID` | 请求里的 `user.uid`，默认 `hibi_asr` |
| `ASR_SEGMENT_MS` | 非流式接口分片间隔，默认 200ms |

### 3.4 示例（可直接改值）

```env
ASR_ENABLED=true
ASR_APP_ID=9706629904
ASR_TOKEN=你的AccessToken
ASR_RESOURCE_ID=volc.bigasr.sauc.duration
ASR_WS_URL=wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream
ASR_INCLUDE_CONNECT_ID=0
```

---

## 4. 前端代码原理（Flutter）

### 4.1 核心流程

1. `_asrStreamService.start()` 建立到后端的 WebSocket（**不再阻塞等待**服务端 `ready` 再返回；连接成功即可）。
2. `AudioRecorder.startStream()` 与上一步 **并行** 启动（`Future.wait`），尽快开始采集 16kHz PCM。
3. 每个片段 `sendAudio(chunk)`：若服务端尚未回 `ready`，音频会 **先入队缓冲**（有字节上限），收到 `ready` 后 **按顺序补发到后端**，避免「先等握手再开麦」丢掉句首。
4. 后端回 `partial/final` 时更新 `_streamPreviewText`（实时 UI）。
5. 松手调用 `stopAndGetFinal(cancel:false)`，等 `done` 得最终文本。

### 4.2 关键实现点

- **句首丢失（用户感觉说了半句才开始听）**：根因通常是 **先 `await ready` 再 `startStream`**。已改为 **WS 与麦克风并行 + ready 前缓冲**（见 `asr_stream_service.dart` / `agent_chat_page.dart`）。
- **业务场景优化（按下即听）**：聊天页切到「语音模式」后，会先做 **预热**：提前开启麦克风流并做环形缓冲，同时预连接 ASR WebSocket。用户按下按钮时会立刻把缓冲音频 flush 给 ASR，确保“按下那一刻开始说的话”被识别到（减少启动抖动）。
- **按住说话**：桌面端 **不再** 先等 60ms 再开始录音；按下即走权限与并行建链。
- **移动端**：仍为 `onLongPress` 触发，系统长按有约 **300–500ms** 识别延迟，这是手势层限制；若需与桌面一致「按下即录」，可后续改为 `Listener` + `onPointerDown`（产品再定）。
- `stopAndGetFinal` 超时需 >= 后端收尾等待（本项目已调至 30s）。
- 录音浮层应实时显示 `_streamPreviewText`（空时显示“正在实时识别”）。
- 桌面端权限策略与移动端不同（本项目已规避 Windows 权限误拦截）。
- 建议保留 `debugPrint('[ASR-STREAM] ...')` 便于快速定位。

---

## 5. 后端代码原理（FastAPI + SAUC）

### 5.1 `/api/asr/stream` 的桥接逻辑

`api_only_app.py` 中 `ws_asr_stream` 做两件事：

1. 收前端音频并转发给豆包（`recv_client_audio`）。
2. 收豆包响应并转发前端（`recv_doubao_result`）。

最后发送 `done`，文本取 `final_text or last_partial`。

### 5.2 为什么“先收豆包首包再给前端 ready”

若未校验首包就返回 `ready`，前端会立刻推流，可能在上游鉴权/协议未就绪时进入“全程空结果”。
本项目已改为：

- 先发 full client request
- 等豆包首包并校验
- 再发前端 `ready`

**与前端的关系**：后端在 `ready` 之前需要一点时间，客户端**不应**在等到 `ready` 后才开始 `startStream`，否则用户会明显感觉「说了半句才开始听」。当前 Flutter 端在 `ready` 前**缓冲 PCM**，收到 `ready` 后自动补发，与上述后端策略兼容。

### 5.3 本项目关键修复：`audio.format` 必须是 `pcm`

历史问题：协议首包写成 `format: "wav"`，但流式上传是裸 PCM 分片，导致豆包持续报错（如 45000151/45000081）。

已修复：`hibi_sauc_protocol.py` 的 `new_full_client_request()` 中：

- `audio.format: "pcm"`
- `audio.codec: "raw"`

这是本项目最终跑通的关键点之一。

---

## 6. 一次性部署与验证（ECS）

1. 同步代码到 ECS（确保 `api_only_app.py` / `hibi_asr.py` / `hibi_sauc_protocol.py` 最新）。
2. 更新 `.env`（尤其 `ASR_APP_ID`、`ASR_TOKEN`、`ASR_RESOURCE_ID`）。
3. 重启服务：
   ```bash
   systemctl restart jideshi-hibi-api
   systemctl is-active jideshi-hibi-api
   ```
4. 基础检查：
   ```bash
   curl -s http://127.0.0.1:7861/api/asr/config
   ```
   期望：`{"configured":true}`
5. 实时日志观察（边说边看）：
   ```bash
   journalctl -u jideshi-hibi-api -f
   ```

---

## 7. 故障排查速查表

### 7.1 前端提示“流式识别未返回文本”

先看 ECS 日志是否有：

- `WebSocket /api/asr/stream [accepted]`
- `ASR stream ws_connect failed ...`
- `ASR stream 豆包返回错误 code=...`

### 7.2 常见现象与定位

- `400 Invalid response status`：常见为资源 ID 不匹配、请求头不兼容。
- `403 Invalid response status`：常见为能力未开通/权限不足/资源包问题。
- `45000151 / 45000081`：上游业务校验失败，优先检查 `ASR_RESOURCE_ID` 与协议字段（尤其 `audio.format`）。
- 只有 `done len=0` 无 `partial/final`：看是否上游持续报错、或客户端/后端超时过短。

### 7.3 最短排障命令

```bash
grep -E '^ASR_|^PORT=' /root/jideshi_hibi_backend/.env
systemctl status jideshi-hibi-api --no-pager -l
journalctl -u jideshi-hibi-api -n 200 --no-pager
```

---

## 8. 在新项目复用的最小清单

1. 复制后端三件套：`hibi_sauc_protocol.py`、`hibi_asr.py`、`/api/asr/stream` 路由。
2. 确保 full client request 中 `audio.format="pcm"`、`codec="raw"`。
3. 前端实现 WS 流式发送 + `partial/final/done` 事件处理。
4. `.env` 配齐 `ASR_APP_ID` + `ASR_TOKEN` + `ASR_RESOURCE_ID`。
5. 保留端到端日志（前端 `[ASR-STREAM]`，后端 `ASR stream ...`）。

---

## 9. 安全与运维建议

- 不要在仓库提交真实 Token。
- 不要把 root 密码长期共享；排障后立即改密。
- 优先通过 `systemd + journalctl` 管服务，便于审计与回溯。

---

## 10. 新项目10行速用 Checklist

1. 火山控制台创建语音应用并开通「大模型流式语音识别」。
2. 记录三项：`APP ID`、`Access Token`、该能力页面的 `Resource ID`。
3. 后端 `.env` 必填：`ASR_APP_ID`、`ASR_TOKEN`、`ASR_RESOURCE_ID`。
4. 建议加：`ASR_ENABLED=true`、`ASR_INCLUDE_CONNECT_ID=0`。
5. 协议首包必须：`audio.format="pcm"`、`audio.codec="raw"`。
6. 前端录音必须：16kHz、16bit、单声道，流式切片发送。
7. 事件处理：前端要接 `ready/partial/final/done/error`。
8. 重启后端：`systemctl restart jideshi-hibi-api`。
9. 验证配置：`curl -s http://127.0.0.1:7861/api/asr/config` 返回 `configured:true`。
10. 失败先看：`journalctl -u jideshi-hibi-api -f`，定位 400/403/45000151/45000081。
