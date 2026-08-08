"""
希比 HIBI 智能体对话后端：对接 OpenAI 兼容大模型，支持多智能体（名称+职能 system prompt）。
部署到轻量云后配置 .env 中的 MODEL_BASE_URL / MODEL_API_KEY / MODEL_ID 即可。
"""
import os
import json
import logging
import sqlite3
import urllib.parse
import time
import secrets
import base64
import html as html_utils
from typing import Optional
import asyncio
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo
from uuid import uuid4

# 加载同目录 .env（支持多行 PEM）
_env_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env")
if os.path.exists(_env_path):
    with open(_env_path, encoding="utf-8") as f:
        raw_lines = f.read().splitlines()
    i = 0
    while i < len(raw_lines):
        raw = raw_lines[i]
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            i += 1
            continue
        k, v = line.split("=", 1)
        key = k.strip()
        value = v.strip()
        if value.startswith('"') or value.startswith("'"):
            quote = value[0]
            value_body = value[1:]
            if value_body.endswith(quote):
                value = value_body[:-1]
            else:
                parts = [value_body]
                i += 1
                while i < len(raw_lines):
                    nxt = raw_lines[i]
                    if nxt.endswith(quote):
                        parts.append(nxt[:-1])
                        break
                    parts.append(nxt)
                    i += 1
                value = "\n".join(parts)
        os.environ.setdefault(key, value)
        i += 1

import httpx
import aiohttp
from fastapi import FastAPI, Request, UploadFile, File, Form, WebSocket, WebSocketDisconnect
from fastapi.responses import JSONResponse, HTMLResponse, RedirectResponse, PlainTextResponse, FileResponse, Response

logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
logger = logging.getLogger(__name__)

MODEL_BASE_URL = os.getenv("MODEL_BASE_URL", "").strip().rstrip("/")
MODEL_API_KEY = os.getenv("MODEL_API_KEY", "").strip()
MODEL_ID = os.getenv("MODEL_ID", "gpt-3.5-turbo").strip()
PORT = int(os.getenv("PORT", "7861"))


def _normalize_message_content(content):
    if content is None:
        return ""
    if isinstance(content, str):
        return content.strip()
    return str(content).strip()


def _build_system_prompt(agent_name: str, agent_role: str) -> str:
    """根据智能体名称与职能拼 system prompt。"""
    name = (agent_name or "").strip() or "智能助手"
    role = (agent_role or "").strip()
    if role:
        return f"你是「{name}」。\n\n你的职能/角色：\n{role}\n\n请严格按上述身份与职能，用自然、友好的口吻直接回复用户，不要复述身份说明。"
    return f"你是「{name}」。请用自然、友好的口吻直接回复用户。"


# 长对话上下文：保留最近 N 条历史消息发给模型，便于记住上下文（约 N/2 轮对话）
MAX_HISTORY_MESSAGES = 80


def _normalize_history(history) -> list:
    """将前端 history 转为 [{"role":"user"|"assistant","content":"..."}]，最多保留最近 MAX_HISTORY_MESSAGES 条。"""
    if not isinstance(history, list):
        return []
    out = []
    for item in history:
        if not isinstance(item, dict):
            continue
        role = (item.get("role") or "user").strip().lower()
        if role not in ("user", "assistant"):
            role = "user"
        content = _normalize_message_content(item.get("content"))
        if content:
            out.append({"role": role, "content": content})
    return out[-MAX_HISTORY_MESSAGES:] if len(out) > MAX_HISTORY_MESSAGES else out


def _check_base_url_for_doubao(base_url: Optional[str] = None):
    """若当前配置成阿里云地址却用豆包 Key，会 401 且错误链接指向 help.aliyun.com。提醒改用火山方舟。"""
    check = (base_url or MODEL_BASE_URL or "").strip()
    if not check:
        return
    lower = check.lower()
    if "dashscope.aliyuncs.com" in lower or "aliyuncs.com" in lower:
        logger.warning(
            "MODEL_BASE_URL 当前为阿里云地址（%s），若使用豆包请改为: https://ark.cn-beijing.volces.com/api/v3",
            check[:60],
        )


def _normalize_openai_base_url(raw: str) -> str:
    """去掉尾斜杠与误粘贴的 /chat/completions，兼容火山方舟控制台完整 URL。"""
    u = (raw or "").strip()
    while u.endswith("/"):
        u = u[:-1]
    suffix = "/chat/completions"
    if u.lower().endswith(suffix):
        u = u[: -len(suffix)]
        while u.endswith("/"):
            u = u[:-1]
    return u


def _resolve_model_credentials(data: dict) -> tuple[str, str, str, bool]:
    """
    解析本次请求使用的模型凭据。
    客户端可透传 api_key / base_url / model（仅该请求使用，不落盘）。
    返回 (base_url, api_key, model_id, used_client_override)。
    """
    client_key = (data.get("api_key") or data.get("model_api_key") or "").strip()
    client_base = _normalize_openai_base_url(
        (data.get("base_url") or data.get("model_base_url") or "")
    )
    client_model = (data.get("model") or data.get("model_id") or "").strip()
    if client_key and len(client_key) >= 8:
        # 火山 ark- Key 未带 base 时，默认落到方舟而非 api.openai.com，避免误连 OpenAI
        default_base = (MODEL_BASE_URL or "").rstrip("/")
        if not default_base:
            if client_key.startswith("ark-"):
                default_base = "https://ark.cn-beijing.volces.com/api/v3"
            else:
                default_base = "https://api.openai.com/v1"
        base = client_base or default_base
        model = client_model or MODEL_ID or "gpt-3.5-turbo"
        return base, client_key, model, True
    return (
        (MODEL_BASE_URL or "").rstrip("/"),
        MODEL_API_KEY or "",
        MODEL_ID or "gpt-3.5-turbo",
        False,
    )


def _asr_stream_ws_connect_error_message(last_err: Optional[BaseException], last_url: str) -> str:
    """豆包 OpenSpeech WebSocket 握手失败（400/403 等）时给前端的说明，不含密钥。"""
    if last_err is None:
        return "ASR 流式建连失败: unknown"
    raw = str(last_err).strip()
    head = f"ASR 流式建连失败: {raw[:200]}"
    if last_url:
        head += f" url={last_url[:120]}"
    low = raw.lower()
    http_st: Optional[int] = None
    try:
        from aiohttp.client_exceptions import WSServerHandshakeError

        if isinstance(last_err, WSServerHandshakeError):
            http_st = getattr(last_err, "status", None)
            if http_st is not None:
                head += f" http={http_st}"
    except Exception:
        pass
    if http_st is None:
        for marker in ("403", "401", "400"):
            if marker in raw:
                http_st = int(marker)
                break

    if http_st == 403 or (http_st is None and "403" in raw):
        head += (
            "。HTTP 403：无访问权限。请核对：①控制台已开通「大模型流式语音识别」且账号计费/资源包正常；"
            "②ASR_RESOURCE_ID 必须与该能力在控制台展示的资源 ID 完全一致（勿与其它语音产品混用）；"
            "③APP ID、Access Token 对应当前应用；④可试 ASR_INCLUDE_CONNECT_ID=0 后重启。"
        )
    elif http_st == 401 or (http_st is None and "401" in raw):
        head += "。HTTP 401：鉴权失败，请检查 ASR_APP_ID、ASR_TOKEN（勿用 Secret Key 当 Token）。"
    elif (
        http_st == 400
        or (http_st is None and ("400" in raw or "invalid response" in low))
    ):
        head += (
            "。HTTP 400：请求不被接受。请核对：①APP ID、Access Token；②ASR_RESOURCE_ID；"
            "③可试 ASR_SWAP_KEYS=1 或 ASR_INCLUDE_CONNECT_ID=0 后重启。"
        )
    return head[:580]


async def _chat_completions_stream_messages(
    messages: list,
    *,
    base_url: Optional[str] = None,
    api_key: Optional[str] = None,
    model_id: Optional[str] = None,
):
    """调用 OpenAI 兼容 /chat/completions，流式返回完整回复。"""
    if not messages:
        return
    base = (base_url or MODEL_BASE_URL or "https://api.openai.com/v1").rstrip("/")
    key = (api_key or MODEL_API_KEY or "").strip()
    mid = (model_id or MODEL_ID or "gpt-3.5-turbo").strip()
    url = base + "/chat/completions"
    headers = {"Authorization": f"Bearer {key}", "Content-Type": "application/json"}
    payload = {"model": mid, "messages": messages, "stream": True}
    full_reply = ""
    try:
        async with httpx.AsyncClient(timeout=120.0) as client:
            logger.info("模型请求: %s, messages=%s", url[:80], len(messages))
            async with client.stream("POST", url, json=payload, headers=headers) as r:
                if r.status_code != 200:
                    err_text = await r.aread()
                    raise Exception(f"模型 API 错误 {r.status_code}: {err_text[:500].decode(errors='ignore')}")
                async for line in r.aiter_lines():
                    if not line or not line.startswith("data: "):
                        continue
                    data = line[6:].strip()
                    if data == "[DONE]":
                        break
                    try:
                        obj = json.loads(data)
                        for c in obj.get("choices", []):
                            delta = c.get("delta", {})
                            cnt = delta.get("content") or delta.get("text") or ""
                            if cnt:
                                full_reply += cnt
                                yield full_reply
                    except json.JSONDecodeError:
                        pass
    except Exception as e:
        logger.exception("模型请求异常: %s", e)
        raise


async def _chat_completions_with_tools(
    messages: list,
    tools: list,
    tool_choice: str,
    user_id: str,
    current_mind_node_id: Optional[str],
    *,
    base_url: Optional[str] = None,
    api_key: Optional[str] = None,
    model_id: Optional[str] = None,
) -> str:
    """非流式调用，支持 tool_calls；执行后追加 tool 结果再请求，最多 3 轮。"""
    import hibi_abp_tools as _abp
    import hibi_auth_sync as _auth

    base = (base_url or MODEL_BASE_URL or "https://api.openai.com/v1").rstrip("/")
    key = (api_key or MODEL_API_KEY or "").strip()
    mid = (model_id or MODEL_ID or "gpt-3.5-turbo").strip()
    url = base + "/chat/completions"
    headers = {"Authorization": f"Bearer {key}", "Content-Type": "application/json"}
    max_rounds = 3
    last_assistant_content = ""
    for _ in range(max_rounds):
        payload = {
            "model": mid,
            "messages": messages,
            "tools": tools,
            "tool_choice": tool_choice,
        }
        async with httpx.AsyncClient(timeout=120.0) as client:
            r = await client.post(url, json=payload, headers=headers)
        if r.status_code != 200:
            raise Exception(f"模型 API 错误 {r.status_code}: {r.text[:500]}")
        data = r.json()
        choice = (data.get("choices") or [{}])[0]
        msg = choice.get("message") or {}
        tool_calls = msg.get("tool_calls")
        content = (msg.get("content") or "").strip()
        if content:
            last_assistant_content = content
        if not tool_calls:
            return content or last_assistant_content
        messages.append(msg)
        for tc in tool_calls:
            tid = tc.get("id") or ""
            fn = (tc.get("function") or {})
            fname = fn.get("name") or ""
            try:
                args = json.loads(fn.get("arguments") or "{}")
            except Exception:
                args = {}
            result = _abp.execute_tool(
                fname,
                args,
                user_id,
                _auth.get_user_data,
                _auth.save_user_data,
                current_mind_node_id=current_mind_node_id,
            )
            messages.append({
                "role": "tool",
                "tool_call_id": tid,
                "content": result,
            })
        tool_choice = "auto"
    return last_assistant_content


app = FastAPI(title="希比 HIBI 智能体 API")

from fastapi.middleware.cors import CORSMiddleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/")
async def root():
    return {
        "message": "希比 HIBI 智能体 API",
        "docs": "/docs",
        "chat": "POST /api/chat",
    }


@app.get("/api/assistant/conversation")
async def api_assistant_get_or_create_conversation(request: Request):
    """按当前登录用户 + agent_id 获取/创建会话 id（方案 B）。"""
    user_id = _bearer_user_id(request)
    if not user_id:
        return JSONResponse({"message": "未登录"}, status_code=401)
    agent_id = (request.query_params.get("agent_id") or "").strip()
    if not agent_id:
        return JSONResponse({"message": "agent_id 必填"}, status_code=400)
    title = (request.query_params.get("title") or "").strip() or None
    cid = _get_or_create_conversation_id(user_id, agent_id, title=title)
    _maybe_migrate_legacy_assistant_history(user_id, agent_id, cid)
    return JSONResponse({"conversation_id": cid})


@app.get("/api/assistant/conversations/{conversation_id}/messages")
async def api_assistant_list_messages(conversation_id: str, request: Request):
    """分页拉取会话消息（倒序游标）。before_id 为空则取最新；limit 默认 50。"""
    user_id = _bearer_user_id(request)
    if not user_id:
        return JSONResponse({"message": "未登录"}, status_code=401)
    conv_id = (conversation_id or "").strip()
    if not conv_id:
        return JSONResponse({"message": "conversation_id 必填"}, status_code=400)
    try:
        limit = int(request.query_params.get("limit") or "50")
    except ValueError:
        limit = 50
    limit = max(1, min(200, limit))
    before_id = (request.query_params.get("before_id") or "").strip()
    with _assistant_db() as c:
        owner = c.execute(
            "SELECT user_id, agent_id FROM assistant_conversations WHERE id = ?",
            (conv_id,),
        ).fetchone()
        if not owner or owner["user_id"] != user_id:
            return JSONResponse({"message": "会话不存在"}, status_code=404)
        if before_id:
            try:
                bid = int(before_id)
            except ValueError:
                bid = 0
        else:
            bid = 0
        if bid > 0:
            rows = c.execute(
                """SELECT id, role, content, created_at
                   FROM assistant_messages
                   WHERE conversation_id = ? AND id < ?
                   ORDER BY id DESC
                   LIMIT ?""",
                (conv_id, bid, limit),
            ).fetchall()
        else:
            rows = c.execute(
                """SELECT id, role, content, created_at
                   FROM assistant_messages
                   WHERE conversation_id = ?
                   ORDER BY id DESC
                   LIMIT ?""",
                (conv_id, limit),
            ).fetchall()
    msgs = []
    for r in rows:
        msgs.append(
            {
                "id": int(r["id"]),
                "role": r["role"],
                "content": r["content"],
                "created_at": float(r["created_at"]),
            }
        )
    # 返回按时间正序，方便前端直接 append/渲染
    msgs.reverse()
    next_before = str(msgs[0]["id"]) if msgs else None
    return JSONResponse({"conversation_id": conv_id, "messages": msgs, "next_before_id": next_before})


@app.post("/api/chat")
async def api_chat(request: Request):
    """
    智能体对话。
    请求体：message（必填）, history（可选）, agent_name / agent_role（可选）。
    use_backend_system_prompt=true 时使用后端项目助理 system prompt（文件 / 后台保存 / 默认）并支持工具调用（需 Authorization）。
    agent_name / agent_role：与 ABP 合用人设（拼在 system 全文前）；current_mind_node_id：当前思维节点 id，供 get_mind_canvas 等使用。
    可选透传：api_key / base_url / model —— 仅该请求使用用户自定义凭据调模型（不落盘），工具仍走服务端 ABP。
    返回：{ "reply": string, "tools_used": bool }。
    """
    try:
        data = await request.json()
        message = _normalize_message_content(data.get("message") or data.get("userMessage"))
        if not message:
            return JSONResponse({"error": "message 或 userMessage 必填"}, status_code=400)

        agent_id = (data.get("agent_id") or "").strip()

        history_raw = data.get("history") if isinstance(data.get("history"), list) else None
        history = _normalize_history(history_raw)
        use_backend_prompt = data.get("use_backend_system_prompt") is True
        current_mind_node_id = (data.get("current_mind_node_id") or "").strip() or None

        req_base, req_key, req_model, used_client = _resolve_model_credentials(data)
        if not req_base or not req_key:
            logger.warning("未配置 MODEL_BASE_URL 或 MODEL_API_KEY，且客户端未透传凭据")
            return JSONResponse({
                "reply": "后端未配置大模型（请在服务器 .env 中设置 MODEL_BASE_URL、MODEL_API_KEY、MODEL_ID，或在 App「智能体配置」中填写 API Key）。",
                "memory_connected": False,
                "memory_full": False,
            })
        _check_base_url_for_doubao(req_base)
        if len(req_key) < 8:
            logger.warning("模型 API Key 长度过短（client_override=%s）", used_client)
            return JSONResponse({
                "reply": "模型 API Key 无效，请检查服务器配置或 App「智能体配置」。",
                "memory_connected": False,
                "memory_full": False,
            })

        if use_backend_prompt:
            import hibi_abp_tools as _abp
            import hibi_auth_sync as _auth
            auth_header = request.headers.get("Authorization") or ""
            token = auth_header[7:].strip() if auth_header.startswith("Bearer ") else ""
            user_id = _auth.get_user_id_from_token(token) if token else None
            if not user_id:
                return JSONResponse({
                    "reply": "使用项目助理（工具调用）需先登录，请登录后重试。",
                    "tools_used": False,
                })
            system_content = _resolve_abp_system_prompt()
            agent_name = (data.get("agent_name") or "").strip()
            agent_role = (data.get("agent_role") or "").strip()
            if agent_name or agent_role:
                persona_parts: list[str] = []
                if agent_name:
                    persona_parts.append(f"你在对话中使用的名字是「{agent_name}」。")
                if agent_role:
                    persona_parts.append(f"你的角色与说话风格设定：{agent_role}")
                system_content = "\n".join(persona_parts) + "\n\n" + system_content
            try:
                from zoneinfo import ZoneInfo

                tz_cn = ZoneInfo("Asia/Shanghai")
                now = datetime.now(tz_cn)
                wk = ["一", "二", "三", "四", "五", "六", "日"][now.weekday()]
                ex = now.strftime("%Y-%m-%dT%H:%M")
                system_content = (
                    system_content
                    + f"\n\n【当前日期与时间（Asia/Shanghai）】{now.strftime('%Y-%m-%d %H:%M')}，星期{wk}。"
                    f"用户说「今天」「今晚」「明天」须按此时区理解；调用 create_schedule 时 start_time、end_time 须为 ISO8601（含 T），"
                    f"例如今晚八点：{now.strftime('%Y-%m-%d')}T20:00:00，示例格式参考：{ex}:00。"
                    "\n【对用户可见回复】口语、简短、适合语音收听；勿向用户提及日程 id（evt_…）、方块 id 等内部标识。"
                )
            except Exception:
                pass
            messages = [{"role": "system", "content": system_content}] + history + [{"role": "user", "content": message}]
            tools = _abp.get_tools_definitions()
            # 项目助理：始终允许工具（由 system prompt 约束何时真正调用；不再用关键词关 tool_choice）
            tool_choice = "auto"
            try:
                full_reply = await _chat_completions_with_tools(
                    messages, tools, tool_choice, user_id, current_mind_node_id,
                    base_url=req_base, api_key=req_key, model_id=req_model,
                )
            except Exception as e:
                logger.exception("工具调用轮次异常: %s", e)
                full_reply = f"处理时出错：{str(e)[:200]}"

            # 方案 B：登录态下将每轮对话落到服务端会话/消息表（以 user_id + agent_id 归一会话）
            try:
                if agent_id:
                    conv_id = _get_or_create_conversation_id(user_id, agent_id)
                    _append_message(conv_id, user_id, agent_id, "user", message, client_msg_id=data.get("client_msg_id"))
                    _append_message(conv_id, user_id, agent_id, "assistant", full_reply or "")
            except Exception as e:
                logger.warning("保存助理对话历史失败: %s", e)
            return JSONResponse({
                "reply": full_reply or "",
                "memory_connected": False,
                "memory_full": False,
                "tools_used": tool_choice == "auto",
                "conversation_id": (conv_id if "conv_id" in locals() else None),
                "client_model_override": used_client,
            })

        agent_name = (data.get("agent_name") or "").strip() or "智能助手"
        agent_role = (data.get("agent_role") or "").strip()
        system_content = _build_system_prompt(agent_name, agent_role)
        messages = [{"role": "system", "content": system_content}] + history + [{"role": "user", "content": message}]

        logger.info(
            "模型请求: base_url=%s, model=%s, api_key_len=%d, client_override=%s",
            (req_base or "")[:50], req_model, len(req_key or ""), used_client,
        )
        full_reply = ""
        async for full_reply in _chat_completions_stream_messages(
            messages, base_url=req_base, api_key=req_key, model_id=req_model,
        ):
            pass

        # 普通对话：若有登录态也可落库（不含 tools）
        try:
            user_id = _bearer_user_id(request)
            if user_id and agent_id:
                conv_id = _get_or_create_conversation_id(user_id, agent_id)
                _append_message(conv_id, user_id, agent_id, "user", message, client_msg_id=data.get("client_msg_id"))
                _append_message(conv_id, user_id, agent_id, "assistant", full_reply or "")
        except Exception as e:
            logger.warning("保存助理对话历史失败(plain): %s", e)
        return JSONResponse({
            "reply": full_reply or "",
            "memory_connected": False,
            "memory_full": False,
            "conversation_id": (conv_id if "conv_id" in locals() else None),
            "client_model_override": used_client,
        })
    except Exception as e:
        logger.exception("api_chat 异常: %s", e)
        return JSONResponse({"error": str(e)[:500]}, status_code=500)


# ---------- 用户注册/登录/同步（邀请码 + SQLite） ----------
import hibi_auth_sync as _auth
import hibi_payment as _payment
import hibi_graph_captcha as _graph_captcha
import hibi_asr as _asr

_auth.init_db()
_payment.init_payment_db()


# ---------- 助理对话历史（方案 B：会话/消息表，服务端权威） ----------
def _assistant_db():
    conn = sqlite3.connect(_auth.DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def _init_assistant_chat_db():
    with _assistant_db() as c:
        c.executescript(
            """
            CREATE TABLE IF NOT EXISTS assistant_conversations (
                id TEXT PRIMARY KEY,
                user_id TEXT NOT NULL,
                agent_id TEXT NOT NULL,
                title TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                last_message_at REAL,
                UNIQUE(user_id, agent_id)
            );
            CREATE INDEX IF NOT EXISTS idx_assistant_conversations_user_updated
                ON assistant_conversations(user_id, updated_at DESC);

            CREATE TABLE IF NOT EXISTS assistant_messages (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                conversation_id TEXT NOT NULL,
                user_id TEXT NOT NULL,
                agent_id TEXT NOT NULL,
                role TEXT NOT NULL,
                content TEXT NOT NULL,
                created_at REAL NOT NULL,
                client_msg_id TEXT,
                FOREIGN KEY(conversation_id) REFERENCES assistant_conversations(id)
            );
            CREATE INDEX IF NOT EXISTS idx_assistant_messages_conv_id
                ON assistant_messages(conversation_id, id DESC);
            CREATE INDEX IF NOT EXISTS idx_assistant_messages_user_id
                ON assistant_messages(user_id, created_at DESC);
            """
        )


def _now_ts() -> float:
    return time.time()


def _get_or_create_conversation_id(user_id: str, agent_id: str, title: str | None = None) -> str:
    user_id = (user_id or "").strip()
    agent_id = (agent_id or "").strip()
    if not user_id or not agent_id:
        raise ValueError("user_id/agent_id required")
    with _assistant_db() as c:
        row = c.execute(
            "SELECT id FROM assistant_conversations WHERE user_id = ? AND agent_id = ?",
            (user_id, agent_id),
        ).fetchone()
        if row:
            return row["id"]
        cid = "conv_" + uuid4().hex[:16]
        now = _now_ts()
        c.execute(
            """INSERT INTO assistant_conversations
               (id, user_id, agent_id, title, created_at, updated_at, last_message_at)
               VALUES (?,?,?,?,?,?,?)""",
            (
                cid,
                user_id,
                agent_id,
                (title or "").strip() or None,
                now,
                now,
                None,
            ),
        )
        return cid


def _append_message(conversation_id: str, user_id: str, agent_id: str, role: str, content: str, client_msg_id: str | None = None) -> int:
    role = (role or "user").strip().lower()
    if role not in ("user", "assistant", "system"):
        role = "user"
    content = _normalize_message_content(content)
    if not content:
        return 0
    now = _now_ts()
    with _assistant_db() as c:
        # 简单幂等：同一会话若 client_msg_id 相同则不重复插入
        if client_msg_id:
            exist = c.execute(
                """SELECT id FROM assistant_messages
                   WHERE conversation_id = ? AND client_msg_id = ?""",
                (conversation_id, client_msg_id),
            ).fetchone()
            if exist:
                return int(exist["id"])
        cur = c.execute(
            """INSERT INTO assistant_messages
               (conversation_id, user_id, agent_id, role, content, created_at, client_msg_id)
               VALUES (?,?,?,?,?,?,?)""",
            (conversation_id, user_id, agent_id, role, content, now, (client_msg_id or "").strip() or None),
        )
        c.execute(
            """UPDATE assistant_conversations
               SET updated_at = ?, last_message_at = ?
               WHERE id = ?""",
            (now, now, conversation_id),
        )
        return int(cur.lastrowid or 0)


def _maybe_migrate_legacy_assistant_history(user_id: str, agent_id: str, conversation_id: str) -> int:
    """
    兼容旧版本：历史对话可能只存在于 user_data['assistant']（同步包）中，而方案 B 新表为空。
    当会话表存在但消息表为空时，把旧 history 导入 assistant_messages，确保聊天页一打开就能看到历史。
    返回导入条数。
    """
    user_id = (user_id or "").strip()
    agent_id = (agent_id or "").strip()
    conversation_id = (conversation_id or "").strip()
    if not user_id or not agent_id or not conversation_id:
        return 0
    with _assistant_db() as c:
        cnt = c.execute(
            "SELECT COUNT(1) AS c FROM assistant_messages WHERE conversation_id = ?",
            (conversation_id,),
        ).fetchone()
        if cnt and int(cnt["c"] or 0) > 0:
            return 0
    try:
        legacy_raw = _auth.get_user_data(user_id, "assistant")
        if not legacy_raw:
            return 0
        legacy = json.loads(legacy_raw) if isinstance(legacy_raw, str) else legacy_raw
        if not isinstance(legacy, dict):
            return 0
        msg_map = legacy.get("messages")
        if not isinstance(msg_map, dict):
            return 0
        # 旧格式：messages 以 agent_id 为 key
        legacy_list = msg_map.get(agent_id)
        if not isinstance(legacy_list, list) or not legacy_list:
            return 0
        imported = 0
        base = _now_ts() - max(0, len(legacy_list)) * 0.001
        with _assistant_db() as c:
            for i, m in enumerate(legacy_list):
                if not isinstance(m, dict):
                    continue
                role = (m.get("role") or "user").strip().lower()
                if role not in ("user", "assistant", "system"):
                    role = "user"
                content = _normalize_message_content(m.get("content"))
                if not content:
                    continue
                created_at = None
                ts_raw = (m.get("timestamp") or "").strip() if isinstance(m.get("timestamp"), str) else None
                if ts_raw:
                    try:
                        dt = datetime.fromisoformat(ts_raw.replace("Z", "+00:00"))
                        created_at = dt.timestamp()
                    except Exception:
                        created_at = None
                if created_at is None:
                    created_at = base + i * 0.001
                c.execute(
                    """INSERT INTO assistant_messages
                       (conversation_id, user_id, agent_id, role, content, created_at, client_msg_id)
                       VALUES (?,?,?,?,?,?,NULL)""",
                    (conversation_id, user_id, agent_id, role, content, float(created_at)),
                )
                imported += 1
            if imported > 0:
                now = _now_ts()
                c.execute(
                    "UPDATE assistant_conversations SET updated_at = ?, last_message_at = ? WHERE id = ?",
                    (now, now, conversation_id),
                )
        return imported
    except Exception as e:
        logger.warning("迁移旧 assistant 历史失败: %s", e)
        return 0


_init_assistant_chat_db()

_GEO_CACHE: dict[str, tuple[float, str]] = {}
_ADMIN_SESSIONS: dict[str, float] = {}
_ADMIN_COOKIE_NAME = "hibi_admin_session"
_ADMIN_SESSION_TTL_SECONDS = 60 * 60 * 12  # 12 小时
_CAPTCHA_CHALLENGES: dict[str, dict] = {}
_CAPTCHA_TTL_SECONDS = 5 * 60  # 图形认证挑战 5 分钟有效
_CAPTCHA_SDK_FILE = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "static",
    "ct4.js",
)


def _load_ct4_js_text_for_inline() -> Optional[str]:
    """
    读取与 /api/auth/captcha/sdk.js 相同的 ct4 正文，供 embed 页内联。
    WebView2 下二次请求 sdk.js 可能长时间挂起（既不 onload 也不 onerror），
    内联后可一次响应完成初始化（与官方「先引入 ct4 再 initAlicom4」一致）。
    """
    if os.path.isfile(_CAPTCHA_SDK_FILE):
        try:
            with open(_CAPTCHA_SDK_FILE, "r", encoding="utf-8", errors="replace") as f:
                return f.read()
        except OSError:
            pass
    try:
        import hibi_ct4_fallback as _ct4_fb

        fb = _ct4_fb.get_ct4_js_bytes()
        if fb:
            return fb.decode("utf-8", errors="replace")
    except Exception:
        logger.exception("ct4 内联读取失败（hibi_ct4_fallback）")
    return None


def _escape_for_html_inline_script(js: str) -> str:
    """避免 </script> 截断 HTML 解析。"""
    return js.replace("</script>", "<\\/script>").replace("</SCRIPT>", "<\\/SCRIPT>")

_DOC_KEY_PRIVACY_TERMS = "privacy_terms"
# 项目助理（工具调用）System Prompt，后台可编辑；见 _resolve_abp_system_prompt
_DOC_KEY_ABP_SYSTEM_PROMPT = "abp_system_prompt"
# 登录/注册是否要求图形认证（后台可关）；见 _graph_captcha_enabled_for_auth
_DOC_KEY_GRAPH_CAPTCHA_ENABLED = "graph_captcha_enabled"
# App 升级推送：版本号、更新说明、各端安装包 URL（JSON，后台可编辑）
_DOC_KEY_APP_UPDATE_MANIFEST = "app_update_manifest"
# App 主题策略：默认主题 + 按北京时区周历每日至多一个主题（与客户端 AppThemeId 一致）
_DOC_KEY_THEME_POLICY = "theme_policy"
_TZ_BEIJING = ZoneInfo("Asia/Shanghai")
# 与客户端 AppThemeId 一致；顺序用于后台列表展示
_THEME_CATALOG_ORDER = (
    "hibi",
    "dark",
    "light",
    "2027ss",
    "dreamy",
    "dreamy_night",
    "cyberpunk",
    "astral",
    "astral_phantasm",
    "earthrealm",
)
_THEME_IDS_ALLOWED = frozenset(_THEME_CATALOG_ORDER)
_THEME_DISPLAY_NAMES = {
    "hibi": "hibi主题",
    "dark": "暗色主题",
    "light": "亮色主题",
    "2027ss": "2027SS",
    "dreamy": "梦幻",
    "dreamy_night": "梦幻·夜",
    "cyberpunk": "CyberPunk",
    "astral": "星界",
    "astral_phantasm": "星界·幻",
    "earthrealm": "地界",
    # token 驱动的新主题（第二阶段）：不再绑定内置 ThemeData
    "light_pro": "亮色 Pro",
}
_THEME_WEEKDAY_LABELS_CN = {
    "mon": "周一",
    "tue": "周二",
    "wed": "周三",
    "thu": "周四",
    "fri": "周五",
    "sat": "周六",
    "sun": "周日",
}
_THEME_WEEKDAY_KEYS = ("mon", "tue", "wed", "thu", "fri", "sat", "sun")
_THEME_STYLE_CODE_MAX_LEN = 50000
_THEME_CUSTOM_NAME_MAX_LEN = 40
_THEME_CUSTOM_DESC_MAX_LEN = 200
_THEME_CUSTOM_ID_MAX_LEN = 60
_THEME_CALENDAR_MAX_EXPAND_DAYS = 1100  # 约 3 年，避免误配超大区间导致 CPU 爆炸


def _safe_custom_theme_id(v: str) -> str:
    s = (v or "").strip().lower()
    if not s:
        s = uuid4().hex[:12]
    allowed = []
    for ch in s:
        if ch.isalnum() or ch in ("_", "-"):
            allowed.append(ch)
        else:
            allowed.append("_")
    out = "".join(allowed).strip("_")
    if not out:
        out = uuid4().hex[:12]
    if not out.startswith("custom_"):
        out = "custom_" + out
    return out[:_THEME_CUSTOM_ID_MAX_LEN]


def _iter_dates_inclusive(start_date: str, end_date: str):
    """yield YYYY-MM-DD inclusive; assumes inputs valid."""
    y1, m1, d1 = int(start_date[:4]), int(start_date[5:7]), int(start_date[8:10])
    y2, m2, d2 = int(end_date[:4]), int(end_date[5:7]), int(end_date[8:10])
    cur = datetime(y1, m1, d1)
    end = datetime(y2, m2, d2)
    days = 0
    while cur <= end:
        yield cur.strftime("%Y-%m-%d")
        cur = cur + timedelta(days=1)
        days += 1
        if days > _THEME_CALENDAR_MAX_EXPAND_DAYS:
            break
_APP_PACKAGE_UPLOAD_DIR = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "uploads",
    "app_packages",
)
_APP_PACKAGE_MAX_BYTES = 350 * 1024 * 1024  # 350MB，避免误传大文件撑爆磁盘
_DEFAULT_PRIVACY_TERMS = """希比（HIBI）隐私条款

更新时间：2026-03-03

欢迎使用希比（HIBI）。我们重视并保护你的个人信息与数据安全。本条款用于说明我们如何收集、使用、存储和保护你的信息，以及你享有的相关权利。

一、我们收集的信息
1）账号信息：你注册或登录时提交的手机号/邮箱、昵称、头像等信息。
2）业务数据：你在应用内产生的思维节点、日程、助理对话历史等内容。
3）设备与日志信息：为保障服务安全与稳定，我们会记录必要的访问日志，如登录时间、IP、设备基础信息等。
4）支付相关信息：当你购买订阅服务时，我们会处理订单号、支付状态、套餐信息；银行卡等敏感支付信息由支付平台处理，我们不会直接保存完整支付凭据。

二、信息使用目的
1）提供账号登录、身份校验和基础功能服务。
2）在你开通对应订阅后提供云同步、助理能力、主题能力等增值服务。
3）保障服务稳定运行，进行故障排查、反作弊和安全防护。
4）优化产品体验与功能迭代（以统计分析形式进行，不用于非法用途）。

三、数据存储与同步
1）未开通数据服务时，思维节点、日程、助理历史主要保存在你的本地设备。
2）开通数据服务或大会员后，上述数据可按产品逻辑同步至云端并在多端使用。
3）我们采取合理安全措施保护数据，但你也应妥善保管账号与设备。

四、信息共享与披露
1）除法律法规要求或经你明确授权外，我们不会向无关第三方出售你的个人信息。
2）为完成支付、云服务、短信认证等必要能力，可能与合规服务商协作，且仅在实现业务所需范围内进行。

五、你的权利
你有权查询、更正、删除你的相关信息，并可通过注销账户停止继续使用相关服务。
如你对隐私条款或数据处理有疑问，可通过应用内或官方渠道联系我们。

六、未成年人保护
若你是未成年人，请在监护人指导下阅读并使用本服务。

七、条款更新
我们可能根据法律法规、业务调整或产品升级对本条款进行更新。更新后版本将在应用内展示并注明更新时间。
"""


def _bearer_user_id(request: Request) -> str | None:
    auth = request.headers.get("Authorization") or ""
    if auth.startswith("Bearer "):
        return _auth.get_user_id_from_token(auth[7:].strip())
    return None


def _extract_client_ip(request: Request) -> str:
    xff = (request.headers.get("x-forwarded-for") or "").strip()
    if xff:
        return xff.split(",")[0].strip()
    xr = (request.headers.get("x-real-ip") or "").strip()
    if xr:
        return xr
    return (request.client.host if request.client else "") or ""


async def _lookup_ip_geo(ip: str) -> str:
    ip = (ip or "").strip()
    if not ip:
        return ""
    if ip.startswith("127.") or ip == "::1" or ip.startswith("192.168.") or ip.startswith("10.") or ip.startswith("172."):
        return "局域网/本机"
    now = time.time()
    cached = _GEO_CACHE.get(ip)
    if cached and now - cached[0] < 24 * 3600:
        return cached[1]
    geo = ""
    try:
        url = f"http://ip-api.com/json/{ip}?lang=zh-CN"
        async with httpx.AsyncClient(timeout=2.5) as client:
            r = await client.get(url)
        if r.status_code == 200:
            d = r.json()
            if d.get("status") == "success":
                parts = [d.get("country"), d.get("regionName"), d.get("city"), d.get("isp")]
                geo = " / ".join([str(p).strip() for p in parts if p])
    except Exception:
        geo = ""
    _GEO_CACHE[ip] = (now, geo)
    return geo


def _admin_token_from_request(request: Request) -> str:
    return (
        (request.headers.get("x-admin-token") or "").strip()
        or (request.query_params.get("token") or "").strip()
        or (request.headers.get("authorization") or "").replace("Bearer ", "").strip()
    )


def _admin_password() -> str:
    # 按用户要求默认密码为 tsinghibi；可在 ECS .env 用 ADMIN_DASH_PASSWORD 覆盖。
    return (os.getenv("ADMIN_DASH_PASSWORD") or "tsinghibi").strip()


def _cleanup_admin_sessions(now: Optional[float] = None):
    now = now or time.time()
    expired = [k for k, v in _ADMIN_SESSIONS.items() if v <= now]
    for k in expired:
        _ADMIN_SESSIONS.pop(k, None)


def _create_admin_session() -> str:
    token = secrets.token_urlsafe(32)
    now = time.time()
    _cleanup_admin_sessions(now)
    _ADMIN_SESSIONS[token] = now + _ADMIN_SESSION_TTL_SECONDS
    return token


def _is_admin_session_valid(token: str) -> bool:
    if not token:
        return False
    now = time.time()
    _cleanup_admin_sessions(now)
    exp = _ADMIN_SESSIONS.get(token)
    return bool(exp and exp > now)


def _admin_session_token(request: Request) -> str:
    return (request.cookies.get(_ADMIN_COOKIE_NAME) or "").strip()


def _is_admin_request(request: Request) -> bool:
    if _is_admin_session_valid(_admin_session_token(request)):
        return True
    configured = (os.getenv("ADMIN_DASH_TOKEN") or "").strip()
    if not configured:
        return False
    return secrets.compare_digest(_admin_token_from_request(request), configured)


def _legal_db():
    conn = sqlite3.connect(_auth.DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def _init_legal_db():
    with _legal_db() as c:
        c.execute(
            """CREATE TABLE IF NOT EXISTS legal_documents (
                   doc_key TEXT PRIMARY KEY,
                   content TEXT NOT NULL,
                   updated_at REAL NOT NULL,
                   updated_by TEXT
               )"""
        )


def _ensure_default_privacy_terms():
    with _legal_db() as c:
        row = c.execute(
            "SELECT doc_key FROM legal_documents WHERE doc_key = ?",
            (_DOC_KEY_PRIVACY_TERMS,),
        ).fetchone()
        if row:
            return
        c.execute(
            "INSERT INTO legal_documents (doc_key, content, updated_at, updated_by) VALUES (?,?,?,?)",
            (_DOC_KEY_PRIVACY_TERMS, _DEFAULT_PRIVACY_TERMS, time.time(), "system_default"),
        )


def _get_legal_doc(doc_key: str) -> dict:
    with _legal_db() as c:
        row = c.execute(
            "SELECT doc_key, content, updated_at, updated_by FROM legal_documents WHERE doc_key = ?",
            (doc_key,),
        ).fetchone()
    if not row:
        return {
            "doc_key": doc_key,
            "content": "",
            "updated_at": 0,
            "updated_by": "",
        }
    return {
        "doc_key": row["doc_key"],
        "content": row["content"] or "",
        "updated_at": row["updated_at"] or 0,
        "updated_by": row["updated_by"] or "",
    }


def _save_legal_doc(doc_key: str, content: str, updated_by: str = "admin") -> dict:
    now = time.time()
    text = (content or "").strip()
    with _legal_db() as c:
        c.execute(
            """INSERT INTO legal_documents (doc_key, content, updated_at, updated_by)
               VALUES (?,?,?,?)
               ON CONFLICT(doc_key) DO UPDATE SET
                 content = excluded.content,
                 updated_at = excluded.updated_at,
                 updated_by = excluded.updated_by""",
            (doc_key, text, now, (updated_by or "").strip() or "admin"),
        )
    return _get_legal_doc(doc_key)


def _ensure_default_abp_system_prompt():
    """首次部署时在库中写入项目助理默认 System Prompt（与 hibi_abp_tools.DEFAULT_SYSTEM_PROMPT 一致）。"""
    import hibi_abp_tools as _abp

    with _legal_db() as c:
        row = c.execute(
            "SELECT doc_key FROM legal_documents WHERE doc_key = ?",
            (_DOC_KEY_ABP_SYSTEM_PROMPT,),
        ).fetchone()
        if row:
            return
        c.execute(
            "INSERT INTO legal_documents (doc_key, content, updated_at, updated_by) VALUES (?,?,?,?)",
            (_DOC_KEY_ABP_SYSTEM_PROMPT, _abp.DEFAULT_SYSTEM_PROMPT, time.time(), "system_default"),
        )


def _resolve_abp_system_prompt() -> str:
    """项目助理 system prompt：环境变量文件（若存在且非空）→ 后台管理写入的 SQLite → 代码默认。"""
    path = os.getenv("HIBI_ABP_SYSTEM_PROMPT_FILE", "").strip()
    if path and os.path.isfile(path):
        try:
            with open(path, encoding="utf-8") as f:
                t = f.read().strip()
            if t:
                return t
        except Exception as e:
            logger.warning("读取 HIBI_ABP_SYSTEM_PROMPT_FILE 失败: %s，改用库内或默认", e)
    import hibi_abp_tools as _abp

    doc = _get_legal_doc(_DOC_KEY_ABP_SYSTEM_PROMPT)
    c = (doc.get("content") or "").strip()
    if c:
        return c
    return _abp.DEFAULT_SYSTEM_PROMPT


def _ensure_default_graph_captcha_enabled():
    """默认开启图形认证（与历史行为一致）。"""
    with _legal_db() as c:
        row = c.execute(
            "SELECT doc_key FROM legal_documents WHERE doc_key = ?",
            (_DOC_KEY_GRAPH_CAPTCHA_ENABLED,),
        ).fetchone()
        if row:
            return
        c.execute(
            "INSERT INTO legal_documents (doc_key, content, updated_at, updated_by) VALUES (?,?,?,?)",
            (_DOC_KEY_GRAPH_CAPTCHA_ENABLED, "true", time.time(), "system_default"),
        )


def _graph_captcha_enabled_for_auth() -> bool:
    """False 时登录/注册不校验图形认证；configured 对客户端也为 false。"""
    doc = _get_legal_doc(_DOC_KEY_GRAPH_CAPTCHA_ENABLED)
    raw = (doc.get("content") or "").strip().lower()
    if not raw:
        return True
    if raw in ("false", "0", "no", "off"):
        return False
    if raw in ("true", "1", "yes", "on"):
        return True
    try:
        j = json.loads(doc.get("content") or "{}")
        if isinstance(j, dict):
            return bool(j.get("enabled", True))
    except Exception:
        pass
    return True


def _default_app_update_manifest_dict() -> dict:
    return {
        "latest_version": "",
        "release_notes": "",
        "urls": {"windows": "", "ios": "", "android": "", "linux": ""},
    }


def _safe_filename(name: str) -> str:
    name = (name or "").strip()
    if not name:
        return "file"
    # 仅保留基础文件名，去路径；并替换危险字符
    name = os.path.basename(name).replace("\\", "_").replace("/", "_")
    cleaned = []
    for ch in name:
        if ch.isalnum() or ch in ("-", "_", ".", "(", ")", " "):
            cleaned.append(ch)
        else:
            cleaned.append("_")
    out = "".join(cleaned).strip().strip(".")
    return out or "file"


def _ext_lower(name: str) -> str:
    n = (name or "").lower()
    # 兼容 .tar.gz
    if n.endswith(".tar.gz"):
        return ".tar.gz"
    return os.path.splitext(n)[1]


def _allowed_package_ext(platform: str) -> set[str]:
    p = (platform or "").strip().lower()
    if p == "android":
        return {".apk", ".aab"}
    if p == "windows":
        return {".exe", ".msi", ".zip"}
    if p == "linux":
        return {".appimage", ".deb", ".rpm", ".tar.gz", ".zip"}
    if p == "ios":
        # iOS 通常不上传 ipa（App Store/TestFlight），保留扩展位以防企业内测。
        return {".ipa", ".plist", ".zip"}
    return {".apk", ".aab", ".exe", ".msi", ".zip", ".appimage", ".deb", ".rpm", ".tar.gz", ".ipa", ".plist"}


def _ensure_upload_dir() -> None:
    try:
        os.makedirs(_APP_PACKAGE_UPLOAD_DIR, exist_ok=True)
    except Exception as e:
        raise RuntimeError(f"无法创建上传目录：{_APP_PACKAGE_UPLOAD_DIR} ({e})")


def _build_public_download_url(request: Request, filename: str) -> str:
    base = str(request.base_url).rstrip("/")
    return f"{base}/api/app/packages/{urllib.parse.quote(filename)}"


async def _save_upload_file(file: UploadFile, dst_path: str) -> int:
    total = 0
    with open(dst_path, "wb") as f:
        while True:
            chunk = await file.read(1024 * 1024)
            if not chunk:
                break
            total += len(chunk)
            if total > _APP_PACKAGE_MAX_BYTES:
                raise ValueError(f"文件过大（>{_APP_PACKAGE_MAX_BYTES // (1024*1024)}MB），请确认选择的是安装包")
            f.write(chunk)
    return total


def _normalize_app_update_manifest(raw: dict) -> dict:
    base = _default_app_update_manifest_dict()
    if not isinstance(raw, dict):
        return base
    lv = raw.get("latest_version")
    base["latest_version"] = str(lv).strip() if lv is not None else ""
    rn = raw.get("release_notes")
    base["release_notes"] = str(rn) if rn is not None else ""
    urls = raw.get("urls")
    if isinstance(urls, dict):
        for k in ("windows", "ios", "android", "linux"):
            v = urls.get(k)
            base["urls"][k] = str(v).strip() if v is not None else ""
    return base


def get_app_update_manifest_dict() -> dict:
    """当前升级配置（供公开接口与后台）。"""
    doc = _get_legal_doc(_DOC_KEY_APP_UPDATE_MANIFEST)
    raw_txt = (doc.get("content") or "").strip()
    try:
        raw = json.loads(raw_txt) if raw_txt else {}
    except Exception:
        raw = {}
    m = _normalize_app_update_manifest(raw if isinstance(raw, dict) else {})
    m["updated_at"] = float(doc.get("updated_at") or 0)
    return m


def _default_theme_meta() -> dict:
    return {tid: {"hidden": False, "style_code": ""} for tid in _THEME_IDS_ALLOWED}


def _normalize_theme_meta(raw) -> dict:
    base = _default_theme_meta()
    if not isinstance(raw, dict):
        return base
    for tid in _THEME_IDS_ALLOWED:
        m = raw.get(tid)
        if not isinstance(m, dict):
            continue
        sc = str(m.get("style_code") or "")
        if len(sc) > _THEME_STYLE_CODE_MAX_LEN:
            sc = sc[:_THEME_STYLE_CODE_MAX_LEN]
        base[tid] = {
            "hidden": bool(m.get("hidden")),
            "style_code": sc,
        }
    return base


def _normalize_custom_themes(raw) -> list:
    if not isinstance(raw, list):
        return []
    out = []
    seen = set()
    for item in raw:
        if not isinstance(item, dict):
            continue
        cid = _safe_custom_theme_id(str(item.get("id") or ""))
        if cid in seen:
            continue
        seen.add(cid)
        name = str(item.get("name") or "").strip()[:_THEME_CUSTOM_NAME_MAX_LEN]
        desc = str(item.get("description") or "").strip()[:_THEME_CUSTOM_DESC_MAX_LEN]
        bind = _normalize_theme_id(item.get("bind_theme_id"))
        sc = str(item.get("style_code") or "")
        if len(sc) > _THEME_STYLE_CODE_MAX_LEN:
            sc = sc[:_THEME_STYLE_CODE_MAX_LEN]
        out.append(
            {
                "id": cid,
                "name": name or cid,
                "description": desc,
                "bind_theme_id": bind,  # 可为空（仅存档）
                "enabled": bool(item.get("enabled", True)),
                "hidden": bool(item.get("hidden", False)),
                "style_code": sc,
            }
        )
    return out


def _default_theme_policy_dict() -> dict:
    return {
        "default_theme_id": "astral",
        "weekly": {k: None for k in _THEME_WEEKDAY_KEYS},
        "theme_meta": _default_theme_meta(),
        "custom_themes": [
            {
                "id": "custom_light_pro",
                "name": "亮色 Pro",
                "description": "2026 现代亮色风格（token 驱动，示例主题）",
                "bind_theme_id": None,
                "enabled": True,
                "hidden": False,
                "style_code": json.dumps(
                    {
                        "name": "Light Pro 2026",
                        "mode": "light",
                        "colors": {
                            "primary": "#2563EB",
                            "secondary": "#14B8A6",
                            "background": "#F6F7FB",
                            "surface": "#FFFFFF",
                            "surfaceAlt": "#F1F3FA",
                            "outline": "#1A111827",
                            "onBackground": "#0F172A",
                            "onSurface": "#111827",
                            "onSurfaceVariant": "#475569",
                            "success": "#16A34A",
                            "warning": "#F59E0B",
                            "error": "#DC2626",
                        },
                        "shape": {"radiusSm": 12, "radiusMd": 16, "radiusLg": 22},
                        "typography": {"baseSize": 14, "titleScale": 1.06},
                        "effects": {"elevation": 2, "cardOpacity": 0.78, "glassBlur": 12},
                    },
                    ensure_ascii=False,
                ),
            }
        ],
        # 日历排期（北京时间，按日不重叠）：[{date:"YYYY-MM-DD", theme_ref:"astral"|custom_id}]
        "calendar": [],
    }


def _normalize_theme_id(v) -> Optional[str]:
    if v is None:
        return None
    s = str(v).strip()
    if not s:
        return None
    if s not in _THEME_IDS_ALLOWED:
        return None
    return s


def _normalize_theme_policy(raw: dict) -> dict:
    base = _default_theme_policy_dict()
    if not isinstance(raw, dict):
        return base
    dft = _normalize_theme_id(raw.get("default_theme_id"))
    if dft:
        base["default_theme_id"] = dft
    base["theme_meta"] = _normalize_theme_meta(raw.get("theme_meta"))
    base["custom_themes"] = _normalize_custom_themes(raw.get("custom_themes"))
    # 默认主题不可隐藏（否则客户端无兜底）
    base["theme_meta"][base["default_theme_id"]]["hidden"] = False
    wk = raw.get("weekly")
    if isinstance(wk, dict):
        for k in _THEME_WEEKDAY_KEYS:
            tid = _normalize_theme_id(wk.get(k))
            base["weekly"][k] = tid
    # 日历排期（支持区间）：先按天展开去重（后写覆盖先写），再合并回区间
    cal = raw.get("calendar")
    day_map: dict[str, dict] = {}
    if isinstance(cal, list):
        for it in cal:
            if not isinstance(it, dict):
                continue
            sid = (str(it.get("id") or "")).strip()[:48] or f"cal_{uuid4().hex[:12]}"
            sd = str(it.get("start_date") or it.get("date") or "").strip()
            ed = str(it.get("end_date") or sd).strip()
            # 仅接受 YYYY-MM-DD
            for ds in (sd, ed):
                if not ds or len(ds) != 10 or ds[4] != "-" or ds[7] != "-":
                    sd = ""
                    break
            if not sd:
                continue
            y1, m1, d1 = sd[:4], sd[5:7], sd[8:10]
            y2, m2, d2 = ed[:4], ed[5:7], ed[8:10]
            if not (y1.isdigit() and m1.isdigit() and d1.isdigit() and y2.isdigit() and m2.isdigit() and d2.isdigit()):
                continue
            try:
                datetime(int(y1), int(m1), int(d1))
                datetime(int(y2), int(m2), int(d2))
            except Exception:
                continue
            if ed < sd:
                sd, ed = ed, sd
            ref = str(it.get("theme_ref") or "").strip()
            if not ref:
                continue
            apply_id = _resolve_apply_theme_id(base, ref)
            for ds in _iter_dates_inclusive(sd, ed):
                day_map[ds] = {
                    "id": sid,
                    "start_date": sd,
                    "end_date": ed,
                    "theme_ref": ref,
                    "apply_theme_id": apply_id,
                }
    # 合并连续日期为区间（同 theme_ref/apply_theme_id）
    merged = []
    if day_map:
        days = sorted(day_map.keys())
        cur = None
        for ds in days:
            it = day_map[ds]
            if cur is None:
                cur = {**it, "start_date": ds, "end_date": ds}
                continue
            same = (
                it.get("theme_ref") == cur.get("theme_ref")
                and it.get("apply_theme_id") == cur.get("apply_theme_id")
            )
            prev_end = cur["end_date"]
            # 判断是否连续
            py, pm, pd = int(prev_end[:4]), int(prev_end[5:7]), int(prev_end[8:10])
            ny, nm, nd = int(ds[:4]), int(ds[5:7]), int(ds[8:10])
            cont = datetime(ny, nm, nd) == (datetime(py, pm, pd) + timedelta(days=1))
            if same and cont:
                cur["end_date"] = ds
            else:
                merged.append(cur)
                cur = {**it, "start_date": ds, "end_date": ds}
        if cur is not None:
            merged.append(cur)
    base["calendar"] = merged
    return base


def _build_theme_rows(pol: dict) -> list:
    weekly = pol.get("weekly") or {}
    default_id = pol.get("default_theme_id") or "astral"
    meta = pol.get("theme_meta") or {}
    customs = pol.get("custom_themes") or []
    push_map: dict[str, list] = {tid: [] for tid in _THEME_CATALOG_ORDER}
    for day in _THEME_WEEKDAY_KEYS:
        tid = weekly.get(day)
        if tid in push_map:
            push_map[tid].append(day)
    # 日历排期摘要：按 apply_theme_id / theme_ref 归档区间
    cal = pol.get("calendar") or []
    cal_by_apply: dict[str, list] = {tid: [] for tid in _THEME_CATALOG_ORDER}
    cal_by_ref: dict[str, list] = {}
    if isinstance(cal, list):
        for it in cal:
            if not isinstance(it, dict):
                continue
            sd = str(it.get("start_date") or "").strip()
            ed = str(it.get("end_date") or sd).strip()
            ref = str(it.get("theme_ref") or "").strip()
            apply_id = _normalize_theme_id(it.get("apply_theme_id"))
            rng = f"{sd}~{ed}" if sd and ed else ""
            if apply_id and rng:
                cal_by_apply.setdefault(apply_id, []).append(rng)
            if ref and rng:
                cal_by_ref.setdefault(ref, []).append(rng)

    out = []
    for tid in _THEME_CATALOG_ORDER:
        tm = meta.get(tid) if isinstance(meta.get(tid), dict) else {}
        hidden = bool(tm.get("hidden"))
        style_code = str(tm.get("style_code") or "")
        days = push_map.get(tid) or []
        labels = [_THEME_WEEKDAY_LABELS_CN[d] for d in days if d in _THEME_WEEKDAY_LABELS_CN]
        cal_ranges = cal_by_apply.get(tid) or []
        out.append(
            {
                "theme_id": tid,
                "display_name": _THEME_DISPLAY_NAMES.get(tid, tid),
                "push_weekdays": days,
                "push_summary": "、".join(labels) if labels else "未排期",
                "calendar_ranges": cal_ranges,
                "calendar_summary": f"{len(cal_ranges)}段" if cal_ranges else "无",
                "is_default": tid == default_id,
                "hidden": hidden,
                "style_code": style_code,
                "kind": "built_in",
            }
        )
    if isinstance(customs, list):
        for c in customs:
            if not isinstance(c, dict):
                continue
            cid = str(c.get("id") or "").strip()
            if not cid:
                continue
            bind = _normalize_theme_id(c.get("bind_theme_id"))
            days = push_map.get(bind) if bind else []
            labels = [_THEME_WEEKDAY_LABELS_CN[d] for d in (days or []) if d in _THEME_WEEKDAY_LABELS_CN]
            out.append(
                {
                    "theme_id": cid,
                    "display_name": str(c.get("name") or cid).strip()[:_THEME_CUSTOM_NAME_MAX_LEN] or cid,
                    "description": str(c.get("description") or "").strip()[:_THEME_CUSTOM_DESC_MAX_LEN],
                    "bind_theme_id": bind,
                    "push_weekdays": days or [],
                    "push_summary": ("、".join(labels) if labels else "未排期") if bind else "未绑定",
                    "calendar_ranges": cal_by_ref.get(cid) or [],
                    "calendar_summary": f"{len(cal_by_ref.get(cid) or [])}段" if (cal_by_ref.get(cid) or []) else "无",
                    "is_default": bool(bind) and bind == default_id,
                    "hidden": bool(c.get("hidden")),
                    "enabled": bool(c.get("enabled", True)),
                    "style_code": str(c.get("style_code") or ""),
                    "kind": "custom",
                }
            )
    return out


def _resolve_apply_theme_id(pol: dict, theme_ref: Optional[str]) -> Optional[str]:
    """将 theme_ref（内置 theme_id 或 custom_id）解析为客户端可应用的内置 theme_id。"""
    if not theme_ref:
        return None
    ref = str(theme_ref).strip()
    if ref in _THEME_IDS_ALLOWED:
        return ref
    customs = pol.get("custom_themes") or []
    if isinstance(customs, list):
        for c in customs:
            if not isinstance(c, dict):
                continue
            if str(c.get("id") or "").strip() != ref:
                continue
            if not bool(c.get("enabled", True)):
                return None
            bind = _normalize_theme_id(c.get("bind_theme_id"))
            return bind
    return None


def _resolve_style_code_for_ref(pol: dict, theme_ref: Optional[str], built_in_fallback: Optional[str]) -> str:
    """返回主题样式代码（JSON token/说明）。custom 优先取 custom.style_code；built-in 取 theme_meta.style_code。"""
    meta = pol.get("theme_meta") or {}
    ref = (theme_ref or "").strip()
    if ref in _THEME_IDS_ALLOWED:
        m = meta.get(ref) if isinstance(meta.get(ref), dict) else {}
        return str(m.get("style_code") or "")
    customs = pol.get("custom_themes") or []
    if isinstance(customs, list):
        for c in customs:
            if not isinstance(c, dict):
                continue
            if str(c.get("id") or "").strip() != ref:
                continue
            if not bool(c.get("enabled", True)):
                return ""
            return str(c.get("style_code") or "")
    fb = (built_in_fallback or "").strip()
    if fb in _THEME_IDS_ALLOWED:
        m = meta.get(fb) if isinstance(meta.get(fb), dict) else {}
        return str(m.get("style_code") or "")
    return ""


def _calendar_theme_ref_for_date(pol: dict, beijing_date: str) -> Optional[str]:
    cal = pol.get("calendar") or []
    if not isinstance(cal, list):
        return None
    for it in cal:
        if not isinstance(it, dict):
            continue
        sd = str(it.get("start_date") or "").strip()
        ed = str(it.get("end_date") or sd).strip()
        if sd and ed and sd <= beijing_date <= ed:
            return str(it.get("theme_ref") or "").strip() or None
    return None


def _calendar_apply_theme_id_for_date(pol: dict, beijing_date: str) -> Optional[str]:
    cal = pol.get("calendar") or []
    if not isinstance(cal, list):
        return None
    for it in cal:
        if not isinstance(it, dict):
            continue
        sd = str(it.get("start_date") or "").strip()
        ed = str(it.get("end_date") or sd).strip()
        if sd and ed and sd <= beijing_date <= ed:
            return _normalize_theme_id(it.get("apply_theme_id"))
    return None


def _compute_theme_policy_view(stored: dict, *, for_public: bool = False) -> dict:
    pol = _normalize_theme_policy(stored if isinstance(stored, dict) else {})
    now = datetime.now(_TZ_BEIJING)
    bj_date = now.strftime("%Y-%m-%d")
    wkey = _THEME_WEEKDAY_KEYS[now.weekday()]
    weekly = pol.get("weekly") or {}
    meta = pol.get("theme_meta") or {}
    default_id = pol.get("default_theme_id") or "astral"
    # 当日排期：日历日优先，其次周历；theme_ref 可为内置 theme_id 或 custom_id
    cal_ref = _calendar_theme_ref_for_date(pol, bj_date)
    cal_apply = _calendar_apply_theme_id_for_date(pol, bj_date)
    sched_ref = cal_ref or (weekly.get(wkey) if isinstance(weekly, dict) else None)
    sched_apply = cal_apply or _resolve_apply_theme_id(pol, sched_ref)
    effective_apply = sched_apply if sched_apply else default_id
    effective_ref = sched_ref or effective_apply
    view = {
        "default_theme_id": default_id,
        "weekly": {k: weekly.get(k) for k in _THEME_WEEKDAY_KEYS},
        "calendar": pol.get("calendar") or [],
        "beijing_date": bj_date,
        "beijing_weekday": wkey,
        "scheduled_theme_ref": sched_ref,
        "scheduled_apply_theme_id": sched_apply,
        # 兼容字段：客户端旧版本仍用该值应用内置主题
        "effective_theme_id": effective_apply,
        # 新字段：用于区分 custom / built-in
        "effective_theme_key": effective_ref,
    }
    if for_public:
        view["hidden_theme_ids"] = [
            tid for tid in _THEME_CATALOG_ORDER if (meta.get(tid) or {}).get("hidden")
        ]
        # 当前生效主题的样式代码（custom 则取 custom.style_code，built-in 取 theme_meta）
        view["effective_style_code"] = _resolve_style_code_for_ref(pol, effective_ref, effective_apply)
        # 公开：下发“可选主题目录”（内置 + 自定义且 enabled 且非 hidden；custom 支持无 bind 但需有 style_code）
        catalog = []
        # 内置主题：若被隐藏则不展示在设置页，但仍可被排期应用
        for tid in _THEME_CATALOG_ORDER:
            if (meta.get(tid) or {}).get("hidden"):
                continue
            catalog.append({"id": tid, "name": _THEME_DISPLAY_NAMES.get(tid, tid), "apply_theme_id": tid, "kind": "built_in"})
        customs = pol.get("custom_themes") or []
        if isinstance(customs, list):
            for c in customs:
                if not isinstance(c, dict):
                    continue
                if not bool(c.get("enabled", True)):
                    continue
                if bool(c.get("hidden", False)):
                    continue
                cid = str(c.get("id") or "").strip()
                if not cid:
                    continue
                bind = _normalize_theme_id(c.get("bind_theme_id"))
                sc = str(c.get("style_code") or "")
                if not bind and not sc.strip():
                    continue
                catalog.append(
                    {
                        "id": cid,
                        "name": str(c.get("name") or cid).strip()[:_THEME_CUSTOM_NAME_MAX_LEN] or cid,
                        "apply_theme_id": bind or "",
                        "style_code": sc,
                        "kind": "custom",
                    }
                )
        view["theme_catalog"] = catalog
    else:
        view["themes"] = _build_theme_rows(pol)
        view["theme_meta"] = pol.get("theme_meta") or _default_theme_meta()
        view["custom_themes"] = pol.get("custom_themes") or []
    return view


def get_theme_policy_dict(*, for_public: bool = False) -> dict:
    doc = _get_legal_doc(_DOC_KEY_THEME_POLICY)
    raw_txt = (doc.get("content") or "").strip()
    try:
        raw = json.loads(raw_txt) if raw_txt else {}
    except Exception:
        raw = {}
    view = _compute_theme_policy_view(raw if isinstance(raw, dict) else {}, for_public=for_public)
    view["updated_at"] = float(doc.get("updated_at") or 0)
    return view


def _ensure_default_theme_policy():
    with _legal_db() as c:
        row = c.execute(
            "SELECT doc_key FROM legal_documents WHERE doc_key = ?",
            (_DOC_KEY_THEME_POLICY,),
        ).fetchone()
        if row:
            return
        c.execute(
            "INSERT INTO legal_documents (doc_key, content, updated_at, updated_by) VALUES (?,?,?,?)",
            (
                _DOC_KEY_THEME_POLICY,
                json.dumps(_default_theme_policy_dict(), ensure_ascii=False),
                time.time(),
                "system_default",
            ),
        )


def _ensure_default_app_update_manifest():
    with _legal_db() as c:
        row = c.execute(
            "SELECT doc_key FROM legal_documents WHERE doc_key = ?",
            (_DOC_KEY_APP_UPDATE_MANIFEST,),
        ).fetchone()
        if row:
            return
        c.execute(
            "INSERT INTO legal_documents (doc_key, content, updated_at, updated_by) VALUES (?,?,?,?)",
            (
                _DOC_KEY_APP_UPDATE_MANIFEST,
                json.dumps(_default_app_update_manifest_dict(), ensure_ascii=False),
                time.time(),
                "system_default",
            ),
        )


_init_legal_db()
_ensure_default_privacy_terms()
_ensure_default_abp_system_prompt()
_ensure_default_graph_captcha_enabled()
_ensure_default_app_update_manifest()
_ensure_default_theme_policy()


def _cleanup_captcha_challenges(now: Optional[float] = None):
    now = now or time.time()
    expired = [k for k, v in _CAPTCHA_CHALLENGES.items() if float(v.get("expire_at") or 0) <= now]
    for k in expired:
        _CAPTCHA_CHALLENGES.pop(k, None)


def _new_captcha_challenge(platform: str) -> str:
    now = time.time()
    _cleanup_captcha_challenges(now)
    cid = secrets.token_urlsafe(24)
    _CAPTCHA_CHALLENGES[cid] = {
        "platform": platform,
        "created_at": now,
        "expire_at": now + _CAPTCHA_TTL_SECONDS,
        "verified": False,
        "used": False,
    }
    return cid


def _mark_captcha_verified(challenge_id: str):
    item = _CAPTCHA_CHALLENGES.get(challenge_id)
    if not item:
        return
    item["verified"] = True
    # 验证通过后保留短时间供登录/注册提交消费
    item["expire_at"] = max(float(item.get("expire_at") or 0), time.time() + 120)


def _consume_verified_challenge(challenge_id: str, platform: str) -> tuple[bool, str]:
    _cleanup_captcha_challenges()
    item = _CAPTCHA_CHALLENGES.get(challenge_id)
    if not item:
        return False, "图形认证状态不存在或已过期"
    if item.get("used"):
        return False, "图形认证状态已使用"
    if str(item.get("platform") or "") != platform:
        return False, "图形认证平台不匹配"
    if not item.get("verified"):
        return False, "请先完成图形认证"
    item["used"] = True
    return True, ""


@app.post("/api/auth/register")
async def api_auth_register(request: Request):
    """注册：图形认证通过后即可注册（邀请码已关闭强制校验）。"""
    try:
        data = await request.json()
        captcha_platform = (data.get("captcha_platform") or data.get("captchaPlatform") or "web").strip()
        if _graph_captcha_enabled_for_auth() and _graph_captcha.is_configured(captcha_platform):
            challenge_id = (data.get("captcha_challenge_id") or data.get("captchaChallengeId") or "").strip()
            if challenge_id:
                ok, reason = _consume_verified_challenge(challenge_id, captcha_platform)
            else:
                ok, reason = _graph_captcha.verify(data, platform=captcha_platform)
            if not ok:
                return JSONResponse({"message": reason or "请先通过图形认证"}, status_code=400)
        phone = (data.get("phone_or_email") or data.get("phoneOrEmail") or "").strip()
        password = data.get("password") or ""
        nickname = (data.get("nickname") or "").strip() or None
        if not phone or not password:
            return JSONResponse({"message": "账号与密码必填"}, status_code=400)
        if len(password) < 6:
            return JSONResponse({"message": "密码至少 6 位"}, status_code=400)
        try:
            user_id = _auth.create_user(phone, password, nickname)
        except sqlite3.IntegrityError:
            return JSONResponse({"message": "该账号已注册"}, status_code=400)
        token = _auth.create_session(user_id)
        ip = _extract_client_ip(request)
        geo = await _lookup_ip_geo(ip)
        _auth.touch_user_login_meta(user_id, ip=ip, geo=geo, set_created_if_empty=True)
        profile = _auth.get_user_profile(user_id)
        return JSONResponse({
            "token": token,
            "user_id": user_id,
            "phone_or_email": profile["phone_or_email"],
            "nickname": profile["nickname"],
        })
    except Exception as e:
        logger.exception("api_auth_register")
        return JSONResponse({"message": str(e)[:200]}, status_code=500)


@app.post("/api/auth/login")
async def api_auth_login(request: Request):
    try:
        data = await request.json()
        captcha_platform = (data.get("captcha_platform") or data.get("captchaPlatform") or "web").strip()
        if _graph_captcha_enabled_for_auth() and _graph_captcha.is_configured(captcha_platform):
            challenge_id = (data.get("captcha_challenge_id") or data.get("captchaChallengeId") or "").strip()
            if challenge_id:
                ok, reason = _consume_verified_challenge(challenge_id, captcha_platform)
            else:
                ok, reason = _graph_captcha.verify(data, platform=captcha_platform)
            if not ok:
                return JSONResponse({"message": reason or "请先通过图形认证"}, status_code=400)
        phone = (data.get("phone_or_email") or data.get("phoneOrEmail") or "").strip()
        password = data.get("password") or ""
        if not phone or not password:
            return JSONResponse({"message": "账号与密码必填"}, status_code=400)
        user_id = _auth.verify_user(phone, password)
        if not user_id:
            return JSONResponse({"message": "账号或密码错误"}, status_code=401)
        token = _auth.create_session(user_id)
        ip = _extract_client_ip(request)
        geo = await _lookup_ip_geo(ip)
        _auth.touch_user_login_meta(user_id, ip=ip, geo=geo, set_created_if_empty=False)
        profile = _auth.get_user_profile(user_id)
        return JSONResponse({
            "token": token,
            "user_id": user_id,
            "phone_or_email": profile["phone_or_email"],
            "nickname": profile["nickname"],
        })
    except Exception as e:
        logger.exception("api_auth_login")
        return JSONResponse({"message": str(e)[:200]}, status_code=500)


@app.post("/api/auth/logout")
async def api_auth_logout(request: Request):
    auth = request.headers.get("Authorization") or ""
    if auth.startswith("Bearer "):
        _auth.delete_session(auth[7:].strip())
    return JSONResponse({"ok": True})


@app.get("/api/auth/profile")
async def api_auth_profile(request: Request):
    user_id = _bearer_user_id(request)
    if not user_id:
        return JSONResponse({"message": "未登录"}, status_code=401)
    profile = _auth.get_user_profile(user_id)
    if not profile:
        return JSONResponse({"message": "用户不存在"}, status_code=404)
    return JSONResponse(profile)


@app.put("/api/auth/profile")
async def api_auth_update_profile(request: Request):
    user_id = _bearer_user_id(request)
    if not user_id:
        return JSONResponse({"message": "未登录"}, status_code=401)
    try:
        data = await request.json()
        nickname = data.get("nickname")
        avatar_url = data.get("avatar_url")
        profile = _auth.update_user_profile(
            user_id,
            nickname=nickname if nickname is not None else None,
            avatar_url=avatar_url if avatar_url is not None else None,
        )
        if not profile:
            return JSONResponse({"message": "更新失败"}, status_code=400)
        return JSONResponse(profile)
    except Exception as e:
        logger.exception("api_auth_update_profile")
        return JSONResponse({"message": str(e)[:200]}, status_code=500)


@app.get("/api/auth/captcha_config")
async def api_auth_captcha_config(request: Request):
    """
    图形认证配置查询：
    - configured: 服务端是否已配置 appId/appKey
    - app_id: 前端初始化图形认证 SDK 所需 appId
    """
    platform = (request.query_params.get("platform") or "web").strip()
    cfg = _graph_captcha.public_config(platform=platform)
    if not (cfg.get("sdk_url") or "").strip():
        base = str(request.base_url).rstrip("/")
        cfg["sdk_url"] = f"{base}/api/auth/captcha/sdk.js"
    admin_on = _graph_captcha_enabled_for_auth()
    cfg["configured"] = bool(cfg.get("configured")) and admin_on
    cfg["admin_graph_captcha_enabled"] = admin_on
    return JSONResponse(cfg)


@app.get("/api/auth/captcha/sdk.js")
async def api_auth_captcha_sdk():
    """托管图形认证 ct4.js（官方 H5：script src 指向可访问的完整 URL；此处为同一路径）。"""
    if os.path.isfile(_CAPTCHA_SDK_FILE):
        return FileResponse(
            _CAPTCHA_SDK_FILE,
            media_type="application/javascript; charset=utf-8",
            filename="ct4.js",
        )
    # 部署遗漏 static/ct4.js 时：随包 Base64 回退（与仓库 static/ct4.js 同步更新）
    try:
        import hibi_ct4_fallback as _ct4_fb

        fb = _ct4_fb.get_ct4_js_bytes()
        if fb:
            logger.warning(
                "使用内嵌 ct4.js 回退：请尽快将 static/ct4.js 同步到服务器 %s",
                _CAPTCHA_SDK_FILE,
            )
            return Response(
                content=fb,
                media_type="application/javascript; charset=utf-8",
            )
    except Exception as e:
        logger.exception("ct4.js 内嵌回退失败: %s", e)
    return JSONResponse({"message": "captcha sdk not found"}, status_code=404)


@app.get("/api/auth/captcha/embed", response_class=HTMLResponse)
async def api_auth_captcha_embed(request: Request):
    """
    Windows WebView2 用真实文档 URL 打开图形认证页（非 NavigateToString 内联 HTML）。
    ct4.js **内联**在本响应中，避免再发 `<script src=.../sdk.js>` 时 WebView2 请求挂死、
    界面长期停在「正在加载图形认证 SDK…」。与阿里云 H5 要求「先引入 ct4 再 initAlicom4」一致。
    """
    app_id = (request.query_params.get("app_id") or "").strip()
    if not app_id:
        return HTMLResponse(
            "<!DOCTYPE html><html><body>missing app_id</body></html>",
            status_code=400,
        )
    ct4_body = _load_ct4_js_text_for_inline()
    if not ct4_body:
        base = str(request.base_url).rstrip("/")
        sdk_js = f"{base}/api/auth/captcha/sdk.js"
        return HTMLResponse(
            f"<!DOCTYPE html><html><body>ct4.js unavailable. Check static/ct4.js or fallback; {sdk_js}</body></html>",
            status_code=500,
        )
    base = str(request.base_url).rstrip("/")
    sdk_js = f"{base}/api/auth/captcha/sdk.js"
    captcha_id_js = json.dumps(app_id)
    _err_init_undef = json.dumps(
        f"initAlicom4 未定义：内联 ct4 异常。请在浏览器打开下列完整地址自检（须为 JS 源码 200）：{sdk_js}",
        ensure_ascii=False,
    )
    ct4_esc = _escape_for_html_inline_script(ct4_body)
    runner = f"""(function() {{
  var captchaId = {captcha_id_js};
  var initDone = false;
  function send(o) {{
    try {{
      if (window.HibiCaptcha && typeof window.HibiCaptcha.postMessage === 'function') {{
        window.HibiCaptcha.postMessage(typeof o === 'string' ? o : JSON.stringify(o));
        return;
      }}
      if (!window.chrome || !window.chrome.webview || typeof window.chrome.webview.postMessage !== 'function') {{
        var h = document.getElementById('hint');
        if (h) h.textContent = '图形认证：当前 WebView 未注入 HibiCaptcha（移动）或 chrome.webview（Windows）。';
        return;
      }}
      window.chrome.webview.postMessage(o);
    }} catch (e) {{
      var h2 = document.getElementById('hint');
      if (h2) h2.textContent = '图形认证通信失败: ' + (e && e.message ? e.message : e);
    }}
  }}
  window.onerror = function (msg, src, line, col, err) {{
    send({{ event: 'error', reason: '页面脚本错误: ' + msg + (line ? (' @' + line) : '') }});
    return true;
  }};
  send({{ event: 'boot', phase: 'embed-inline' }});
  /* WebView2（Flutter 弹窗内）常在首帧把文档标为 hidden，阿里云 initAlicom4 会报 captcha_id paused */
  try {{
    if (window.chrome && window.chrome.webview) {{
      Object.defineProperty(Document.prototype, 'hidden', {{
        get: function () {{ return false; }},
        configurable: true,
      }});
      Object.defineProperty(Document.prototype, 'visibilityState', {{
        get: function () {{ return 'visible'; }},
        configurable: true,
      }});
    }}
  }} catch (eShim) {{}}
  var h0 = document.getElementById('hint');
  if (h0) h0.textContent = '正在连接阿里云验证服务...';
  setTimeout(function () {{
    if (!initDone) {{
      send({{ event: 'error', reason: '图形认证初始化超时（35s）：请检查本机能否访问 captcha.alicaptcha.com / static.alicaptcha.com，或稍后重试' }});
    }}
  }}, 35000);
  function start() {{
    if (typeof initAlicom4 !== 'function') {{
      send({{ event: 'error', reason: {_err_init_undef} }});
      return;
    }}
    try {{
      initAlicom4({{
        captchaId: captchaId,
        product: 'bind',
        https: true,
        onError: function (e) {{
          initDone = true;
          var m = (e && e.msg) ? e.msg : '网络或服务错误';
          var hint = '';
          /* 官方码 -50105：方案在控制台被暂停，见 help.aliyun.com 图形认证错误码 */
          if (typeof m === 'string' && m.indexOf('paused') !== -1) {{
            hint = ' 请到阿里云「图形认证方案管理」将该方案恢复为启用，错误码通常为 -50105 / captcha_id paused。';
          }}
          send({{ event: 'error', reason: '图形认证(加载阶段): ' + m + hint }});
        }}
      }}, function (captchaObj) {{
        initDone = true;
        captchaObj.onNextReady(function () {{
          send({{ event: 'ready' }});
          var h = document.getElementById('hint');
          if (h) h.style.display = 'none';
          captchaObj.showCaptcha();
        }});
        captchaObj.onSuccess(function () {{
          var v = captchaObj.getValidate() || {{}};
          send({{
            event: 'success',
            lot_number: v.lot_number || '',
            captcha_output: v.captcha_output || '',
            pass_token: v.pass_token || '',
            gen_time: v.gen_time || ''
          }});
        }});
        captchaObj.onClose(function () {{ send({{ event: 'close', reason: '用户取消图形认证' }}); }});
        captchaObj.onFail(function () {{ send({{ event: 'error', reason: '图形认证失败' }}); }});
        captchaObj.onError(function (e) {{ send({{ event: 'error', reason: (e && e.msg) ? e.msg : '图形认证异常' }}); }});
      }});
    }} catch (e) {{
      initDone = true;
      send({{ event: 'error', reason: '初始化失败: ' + (e && e.message ? e.message : e) }});
    }}
  }}
  function scheduleStart() {{
    requestAnimationFrame(function () {{
      requestAnimationFrame(function () {{ start(); }});
    }});
  }}
  if (document.readyState === 'loading') {{
    document.addEventListener('DOMContentLoaded', scheduleStart);
  }} else {{
    scheduleStart();
  }}
}})();"""
    html = (
        """<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="UTF-8"/>
  <meta name="viewport" content="width=device-width,initial-scale=1"/>
</head>
<body style="margin:0;background:#0f1220;color:#e8e8e8;font-family:Segoe UI, sans-serif;">
  <div id="hint" style="padding:12px 16px;">正在加载图形认证...</div>
  <script>
"""
        + ct4_esc
        + """
  </script>
  <script>
"""
        + runner
        + """
  </script>
</body>
</html>"""
    )
    return HTMLResponse(html)


@app.post("/api/auth/captcha/challenge")
async def api_auth_captcha_challenge(request: Request):
    """创建一次性图形认证挑战 ID。"""
    try:
        data = await request.json()
    except Exception:
        data = {}
    platform = (data.get("platform") or "web").strip()
    if not _graph_captcha_enabled_for_auth():
        return JSONResponse(
            {"message": "图形认证已由管理员关闭", "configured": False},
            status_code=403,
        )
    cfg = _graph_captcha.public_config(platform=platform)
    if not cfg.get("configured"):
        return JSONResponse({"message": "图形认证未配置", "configured": False}, status_code=400)
    challenge_id = _new_captcha_challenge(cfg.get("platform") or "web")
    sdk_url = (cfg.get("sdk_url") or "").strip()
    if not sdk_url:
        base = str(request.base_url).rstrip("/")
        sdk_url = f"{base}/api/auth/captcha/sdk.js"
    return JSONResponse(
        {
            "challenge_id": challenge_id,
            "platform": cfg.get("platform") or "web",
            "configured": bool(cfg.get("configured")),
            "app_id": cfg.get("app_id") or "",
            "sdk_url": sdk_url,
            "expire_in": _CAPTCHA_TTL_SECONDS,
        }
    )


@app.post("/api/auth/captcha/verify")
async def api_auth_captcha_verify(request: Request):
    """校验图形认证结果，并将挑战标记为已验证。"""
    try:
        if not _graph_captcha_enabled_for_auth():
            return JSONResponse({"message": "图形认证已由管理员关闭"}, status_code=403)
        data = await request.json()
        challenge_id = (data.get("challenge_id") or data.get("captcha_challenge_id") or "").strip()
        platform = (data.get("platform") or data.get("captcha_platform") or "web").strip()
        if not challenge_id:
            return JSONResponse({"message": "challenge_id 必填"}, status_code=400)
        _cleanup_captcha_challenges()
        item = _CAPTCHA_CHALLENGES.get(challenge_id)
        if not item:
            return JSONResponse({"message": "图形认证状态不存在或已过期"}, status_code=400)
        target_platform = item.get("platform") or "web"
        normalized_platform = (_graph_captcha.public_config(platform=platform).get("platform") or "web")
        if target_platform != normalized_platform:
            return JSONResponse({"message": "图形认证平台不匹配"}, status_code=400)
        ok, reason = _graph_captcha.verify(data, platform=target_platform)
        if not ok:
            return JSONResponse({"message": reason or "图形认证未通过"}, status_code=400)
        _mark_captcha_verified(challenge_id)
        return JSONResponse({"ok": True, "challenge_id": challenge_id})
    except Exception as e:
        logger.exception("api_auth_captcha_verify")
        return JSONResponse({"message": str(e)[:200]}, status_code=500)


@app.get("/api/auth/captcha/challenge_status")
async def api_auth_captcha_challenge_status(request: Request):
    """查询挑战状态（用于调试和轮询）。"""
    challenge_id = (request.query_params.get("challenge_id") or "").strip()
    if not challenge_id:
        return JSONResponse({"message": "challenge_id 必填"}, status_code=400)
    _cleanup_captcha_challenges()
    item = _CAPTCHA_CHALLENGES.get(challenge_id)
    if not item:
        return JSONResponse({"exists": False, "verified": False, "used": False})
    return JSONResponse(
        {
            "exists": True,
            "verified": bool(item.get("verified")),
            "used": bool(item.get("used")),
            "platform": item.get("platform") or "web",
            "expire_at": float(item.get("expire_at") or 0),
        }
    )


@app.get("/api/asr/config")
async def api_asr_config(_request: Request):
    """返回语音转文字是否已配置（兼容 ASR_APP_ID/ASR_TOKEN 与 ASR_APP_KEY/ASR_ACCESS_KEY）。"""
    app_id, token = _asr.get_asr_credentials()
    return JSONResponse(
        {
            "configured": _asr.is_asr_configured(),
            "enabled": _asr.is_asr_configured(),
            "app_id_present": bool(app_id),
            "token_present": bool(token),
        }
    )


@app.post("/api/asr")
async def api_asr(file: UploadFile = File(...)):
    """
    语音转文字：上传 WAV 文件（建议 16kHz、16bit、单声道），返回识别文本。
    需配置环境变量：ASR_APP_ID + ASR_TOKEN（或兼容旧变量 ASR_APP_KEY + ASR_ACCESS_KEY）。
    """
    if not _asr.is_asr_configured():
        return JSONResponse({"message": "语音识别未配置"}, status_code=503)
    try:
        content = await file.read()
        if len(content) < 100:
            return JSONResponse({"message": "音频过短"}, status_code=400)
        text = await _asr.run_asr(content)
        return JSONResponse({"text": text or ""})
    except ValueError as e:
        return JSONResponse({"message": str(e)[:200]}, status_code=400)
    except Exception as e:
        logger.exception("api_asr: %s", e)
        return JSONResponse({"message": str(e)[:200]}, status_code=500)


@app.websocket("/api/asr/stream")
async def ws_asr_stream(websocket: WebSocket):
    await websocket.accept()
    if not _asr.is_asr_configured():
        await websocket.send_json({"event": "error", "message": "语音识别未配置"})
        await websocket.close()
        return

    app_id, token = _asr.get_asr_credentials()
    if not app_id or not token:
        await websocket.send_json(
            {"event": "error", "message": "ASR 未配置（需 ASR_APP_ID/ASR_TOKEN 或 ASR_APP_KEY/ASR_ACCESS_KEY）"}
        )
        await websocket.close()
        return

    swap_keys = (os.environ.get("ASR_SWAP_KEYS", "") or "").strip().lower() in ("1", "true", "yes")
    headers = _asr._new_auth_headers(app_id, token, swap_keys=swap_keys)
    ws_urls = _asr.get_stream_ws_candidates()
    stop_event = asyncio.Event()
    last_partial = ""
    final_text = ""
    seq_holder = {"seq": 2}

    try:
        async with aiohttp.ClientSession() as session:
            doubao_ws = None
            last_err = None
            last_url = ""
            for url in ws_urls:
                last_url = url
                try:
                    doubao_ws = await session.ws_connect(
                        url, headers=headers, timeout=aiohttp.ClientTimeout(total=30)
                    )
                    break
                except Exception as e:
                    last_err = e
                    logger.warning("ASR stream ws_connect failed url=%s err=%s", url, e)
                    continue
            if doubao_ws is None:
                await websocket.send_json(
                    {
                        "event": "error",
                        "message": _asr_stream_ws_connect_error_message(last_err, last_url),
                    }
                )
                await websocket.close()
                return

            async with doubao_ws:
                await doubao_ws.send_bytes(_asr._new_stream_full_client_request(1))
                # 与官方「先发 full client、再读首包」一致；若未等首包校验就向豆包推 PCM，易出现全程无识别结果。
                try:
                    first = await asyncio.wait_for(doubao_ws.receive(), timeout=15.0)
                except asyncio.TimeoutError:
                    await websocket.send_json(
                        {"event": "error", "message": "豆包 ASR 首包超时，请检查 ASR_WS_URL、鉴权与网络"}
                    )
                    return
                if first.type == aiohttp.WSMsgType.BINARY:
                    fr = _asr._parse_response(first.data)
                    fcode = fr.get("code")
                    fpayload = fr.get("payload_msg")
                    if fcode is not None and int(fcode) != 0:
                        pm = fpayload if isinstance(fpayload, dict) else {}
                        err_msg = (pm.get("message") or pm.get("msg") or str(fcode))[:200]
                        logger.warning("ASR stream 豆包首包错误 code=%s: %s", fcode, err_msg)
                        await websocket.send_json({"event": "error", "message": f"ASR 服务错误: {err_msg}"})
                        return
                    t0 = _asr._extract_text_from_payload(fpayload)
                    is_f0 = _asr.payload_is_final(fpayload) or bool(fr.get("is_last"))
                    if t0:
                        last_partial = t0
                        if is_f0:
                            final_text = t0
                        await websocket.send_json({"event": "final" if is_f0 else "partial", "text": t0})
                    elif fpayload and isinstance(fpayload, dict):
                        logger.info(
                            "ASR stream 豆包首包无文本 keys=%s",
                            list(fpayload.keys())[:24],
                        )
                elif first.type == aiohttp.WSMsgType.TEXT:
                    try:
                        raw = json.loads(first.data)
                    except Exception:
                        raw = None
                    if isinstance(raw, dict):
                        t0 = _asr._extract_text_from_payload(raw)
                        is_f0 = _asr.payload_is_final(raw)
                        if t0:
                            last_partial = t0
                            if is_f0:
                                final_text = t0
                            await websocket.send_json({"event": "final" if is_f0 else "partial", "text": t0})
                elif first.type in (
                    aiohttp.WSMsgType.CLOSE,
                    aiohttp.WSMsgType.CLOSED,
                    aiohttp.WSMsgType.ERROR,
                ):
                    await websocket.send_json({"event": "error", "message": "豆包 ASR 连接首包即关闭"})
                    return
                else:
                    await websocket.send_json(
                        {"event": "error", "message": f"豆包 ASR 首包类型异常: {first.type}"}
                    )
                    return

                await websocket.send_json({"event": "ready"})

                async def recv_client_audio():
                    while not stop_event.is_set():
                        try:
                            msg = await websocket.receive()
                        except WebSocketDisconnect:
                            stop_event.set()
                            break
                        msg_type = msg.get("type")
                        if msg_type == "websocket.disconnect":
                            stop_event.set()
                            break
                        data_bytes = msg.get("bytes")
                        data_text = msg.get("text")
                        if data_bytes:
                            seq = seq_holder["seq"]
                            seq_holder["seq"] = seq + 1
                            await doubao_ws.send_bytes(_asr._new_audio_only_request(seq, data_bytes, False))
                            continue
                        if data_text:
                            try:
                                payload = json.loads(data_text)
                            except Exception:
                                payload = {}
                            if payload.get("event") == "end":
                                seq = seq_holder["seq"]
                                seq_holder["seq"] = seq + 1
                                await doubao_ws.send_bytes(_asr._new_audio_only_request(seq, b"", True))
                                stop_event.set()
                                break
                            if payload.get("event") == "cancel":
                                stop_event.set()
                                break

                async def recv_doubao_result():
                    nonlocal last_partial, final_text
                    # 客户端发 end 后豆包可能排队数百毫秒～数秒才推最后一包；4s 空闲即退出会截断结果，表现为「流式识别未返回文本」
                    drain_recv_timeout = float(
                        (os.environ.get("ASR_STREAM_DRAIN_RECV_TIMEOUT") or "22").strip() or "22"
                    )
                    while True:
                        if stop_event.is_set():
                            try:
                                msg = await asyncio.wait_for(
                                    doubao_ws.receive(),
                                    timeout=max(4.0, drain_recv_timeout),
                                )
                            except asyncio.TimeoutError:
                                break
                        else:
                            msg = await doubao_ws.receive()
                        if msg.type == aiohttp.WSMsgType.BINARY:
                            resp = _asr._parse_response(msg.data)
                            payload = resp.get("payload_msg")
                            code = resp.get("code")
                            if code is not None and int(code) != 0:
                                pm = payload if isinstance(payload, dict) else {}
                                err_t = (pm.get("message") or pm.get("msg") or str(code))[:220]
                                logger.warning("ASR stream 豆包返回错误 code=%s msg=%s", code, err_t)
                            text = _asr._extract_text_from_payload(payload)
                            is_final = _asr.payload_is_final(payload) or bool(resp.get("is_last"))
                            if text and text != last_partial:
                                last_partial = text
                                await websocket.send_json({"event": "final" if is_final else "partial", "text": text})
                            if is_final and text:
                                final_text = text
                                if stop_event.is_set():
                                    break
                        elif msg.type == aiohttp.WSMsgType.TEXT:
                            try:
                                raw = json.loads(msg.data)
                            except Exception:
                                raw = None
                            if isinstance(raw, dict):
                                text = _asr._extract_text_from_payload(raw)
                                is_final = _asr.payload_is_final(raw)
                                if text and text != last_partial:
                                    last_partial = text
                                    await websocket.send_json(
                                        {"event": "final" if is_final else "partial", "text": text}
                                    )
                                if is_final and text:
                                    final_text = text
                                    if stop_event.is_set():
                                        break
                        elif msg.type in (
                            aiohttp.WSMsgType.CLOSE,
                            aiohttp.WSMsgType.CLOSED,
                            aiohttp.WSMsgType.ERROR,
                        ):
                            break

                # 必须先等客户端发完 end/音频结束，再继续收豆包侧结果。
                # 若使用 FIRST_COMPLETED，会在 recv_client_audio 先结束时取消 recv_doubao_result，
                # 导致识别结果尚未收到就关闭，表现为「未识别到文字」。
                t_client = asyncio.create_task(recv_client_audio())
                t_doubao = asyncio.create_task(recv_doubao_result())
                try:
                    await t_client
                finally:
                    stop_event.set()
                try:
                    await asyncio.wait_for(t_doubao, timeout=25.0)
                except asyncio.TimeoutError:
                    logger.warning("ASR stream: 豆包侧结果接收超时，使用已缓存 partial/final")
                except Exception as e:
                    logger.warning("ASR stream: 豆包侧任务异常: %s", e)

                final_payload = (final_text or last_partial or "").strip()
                await websocket.send_json({"event": "done", "text": final_payload})
    except Exception as e:
        try:
            await websocket.send_json({"event": "error", "message": str(e)[:200]})
        except Exception:
            pass
    finally:
        try:
            await websocket.close()
        except Exception:
            pass


@app.get("/api/sync/pull")
async def api_sync_pull(request: Request):
    """登录后拉取：mind / schedule / assistant / settings（主题等账号级设置）"""
    user_id = _bearer_user_id(request)
    if not user_id:
        return JSONResponse({"message": "未登录"}, status_code=401)
    mind = _auth.get_user_data(user_id, "mind")
    schedule = _auth.get_user_data(user_id, "schedule")
    assistant = _auth.get_user_data(user_id, "assistant")
    settings_raw = _auth.get_user_data(user_id, "settings")
    out = {}
    if mind:
        try:
            out["mind"] = json.loads(mind)
        except Exception:
            out["mind"] = None
    else:
        out["mind"] = None
    if schedule:
        try:
            out["schedule"] = json.loads(schedule)
        except Exception:
            out["schedule"] = None
    else:
        out["schedule"] = None
    if assistant:
        try:
            out["assistant"] = json.loads(assistant)
        except Exception:
            out["assistant"] = None
    else:
        out["assistant"] = None
    if settings_raw:
        try:
            out["settings"] = json.loads(settings_raw)
        except Exception:
            out["settings"] = None
    else:
        out["settings"] = None
    return JSONResponse(out)


@app.post("/api/sync/push")
async def api_sync_push(request: Request):
    """退出/切换账户前推送：body 可含 mind / schedule / assistant / settings（主题 themeId 等）"""
    user_id = _bearer_user_id(request)
    if not user_id:
        return JSONResponse({"message": "未登录"}, status_code=401)
    try:
        data = await request.json()
        for key in ("mind", "schedule", "assistant", "settings"):
            if key not in data:
                continue
            val = data[key]
            if val is None:
                continue
            if isinstance(val, (dict, list)):
                payload = json.dumps(val, ensure_ascii=False)
            else:
                payload = str(val)
            _auth.save_user_data(user_id, key, payload)
        return JSONResponse({"ok": True})
    except Exception as e:
        logger.exception("api_sync_push")
        return JSONResponse({"message": str(e)[:200]}, status_code=500)


# ---------- 服务增值支付（数捷支付对接） ----------


@app.post("/api/payment/create_order")
async def api_payment_create_order(request: Request):
    """创建支付订单，返回 order_id、pay_url、amount、subject。需登录。"""
    user_id = _bearer_user_id(request)
    if not user_id:
        return JSONResponse({"message": "未登录"}, status_code=401)
    try:
        data = await request.json()
        plan_id = (data.get("plan_id") or "").strip()
        pay_type = (data.get("pay_type") or "").strip().lower() or None
        if not plan_id or plan_id not in _payment.PLANS:
            return JSONResponse({"message": "无效的 plan_id"}, status_code=400)
        result = _payment.create_order(user_id, plan_id, pay_type=pay_type)
        if result and result.get("error"):
            return JSONResponse(
                {"message": (result.get("message") or "无法创建订单").strip()},
                status_code=400,
            )
        if not result:
            return JSONResponse({"message": "创建订单失败"}, status_code=500)
        return JSONResponse(result)
    except Exception as e:
        logger.exception("api_payment_create_order: %s", e)
        return JSONResponse({"message": str(e)[:200]}, status_code=500)


@app.get("/api/payment/order/{order_id}")
async def api_payment_get_order(request: Request, order_id: str):
    """查询订单状态，需登录且只能查本人订单。"""
    user_id = _bearer_user_id(request)
    if not user_id:
        return JSONResponse({"message": "未登录"}, status_code=401)
    order = _payment.get_order(order_id, user_id=user_id)
    if not order:
        return JSONResponse({"message": "订单不存在"}, status_code=404)
    return JSONResponse(order)


@app.get("/api/payment/config_status")
async def api_payment_config_status(_request: Request):
    """数捷支付配置自检：返回各环境变量是否已配置（仅布尔，不返回密钥内容）。"""
    try:
        return JSONResponse(_payment.get_payment_config_status())
    except Exception as e:
        logger.exception("api_payment_config_status: %s", e)
        return JSONResponse({"ready": False, "error": str(e)[:200]}, status_code=500)


@app.get("/api/payment/plans")
async def api_payment_plans(_request: Request):
    """公开套餐目录：后端真实价格/时长/描述，供前端实时渲染。"""
    try:
        return JSONResponse(_payment.get_public_plan_catalog())
    except Exception as e:
        logger.exception("api_payment_plans: %s", e)
        return JSONResponse({"message": str(e)[:200]}, status_code=500)


@app.get("/api/legal/privacy_terms")
async def api_privacy_terms(_request: Request):
    """公开隐私条款：供 App 内查阅。"""
    try:
        doc = _get_legal_doc(_DOC_KEY_PRIVACY_TERMS)
        return JSONResponse({
            "doc_key": _DOC_KEY_PRIVACY_TERMS,
            "title": "隐私条款",
            "content": doc.get("content") or _DEFAULT_PRIVACY_TERMS,
            "updated_at": doc.get("updated_at") or 0,
        })
    except Exception as e:
        logger.exception("api_privacy_terms: %s", e)
        return JSONResponse({"message": str(e)[:200]}, status_code=500)


@app.get("/api/app/update_manifest")
async def api_app_update_manifest(_request: Request):
    """公开：App 启动后拉取，对比版本号与展示更新说明（无需登录）。"""
    try:
        return JSONResponse(get_app_update_manifest_dict())
    except Exception as e:
        logger.exception("api_app_update_manifest: %s", e)
        return JSONResponse({"message": str(e)[:200]}, status_code=500)


@app.get("/api/app/theme_policy")
async def api_app_theme_policy(_request: Request):
    """公开：主题默认与按北京日期生效的排期（无需登录）；客户端静默拉取。不含样式代码。"""
    try:
        # ETag：用 updated_at（秒）做弱一致缓存键；客户端用 If-None-Match 避免频繁拉取
        doc = _get_legal_doc(_DOC_KEY_THEME_POLICY)
        updated_at = float(doc.get("updated_at") or 0)
        etag = f'W/"tp_{int(updated_at*1000)}"'
        inm = (_request.headers.get("if-none-match") or "").strip()
        if inm and inm == etag:
            return Response(status_code=304, headers={"ETag": etag})
        data = get_theme_policy_dict(for_public=True)
        resp = JSONResponse(data)
        resp.headers["ETag"] = etag
        return resp
    except Exception as e:
        logger.exception("api_app_theme_policy: %s", e)
        return JSONResponse({"message": str(e)[:200]}, status_code=500)


@app.get("/admin/login")
async def admin_login_page():
    html = """<!doctype html>
<html><head><meta charset="utf-8"/><title>HIBI 后台登录</title>
<style>
body{font-family:Segoe UI,Arial,sans-serif;background:#0f1220;color:#e8edff;display:flex;min-height:100vh;align-items:center;justify-content:center}
.card{width:380px;background:#141936;border:1px solid #2c3562;border-radius:12px;padding:18px}
input,button{width:100%;padding:10px;border-radius:8px;border:1px solid #3a4270;background:#0f1430;color:#e8edff}
button{margin-top:10px;background:#1f8dd6;border-color:#1f8dd6;cursor:pointer}
.muted{color:#9aa6d1;font-size:12px;margin-top:8px}
</style></head>
<body>
  <form class="card" method="post" action="/admin/login">
    <h3 style="margin-top:0">后台管理登录</h3>
    <div style="margin:10px 0 6px">请输入后台密码</div>
    <input type="password" name="password" autocomplete="current-password" placeholder="后台密码"/>
    <button type="submit">登录后台</button>
  </form>
</body></html>"""
    return HTMLResponse(html)


@app.post("/admin/login")
async def admin_login_submit(request: Request):
    form = await request.form()
    password = (form.get("password") or "").strip()
    if not secrets.compare_digest(password, _admin_password()):
        return HTMLResponse("<h3>登录失败</h3><p>密码错误，请返回重试。</p><a href='/admin/login'>返回登录</a>", status_code=401)
    token = _create_admin_session()
    resp = RedirectResponse(url="/admin/customers", status_code=302)
    resp.set_cookie(
        key=_ADMIN_COOKIE_NAME,
        value=token,
        max_age=_ADMIN_SESSION_TTL_SECONDS,
        httponly=True,
        samesite="lax",
        path="/",
    )
    return resp


@app.post("/admin/logout")
async def admin_logout(request: Request):
    token = _admin_session_token(request)
    if token:
        _ADMIN_SESSIONS.pop(token, None)
    resp = RedirectResponse(url="/admin/login", status_code=302)
    resp.delete_cookie(_ADMIN_COOKIE_NAME, path="/")
    return resp


@app.get("/admin/customers")
async def admin_customers_page(request: Request):
    if not _is_admin_request(request):
        return RedirectResponse(url="/admin/login", status_code=302)
    html = """<!doctype html>
<html><head><meta charset="utf-8"/><title>HIBI 管理后台</title>
<style>
*{box-sizing:border-box}
body{font-family:"Segoe UI",system-ui,-apple-system,Arial,sans-serif;margin:0;padding:0;min-height:100vh;background:linear-gradient(165deg,#0a0c14 0%,#12152a 45%,#0f1220 100%);color:#e8edff}
.admin-wrap{max-width:1180px;margin:0 auto;padding:20px 22px 40px}
.topbar{display:flex;flex-wrap:wrap;justify-content:space-between;align-items:flex-start;gap:16px;margin-bottom:8px}
.topbar h1{margin:0;font-size:1.45rem;font-weight:600;letter-spacing:0.03em;color:#f0f4ff}
.topbar .sub{margin-top:6px;font-size:13px;color:#8b9dc9;line-height:1.4}
.topbar form{margin:0}
.tabs{display:flex;gap:4px;border-bottom:1px solid #2a3158;margin:20px 0 0;padding:0}
.tab-btn{padding:12px 22px;margin-bottom:-1px;background:transparent;border:none;border-bottom:2px solid transparent;color:#8b9dc9;font-size:15px;cursor:pointer;border-radius:8px 8px 0 0;transition:color .15s,background .15s}
.tab-btn:hover{color:#c5d4f0;background:rgba(79,195,247,.06)}
.tab-btn.active{color:#4fc3f7;border-bottom-color:#4fc3f7;background:rgba(79,195,247,.08);font-weight:600}
.tab-panel{display:none;padding-top:18px;animation:fadeIn .22s ease}
.tab-panel.active{display:block}
@keyframes fadeIn{from{opacity:.75}to{opacity:1}}
.row{display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin-bottom:10px}
input,select,button{padding:8px 12px;border-radius:8px;border:1px solid #3a4270;background:#141936;color:#e8edff;font-size:13px}
input#kw{min-width:220px;flex:1;max-width:420px}
button[type="submit"],button.primary{background:linear-gradient(180deg,#2388c9,#1a6fa8);border-color:#2a8cc4;color:#fff}
button[type="submit"]:hover,button.primary:hover{filter:brightness(1.06)}
textarea{width:100%;min-height:220px;padding:12px;border-radius:10px;border:1px solid #354174;background:#0f1430;color:#e8edff;line-height:1.55;font-size:13px}
table{width:100%;border-collapse:separate;border-spacing:0;font-size:13px;border-radius:10px;overflow:hidden;border:1px solid #2a3158}
th,td{border-bottom:1px solid #2a3158;padding:10px 12px;vertical-align:top}
tr:last-child td{border-bottom:none}
th{background:linear-gradient(180deg,#1a1f3d,#141936);color:#b8c5e8;font-weight:600;text-align:left}
tbody tr:hover{background:rgba(79,195,247,.04)}
.muted{color:#8b9dc9;font-size:12px}
.tag{display:inline-block;padding:2px 8px;border-radius:999px;background:#252d52;font-size:12px}
.panel{border:1px solid #323a63;border-radius:12px;background:linear-gradient(180deg,#12172e,#101633);padding:14px 16px;margin:0 0 14px;box-shadow:0 4px 24px rgba(0,0,0,.25)}
.panel h3{margin:0 0 8px;font-size:15px;font-weight:600;color:#dbe4ff}
.users-toolbar{background:rgba(15,20,48,.6);border:1px solid #2a3158;border-radius:10px;padding:12px 14px;margin-bottom:12px}
code{color:#9ecbff;font-size:12px}
.theme-table{width:100%;border-collapse:separate;border-spacing:0;font-size:13px}
.table-scroll{width:100%;overflow:auto;border-radius:10px;border:1px solid #2a3158}
.table-scroll table{border:none;border-radius:0;overflow:visible}
.theme-table th,.theme-table td{border-bottom:1px solid #2a3158;padding:10px 8px;vertical-align:middle}
.theme-table th{color:#b8c5e8;font-weight:600;text-align:left}
.theme-actions{position:relative;text-align:right;white-space:nowrap}
.theme-menu-btn{background:transparent;border:1px solid #3a4570;color:#c5d4f0;border-radius:8px;padding:4px 10px;cursor:pointer;font-size:16px;line-height:1}
.theme-menu-btn:hover{background:rgba(79,195,247,.1)}
.theme-dropdown{position:absolute;right:0;top:100%;margin-top:4px;min-width:200px;background:#141936;border:1px solid #354174;border-radius:10px;box-shadow:0 8px 28px rgba(0,0,0,.45);z-index:50;display:none;padding:6px 0}
.theme-dropdown.open{display:block}
.theme-dropdown button{display:block;width:100%;text-align:left;padding:8px 14px;background:transparent;border:none;color:#e8edff;font-size:13px;cursor:pointer}
.theme-dropdown button:hover{background:rgba(79,195,247,.12)}
.theme-status-line{font-size:12px;color:#8b9dc9;line-height:1.45}
.theme-badge{display:inline-block;padding:2px 8px;border-radius:6px;font-size:11px;margin-left:6px}
.theme-badge.def{background:#1a4a6e;color:#9ee6ff}
.theme-badge.hid{background:#4a3040;color:#ffb3c0}
.modal-backdrop{position:fixed;inset:0;background:rgba(0,0,0,.55);z-index:200;display:flex;align-items:center;justify-content:center;padding:16px}
.modal-card{background:#12172e;border:1px solid #354174;border-radius:14px;max-width:560px;width:100%;max-height:90vh;overflow:auto;padding:18px 20px;box-shadow:0 12px 48px rgba(0,0,0,.5)}
.modal-card h4{margin:0 0 10px;font-size:16px;color:#dbe4ff}
.modal-card .row{margin-bottom:8px}
.modal-card textarea{width:100%;min-height:220px;font-family:ui-monospace,Consolas,monospace;font-size:12px}
.push-grid{display:grid;grid-template-columns:repeat(2,1fr);gap:8px;margin-top:10px}
.push-grid label{display:flex;align-items:center;gap:8px;cursor:pointer;font-size:13px}
</style></head>
<body>
<div class="admin-wrap">
<header class="topbar">
  <div>
    <h1>HIBI 管理后台</h1>
    <div class="sub">服务增值订阅 · 系统配置与内容管理</div>
  </div>
  <form method="post" action="/admin/logout"><button type="submit">退出登录</button></form>
</header>
<nav class="tabs" role="tablist">
  <button type="button" class="tab-btn active" id="tabbtn-settings" role="tab" aria-selected="true" data-tab="settings" onclick="switchTab('settings')">系统配置</button>
  <button type="button" class="tab-btn" id="tabbtn-themes" role="tab" aria-selected="false" data-tab="themes" onclick="switchTab('themes')">主题管理</button>
  <button type="button" class="tab-btn" id="tabbtn-users" role="tab" aria-selected="false" data-tab="users" onclick="switchTab('users')">用户管理</button>
</nav>
<div id="tab-settings" class="tab-panel active" role="tabpanel" aria-labelledby="tabbtn-settings">
<div id="captcha_panel" class="panel">
  <h3 style="margin:2px 0 8px">图形认证（登录 / 注册）</h3>
  <div class="muted" style="margin-bottom:8px">关闭后，客户端会认为未开启图形认证（<code style="color:#aab8e8">captcha_config.configured=false</code>），用户可直接登录、注册；开启后行为与原先一致（需阿里云图形认证配置）。</div>
  <label style="display:flex;align-items:center;gap:8px;cursor:pointer">
    <input type="checkbox" id="graph_captcha_enabled"/> <span>开启图形认证</span>
  </label>
  <div class="row" style="margin-top:10px">
    <button type="button" onclick="saveGraphCaptchaSetting()">保存</button>
    <button type="button" onclick="loadGraphCaptchaSetting()">重新加载</button>
    <span id="graph_captcha_admin_status" class="muted"></span>
  </div>
</div>
<div id="privacy_panel" class="panel">
  <h3 style="margin:2px 0 8px">隐私条款（App 内展示）</h3>
  <div class="muted" style="margin-bottom:8px">保存后，用户在「设置-隐私条款」会读取到最新内容。</div>
  <textarea id="privacy_terms" placeholder="请输入隐私条款内容"></textarea>
  <div class="row" style="margin-top:8px">
    <button onclick="savePrivacyTerms()">保存隐私条款</button>
    <button onclick="loadPrivacyTerms()">重新加载</button>
    <span id="privacy_status" class="muted"></span>
  </div>
</div>
<div id="abp_panel" class="panel">
  <h3 style="margin:2px 0 8px">项目助理 System Prompt（工具调用 / 日程与思维节点）</h3>
  <div class="muted" style="margin-bottom:8px">保存后，使用项目助理对话时会作为 system 提示词（若未配置 <code style="color:#aab8e8">HIBI_ABP_SYSTEM_PROMPT_FILE</code> 或文件为空）。首次进入已填入当前默认全文，可直接改。</div>
  <textarea id="abp_system_prompt" style="min-height:360px" placeholder="项目助理 System Prompt"></textarea>
  <div class="row" style="margin-top:8px">
    <button onclick="saveAbpSystemPrompt()">保存 Prompt</button>
    <button onclick="loadAbpSystemPrompt()">重新加载</button>
    <button onclick="clearAbpSystemPrompt()">清除库内文案（回退默认）</button>
    <span id="abp_status" class="muted"></span>
  </div>
</div>
<div id="app_update_panel" class="panel">
  <h3 style="margin:2px 0 8px">升级推送地址（App 版本更新）</h3>
  <div class="muted" style="margin-bottom:8px">填写<strong>最新版本号</strong>（须大于用户端才会提示更新）、<strong>更新特征</strong>，以及各系统安装包下载地址。客户端在「我的」页对比版本并支持应用内下载安装（iOS 一般为 App Store/TestFlight 链接，由系统打开）。</div>
  <div class="row" style="margin-bottom:8px;align-items:flex-end">
    <label style="flex:1;min-width:200px">最新版本号（如 2.2.0）
      <input id="au_version" placeholder="2.2.0" style="width:100%;margin-top:4px"/>
    </label>
  </div>
  <label>更新特征 / 说明</label>
  <textarea id="au_notes" style="min-height:120px;margin-top:4px" placeholder="每行一条，例如：&#10;- 修复同步问题&#10;- 优化助理响应"></textarea>
  <div class="muted" style="margin:10px 0 6px">各端安装包直链（HTTPS 推荐）</div>
  <div class="row" style="margin-bottom:6px;align-items:flex-end">
    <label style="flex:1;min-width:240px">Windows (.exe / 安装包)
      <input id="au_win" placeholder="https://..." style="width:100%;margin-top:4px"/>
    </label>
    <label style="min-width:240px">上传 Windows 安装包
      <input id="au_win_file" type="file" accept=".exe,.msi,.zip" style="width:100%;margin-top:4px"/>
    </label>
    <button type="button" onclick="uploadAppPackage('windows')">上传</button>
    <span id="au_win_upload_status" class="muted"></span>
  </div>
  <div class="row" style="margin-bottom:6px"><label style="flex:1;min-width:240px">iOS（App Store / TestFlight）
    <input id="au_ios" placeholder="https://apps.apple.com/..." style="width:100%;margin-top:4px"/>
  </label></div>
  <div class="row" style="margin-bottom:6px;align-items:flex-end">
    <label style="flex:1;min-width:240px">Android (.apk)
      <input id="au_android" placeholder="https://.../app.apk" style="width:100%;margin-top:4px"/>
    </label>
    <label style="min-width:240px">上传 Android 安装包
      <input id="au_android_file" type="file" accept=".apk,.aab" style="width:100%;margin-top:4px"/>
    </label>
    <button type="button" onclick="uploadAppPackage('android')">上传</button>
    <span id="au_android_upload_status" class="muted"></span>
  </div>
  <div class="row" style="margin-bottom:10px"><label style="flex:1;min-width:240px">Linux (.deb / AppImage 等）
    <input id="au_linux" placeholder="https://..." style="width:100%;margin-top:4px"/>
  </label></div>
  <div class="row">
    <button type="button" onclick="saveAppUpdateManifest()">保存升级配置</button>
    <button type="button" onclick="loadAppUpdateManifest()">重新加载</button>
    <span id="app_update_status" class="muted"></span>
  </div>
</div>
</div>
<div id="tab-themes" class="tab-panel" role="tabpanel" aria-labelledby="tabbtn-themes">
<div class="panel">
  <h3 style="margin:2px 0 8px">主题管理（北京时间）</h3>
  <div class="muted" style="margin-bottom:10px">内置主题用于客户端实际渲染；自定义主题用于后台扩展与存档。你可以为自定义主题设置名字/说明/代码/状态，并<strong>绑定到某个内置主题</strong>来复用当前推送与默认逻辑（客户端当前仍以内置 ThemeData 为准）。</div>
  <div class="panel" style="padding:12px 14px;margin:10px 0 14px;background:rgba(15,20,48,.45)">
    <div style="font-weight:600;margin:2px 0 10px;color:#dbe4ff">新增主题（自定义）</div>
    <div class="row" style="align-items:flex-end">
      <label style="min-width:220px;flex:1">名字
        <input id="new_theme_name" placeholder="例如：春日限定" style="width:100%;margin-top:4px"/>
      </label>
      <label style="min-width:240px;flex:1">说明
        <input id="new_theme_desc" placeholder="例如：活动主题（后续扩展）" style="width:100%;margin-top:4px"/>
      </label>
    </div>
    <div class="row" style="align-items:flex-end">
      <label style="min-width:260px">绑定到内置主题（用于推送/默认）
        <select id="new_theme_bind" style="width:100%;margin-top:4px">
          <option value="">（不绑定，仅存档）</option>
          <option value="hibi">hibi主题</option>
          <option value="dark">暗色主题</option>
          <option value="light">亮色主题</option>
          <option value="2027ss">2027SS</option>
          <option value="dreamy">梦幻</option>
          <option value="dreamy_night">梦幻·夜</option>
          <option value="cyberpunk">CyberPunk</option>
          <option value="astral">星界</option>
          <option value="astral_phantasm">星界·幻</option>
          <option value="earthrealm">地界</option>
        </select>
      </label>
      <label style="display:flex;align-items:center;gap:8px;min-width:120px;margin-bottom:4px">
        <input type="checkbox" id="new_theme_enabled" checked/> 启用
      </label>
      <label style="display:flex;align-items:center;gap:8px;min-width:120px;margin-bottom:4px">
        <input type="checkbox" id="new_theme_hidden"/> 隐藏
      </label>
      <button type="button" class="primary" onclick="addCustomTheme()">新增</button>
      <span id="new_theme_status" class="muted"></span>
    </div>
    <label class="muted" style="display:block;margin:6px 0 6px">主题代码（可选）</label>
    <textarea id="new_theme_code" style="min-height:140px" placeholder='例如：{"accent":"#4fc3f7"} 或设计说明'></textarea>
  </div>
  <div id="theme_policy_status" class="muted" style="margin-bottom:10px"></div>
  <div class="panel" style="padding:12px 14px;margin:0 0 14px;background:rgba(15,20,48,.45)">
    <div style="font-weight:600;margin:2px 0 10px;color:#dbe4ff">日历排期（按日历日，北京时间，优先于周历）</div>
    <div class="muted" style="margin-bottom:8px">用于提前配置节日主题：例如设置 <b>2026-09-25</b> 推送中秋主题。主题即使隐藏，仍可在该日自动生效（但用户看不到也选不了）。</div>
    <div class="row" style="align-items:flex-end">
      <label style="min-width:200px">开始日期
        <input id="cal_start" type="date" style="width:100%;margin-top:4px"/>
      </label>
      <label style="min-width:200px">截至日期
        <input id="cal_end" type="date" style="width:100%;margin-top:4px"/>
      </label>
      <label style="min-width:320px;flex:1">主题（内置或自定义）
        <select id="cal_theme_ref" style="width:100%;margin-top:4px"></select>
      </label>
      <button type="button" class="primary" onclick="addCalendarEntry()">添加/覆盖</button>
      <span id="cal_status" class="muted"></span>
    </div>
    <div class="table-scroll" style="margin-top:10px">
    <table class="theme-table">
      <thead><tr><th style="width:140px">日期</th><th>主题</th><th class="theme-actions">操作</th></tr></thead>
      <tbody id="cal_list_body"></tbody>
    </table>
    </div>
  </div>
  <div class="row" style="margin:0 0 10px;align-items:flex-end">
    <input id="theme_kw" placeholder="搜索主题名 / ID" style="min-width:240px;flex:1;max-width:420px"/>
    <label style="display:flex;align-items:center;gap:8px;cursor:pointer;margin-bottom:4px">
      <input type="checkbox" id="only_custom"/> 仅自定义
    </label>
    <label style="display:flex;align-items:center;gap:8px;cursor:pointer;margin-bottom:4px">
      <input type="checkbox" id="only_hidden"/> 仅隐藏
    </label>
  </div>
  <div class="table-scroll">
  <table class="theme-table" id="theme_list_table">
    <thead><tr><th>主题</th><th>状态</th><th class="theme-actions">操作</th></tr></thead>
    <tbody id="theme_list_body"></tbody>
  </table>
  </div>
  <div class="row" style="margin-top:12px">
    <button type="button" onclick="loadThemePolicy()">重新加载</button>
  </div>
</div>
</div>
<div id="tab-users" class="tab-panel" role="tabpanel" aria-labelledby="tabbtn-users">
<div class="users-toolbar">
  <div class="row" style="margin:0">
    <input id="kw" placeholder="搜索账号 / 昵称 / user_id"/>
    <button type="button" class="primary" onclick="load()">查询</button>
  </div>
  <div class="muted" style="margin-top:8px">支持编辑各套餐状态、剩余天数、备注；列表展示总消费、创建与登录时间及 IP 定位。</div>
</div>
<div id="status" class="muted" style="margin-bottom:8px"></div>
<table id="tbl"><thead><tr>
<th>客户</th><th>创建/登录</th><th>消费</th><th>套餐状态</th>
</tr></thead><tbody></tbody></table>
</div>
<div id="modal_theme_push" class="modal-backdrop" style="display:none" onclick="if(event.target===this) closePushModal()">
  <div class="modal-card" onclick="event.stopPropagation()">
    <h4 id="modal_push_title">设置推送日期</h4>
    <div class="muted">勾选后，该星期几将<strong>静默推送</strong>本主题（北京时区整日）。取消勾选仅取消本主题在该日的排期。每个星期几同时只能有一个主题。</div>
    <div class="push-grid" id="modal_push_checks"></div>
    <div class="row" style="margin-top:14px">
      <button type="button" class="primary" onclick="savePushModal()">保存</button>
      <button type="button" onclick="closePushModal()">取消</button>
    </div>
  </div>
</div>
<div id="modal_theme_code" class="modal-backdrop" style="display:none" onclick="if(event.target===this) closeCodeModal()">
  <div class="modal-card" onclick="event.stopPropagation()">
    <h4 id="modal_code_title">主题样式代码</h4>
    <div class="muted">可填写 JSON / 设计 token / 备注；当前 App 仍以内置 ThemeData 渲染，此处供存档与后续扩展。</div>
    <textarea id="modal_code_text" placeholder='例如：{"accent":"#4fc3f7"} 或设计说明'></textarea>
    <div class="row" style="margin-top:10px">
      <button type="button" class="primary" onclick="saveCodeModal()">保存</button>
      <button type="button" onclick="closeCodeModal()">取消</button>
    </div>
  </div>
</div>
<div id="modal_custom_edit" class="modal-backdrop" style="display:none" onclick="if(event.target===this) closeCustomEditModal()">
  <div class="modal-card" onclick="event.stopPropagation()">
    <h4 id="modal_custom_title">编辑自定义主题</h4>
    <div class="row" style="align-items:flex-end">
      <label style="min-width:220px;flex:1">名字
        <input id="modal_custom_name" style="width:100%;margin-top:4px"/>
      </label>
      <label style="min-width:260px">绑定到内置主题
        <select id="modal_custom_bind" style="width:100%;margin-top:4px">
          <option value="">（不绑定）</option>
          <option value="hibi">hibi主题</option>
          <option value="dark">暗色主题</option>
          <option value="light">亮色主题</option>
          <option value="2027ss">2027SS</option>
          <option value="dreamy">梦幻</option>
          <option value="dreamy_night">梦幻·夜</option>
          <option value="cyberpunk">CyberPunk</option>
          <option value="astral">星界</option>
          <option value="astral_phantasm">星界·幻</option>
          <option value="earthrealm">地界</option>
        </select>
      </label>
    </div>
    <label class="muted" style="display:block;margin:6px 0 6px">说明</label>
    <input id="modal_custom_desc" style="width:100%"/>
    <div class="row" style="margin-top:10px">
      <label style="display:flex;align-items:center;gap:8px;cursor:pointer">
        <input type="checkbox" id="modal_custom_enabled"/> 启用
      </label>
      <label style="display:flex;align-items:center;gap:8px;cursor:pointer">
        <input type="checkbox" id="modal_custom_hidden"/> 隐藏
      </label>
    </div>
    <label class="muted" style="display:block;margin:6px 0 6px">主题代码</label>
    <textarea id="modal_custom_code" placeholder='例如：{"accent":"#4fc3f7"} 或设计说明'></textarea>
    <div class="row" style="margin-top:10px">
      <button type="button" class="primary" onclick="saveCustomEditModal()">保存</button>
      <button type="button" onclick="closeCustomEditModal()">取消</button>
    </div>
  </div>
</div>
</div>
<script>
async function req(url,opt={}){const r=await fetch(url,opt);if(!r.ok) throw new Error(await r.text()); return r.json();}
function fmtTs(v){if(!v) return '-'; return new Date(v*1000).toLocaleString();}
function fmtLeft(s){if(s==null) return '-'; s=Number(s); if(s<=0) return '0天'; const d=Math.floor(s/86400), h=Math.floor((s%86400)/3600); return `${d}天${h}小时`;}
function esc(s){return String(s??'').replaceAll('&','&amp;').replaceAll('<','&lt;');}
function switchTab(name){
  document.querySelectorAll('.tab-btn').forEach(function(b){
    var on = b.getAttribute('data-tab') === name;
    b.classList.toggle('active', on);
    b.setAttribute('aria-selected', on ? 'true' : 'false');
  });
  var pSet = document.getElementById('tab-settings');
  var pThemes = document.getElementById('tab-themes');
  var pUsr = document.getElementById('tab-users');
  if(pSet) pSet.classList.toggle('active', name === 'settings');
  if(pThemes) pThemes.classList.toggle('active', name === 'themes');
  if(pUsr) pUsr.classList.toggle('active', name === 'users');
  if(name === 'users'){ load(); }
  if(name === 'themes'){ loadThemePolicy(); }
  try{
    if(window.history && window.history.replaceState){
      var h = name === 'users' ? '#users' : (name === 'themes' ? '#themes' : (window.location.pathname + window.location.search));
      window.history.replaceState(null, '', h);
    }
  }catch(e){}
}
window.addEventListener('hashchange', function(){
  if(window.location.hash === '#users') switchTab('users');
  else if(window.location.hash === '#themes') switchTab('themes');
  else switchTab('settings');
});
async function loadGraphCaptchaSetting(){
  const s = document.getElementById('graph_captcha_admin_status');
  try{
    s.textContent = '加载中...';
    const data = await req('/api/admin/settings/graph_captcha_enabled');
    document.getElementById('graph_captcha_enabled').checked = data.enabled !== false;
    s.textContent = data.enabled ? '当前：开启（登录/注册需图形验证）' : '当前：关闭（可直接登录/注册）';
  }catch(e){
    s.textContent = '加载失败：' + (e?.message || e);
  }
}
async function saveGraphCaptchaSetting(){
  const s = document.getElementById('graph_captcha_admin_status');
  try{
    s.textContent = '保存中...';
    const enabled = document.getElementById('graph_captcha_enabled').checked;
    await req('/api/admin/settings/graph_captcha_enabled', {
      method:'POST',
      headers:{'content-type':'application/json'},
      body:JSON.stringify({enabled}),
    });
    s.textContent = enabled ? '已保存：开启' : '已保存：关闭';
  }catch(e){
    s.textContent = '保存失败：' + (e?.message || e);
  }
}
async function loadPrivacyTerms(){
  const s = document.getElementById('privacy_status');
  try{
    s.textContent = '隐私条款加载中...';
    const data = await req('/api/admin/legal/privacy_terms');
    document.getElementById('privacy_terms').value = data.content || '';
    s.textContent = `最近更新：${fmtTs(data.updated_at)} ${data.updated_by ? '（' + data.updated_by + '）' : ''}`;
  }catch(e){
    s.textContent = '加载失败：' + (e?.message || e);
  }
}
async function savePrivacyTerms(){
  const s = document.getElementById('privacy_status');
  try{
    s.textContent = '保存中...';
    const content = document.getElementById('privacy_terms').value || '';
    const data = await req('/api/admin/legal/privacy_terms', {
      method:'POST',
      headers:{'content-type':'application/json'},
      body:JSON.stringify({content}),
    });
    s.textContent = `保存成功，更新时间：${fmtTs(data.updated_at)}`;
  }catch(e){
    s.textContent = '保存失败：' + (e?.message || e);
  }
}
async function loadAbpSystemPrompt(){
  const s = document.getElementById('abp_status');
  try{
    s.textContent = '加载中...';
    const data = await req('/api/admin/settings/abp_system_prompt');
    document.getElementById('abp_system_prompt').value = data.content || '';
    s.textContent = `最近更新：${fmtTs(data.updated_at)} ${data.updated_by ? '（' + data.updated_by + '）' : ''}`;
  }catch(e){
    s.textContent = '加载失败：' + (e?.message || e);
  }
}
async function saveAbpSystemPrompt(){
  const s = document.getElementById('abp_status');
  try{
    s.textContent = '保存中...';
    const content = document.getElementById('abp_system_prompt').value || '';
    const data = await req('/api/admin/settings/abp_system_prompt', {
      method:'POST',
      headers:{'content-type':'application/json'},
      body:JSON.stringify({content}),
    });
    if(data.reset){ s.textContent = data.message || '已清除'; await loadAbpSystemPrompt(); return; }
    s.textContent = `保存成功，更新时间：${fmtTs(data.updated_at)}`;
  }catch(e){
    s.textContent = '保存失败：' + (e?.message || e);
  }
}
async function clearAbpSystemPrompt(){
  if(!confirm('确定清除库内保存的 Prompt？无文件覆盖时将使用代码内置默认。')) return;
  const s = document.getElementById('abp_status');
  try{
    s.textContent = '清除中...';
    await req('/api/admin/settings/abp_system_prompt', {
      method:'POST',
      headers:{'content-type':'application/json'},
      body:JSON.stringify({content:''}),
    });
    await loadAbpSystemPrompt();
    s.textContent = '已回退为代码默认（展示在文本框中）';
    }catch(e){
    s.textContent = '操作失败：' + (e?.message || e);
  }
}
async function loadAppUpdateManifest(){
  const s = document.getElementById('app_update_status');
  try{
    s.textContent = '加载中...';
    const data = await req('/api/admin/settings/app_update_manifest');
    document.getElementById('au_version').value = data.latest_version || '';
    document.getElementById('au_notes').value = data.release_notes || '';
    document.getElementById('au_win').value = (data.urls && data.urls.windows) || '';
    document.getElementById('au_ios').value = (data.urls && data.urls.ios) || '';
    document.getElementById('au_android').value = (data.urls && data.urls.android) || '';
    document.getElementById('au_linux').value = (data.urls && data.urls.linux) || '';
    s.textContent = data.updated_at ? ('已加载 · 更新时间 ' + new Date(data.updated_at*1000).toLocaleString()) : '已加载';
  }catch(e){
    s.textContent = '加载失败：' + (e?.message || e);
  }
}

async function uploadAppPackage(platform){
  const statusId = platform === 'windows' ? 'au_win_upload_status'
                 : platform === 'android' ? 'au_android_upload_status'
                 : 'app_update_status';
  const fileId = platform === 'windows' ? 'au_win_file'
               : platform === 'android' ? 'au_android_file'
               : null;
  const urlInputId = platform === 'windows' ? 'au_win'
                 : platform === 'android' ? 'au_android'
                 : null;
  const s = document.getElementById(statusId);
  try{
    if(!fileId || !urlInputId){ throw new Error('当前平台未配置上传控件'); }
    const f = document.getElementById(fileId).files && document.getElementById(fileId).files[0];
    if(!f){ throw new Error('请先选择文件'); }
    s.textContent = '上传中...';
    const fd = new FormData();
    fd.append('platform', platform);
    fd.append('file', f, f.name);
    const r = await fetch('/api/admin/uploads/app_package', { method:'POST', body: fd });
    if(!r.ok){ throw new Error(await r.text()); }
    const data = await r.json();
    if(!data || data.ok !== true){ throw new Error((data && data.message) || '上传失败'); }
    document.getElementById(urlInputId).value = data.download_url || '';
    s.textContent = `已上传：${data.filename || ''}（${Math.round((data.size_bytes||0)/1024/1024)}MB）`;
  }catch(e){
    s.textContent = '上传失败：' + (e?.message || e);
  }
}
async function saveAppUpdateManifest(){
  const s = document.getElementById('app_update_status');
  try{
    s.textContent = '保存中...';
    const body = {
      latest_version: document.getElementById('au_version').value.trim(),
      release_notes: document.getElementById('au_notes').value,
      urls: {
        windows: document.getElementById('au_win').value.trim(),
        ios: document.getElementById('au_ios').value.trim(),
        android: document.getElementById('au_android').value.trim(),
        linux: document.getElementById('au_linux').value.trim(),
      },
    };
    await req('/api/admin/settings/app_update_manifest', {
      method:'POST',
      headers:{'content-type':'application/json'},
      body:JSON.stringify(body),
    });
    await loadAppUpdateManifest();
    s.textContent = '已保存';
  }catch(e){
    s.textContent = '保存失败：' + (e?.message || e);
  }
}
async function setPlan(uid,pid){
  const st = document.getElementById(`st_${uid}_${pid}`).value;
  const days = Number(document.getElementById(`days_${uid}_${pid}`).value||0);
  const note = document.getElementById(`note_${uid}_${pid}`).value||'';
  await req(`/api/admin/customers/${uid}/plans/${pid}/set_status`,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({status:st,remaining_days:days,note})});
  await load();
}
async function clearPlan(uid,pid){await req(`/api/admin/customers/${uid}/plans/${pid}/clear_override`,{method:'POST'}); await load();}
async function load(){
  document.getElementById('status').textContent='加载中...';
  const kw = document.getElementById('kw').value||'';
  const data = await req(`/api/admin/customers?keyword=${encodeURIComponent(kw)}&limit=200`);
  const tb = document.querySelector('#tbl tbody'); tb.innerHTML='';
  for(const u of data.items){
    const tr=document.createElement('tr');
    const plans=(u.entitlements?.plans||[]).map(p=>{
      const pid=p.plan_id, st=p.status;
      return `<div style="margin-bottom:8px;padding:8px;background:#111731;border-radius:8px">
        <div><b>${esc(pid)}</b> <span class="tag">${esc(st)}</span> 剩余:${fmtLeft(p.remaining_seconds)} ${p.admin_override?'(管理员覆盖)':''}</div>
        <div class="row" style="margin-top:6px">
          <select id="st_${u.user_id}_${pid}">
            <option value="active">active</option><option value="grace">grace</option><option value="interrupted">interrupted</option><option value="inactive">inactive</option>
          </select>
          <input id="days_${u.user_id}_${pid}" placeholder="剩余天数(可选)" style="width:120px"/>
          <input id="note_${u.user_id}_${pid}" placeholder="备注(可选)" style="min-width:180px"/>
          <button onclick="setPlan('${u.user_id}','${pid}')">保存</button>
          <button onclick="clearPlan('${u.user_id}','${pid}')">清除覆盖</button>
        </div>
      </div>`;
    }).join('');
    tr.innerHTML = `<td>
      <div><b>${esc(u.nickname||'-')}</b></div>
      <div class="muted">${esc(u.phone_or_email)}</div>
      <div class="muted">ID: ${esc(u.user_id)}</div>
    </td>
    <td>
      <div>创建: ${fmtTs(u.created_at)}</div>
      <div class="muted">创建IP: ${esc(u.created_ip||'-')}</div>
      <div class="muted">创建定位: ${esc(u.created_geo||'-')}</div>
      <div style="margin-top:6px">最近登录: ${fmtTs(u.last_login_at)}</div>
      <div class="muted">登录IP: ${esc(u.last_login_ip||'-')}</div>
      <div class="muted">登录定位: ${esc(u.last_login_geo||'-')}</div>
    </td>
    <td><b>¥${Number(u.total_spent_amount||0).toFixed(2)}</b><div class="muted">${u.total_spent_cents||0} 分</div></td>
    <td>${plans || '<span class="muted">无</span>'}</td>`;
    tb.appendChild(tr);
  }
  document.getElementById('status').textContent=`共 ${data.total} 位客户`;
}
window._themePolicyDraft = null;
window._modalThemeId = null;
window._themeOptions = [];
function closeAllThemeMenus(){
  document.querySelectorAll('.theme-dropdown.open').forEach(function(el){ el.classList.remove('open'); });
}
document.addEventListener('click', function(){ closeAllThemeMenus(); });
function toggleThemeMenu(ev, themeId){
  ev.stopPropagation();
  closeAllThemeMenus();
  var dd = document.getElementById('theme_menu_'+themeId);
  if(dd) dd.classList.toggle('open');
}
async function postThemePolicyDraft(){
  var s = document.getElementById('theme_policy_status');
  if(s) s.textContent = '保存中...';
  const body = {
    default_theme_id: window._themePolicyDraft.default_theme_id,
    weekly: window._themePolicyDraft.weekly,
    theme_meta: window._themePolicyDraft.theme_meta,
    custom_themes: window._themePolicyDraft.custom_themes || [],
    calendar: window._themePolicyDraft.calendar || [],
  };
  await req('/api/admin/settings/theme_policy', {
    method:'POST',
    headers:{'content-type':'application/json'},
    body: JSON.stringify(body),
  });
  await loadThemePolicy();
  if(s) s.textContent = '已保存';
}
async function themeSetDefault(themeId){
  closeAllThemeMenus();
  window._themePolicyDraft.default_theme_id = themeId;
  if(!window._themePolicyDraft.theme_meta[themeId]) window._themePolicyDraft.theme_meta[themeId] = {hidden:false,style_code:''};
  window._themePolicyDraft.theme_meta[themeId].hidden = false;
  await postThemePolicyDraft();
}
async function themeToggleHidden(themeId){
  closeAllThemeMenus();
  var dft = window._themePolicyDraft.default_theme_id;
  if(themeId === dft){ alert('默认主题不可隐藏'); return; }
  var m = window._themePolicyDraft.theme_meta[themeId];
  if(!m) m = {hidden:false,style_code:''};
  m.hidden = !m.hidden;
  window._themePolicyDraft.theme_meta[themeId] = m;
  await postThemePolicyDraft();
}

async function addCustomTheme(){
  var s = document.getElementById('new_theme_status');
  try{
    if(s) s.textContent = '新增中...';
    if(!window._themePolicyDraft) await loadThemePolicy();
    const name = (document.getElementById('new_theme_name').value||'').trim();
    if(!name){ if(s) s.textContent='名字不能为空'; return; }
    const desc = (document.getElementById('new_theme_desc').value||'').trim();
    const bind = (document.getElementById('new_theme_bind').value||'').trim();
    const enabled = document.getElementById('new_theme_enabled').checked;
    const hidden = document.getElementById('new_theme_hidden').checked;
    const code = document.getElementById('new_theme_code').value||'';
    const id = 'custom_' + Date.now().toString(36);
    const item = {id, name, description: desc, bind_theme_id: bind||null, enabled, hidden, style_code: code};
    if(!Array.isArray(window._themePolicyDraft.custom_themes)) window._themePolicyDraft.custom_themes = [];
    window._themePolicyDraft.custom_themes.unshift(item);
    await postThemePolicyDraft();
    document.getElementById('new_theme_name').value = '';
    document.getElementById('new_theme_desc').value = '';
    document.getElementById('new_theme_bind').value = '';
    document.getElementById('new_theme_enabled').checked = true;
    document.getElementById('new_theme_hidden').checked = false;
    document.getElementById('new_theme_code').value = '';
    if(s) s.textContent = '已新增';
  }catch(e){
    if(s) s.textContent = '新增失败：' + (e?.message || e);
  }
}

function openCustomEditModal(themeId){
  closeAllThemeMenus();
  var list = window._themePolicyDraft.custom_themes || [];
  var it = list.find(function(x){ return x && x.id === themeId; });
  if(!it){ alert('未找到自定义主题'); return; }
  window._modalThemeId = themeId;
  document.getElementById('modal_custom_title').textContent = '编辑自定义主题 — ' + themeId;
  document.getElementById('modal_custom_name').value = it.name || '';
  document.getElementById('modal_custom_desc').value = it.description || '';
  document.getElementById('modal_custom_bind').value = it.bind_theme_id || '';
  document.getElementById('modal_custom_enabled').checked = it.enabled !== false;
  document.getElementById('modal_custom_hidden').checked = !!it.hidden;
  document.getElementById('modal_custom_code').value = it.style_code || '';
  document.getElementById('modal_custom_edit').style.display = 'flex';
}
function closeCustomEditModal(){
  document.getElementById('modal_custom_edit').style.display = 'none';
}
async function saveCustomEditModal(){
  var themeId = window._modalThemeId;
  var list = window._themePolicyDraft.custom_themes || [];
  var idx = list.findIndex(function(x){ return x && x.id === themeId; });
  if(idx < 0) return;
  list[idx] = {
    id: themeId,
    name: (document.getElementById('modal_custom_name').value||'').trim(),
    description: (document.getElementById('modal_custom_desc').value||'').trim(),
    bind_theme_id: (document.getElementById('modal_custom_bind').value||'').trim() || null,
    enabled: document.getElementById('modal_custom_enabled').checked,
    hidden: document.getElementById('modal_custom_hidden').checked,
    style_code: document.getElementById('modal_custom_code').value||'',
  };
  window._themePolicyDraft.custom_themes = list;
  closeCustomEditModal();
  await postThemePolicyDraft();
}
async function deleteCustomTheme(themeId){
  closeAllThemeMenus();
  if(!confirm('确认删除该自定义主题？')) return;
  var list = window._themePolicyDraft.custom_themes || [];
  window._themePolicyDraft.custom_themes = list.filter(function(x){ return x && x.id !== themeId; });
  await postThemePolicyDraft();
}
function openPushModal(themeId){
  closeAllThemeMenus();
  window._modalThemeId = themeId;
  var w = window._themePolicyDraft.weekly || {};
  var days = ['mon','tue','wed','thu','fri','sat','sun'];
  var labels = {mon:'周一',tue:'周二',wed:'周三',thu:'周四',fri:'周五',sat:'周六',sun:'周日'};
  var html = '';
  days.forEach(function(d){
    var on = (w[d] === themeId);
    html += '<label><input type="checkbox" data-day="'+d+'" '+(on?'checked':'')+'/> '+labels[d]+'</label>';
  });
  document.getElementById('modal_push_checks').innerHTML = html;
  document.getElementById('modal_push_title').textContent = '推送日期 — ' + themeId;
  document.getElementById('modal_theme_push').style.display = 'flex';
}
function closePushModal(){
  document.getElementById('modal_theme_push').style.display = 'none';
  window._modalThemeId = null;
}
async function savePushModal(){
  var themeId = window._modalThemeId;
  if(!themeId) return;
  var w = window._themePolicyDraft.weekly;
  var boxes = document.querySelectorAll('#modal_push_checks input[type=checkbox]');
  boxes.forEach(function(cb){
    var d = cb.getAttribute('data-day');
    if(cb.checked){
      w[d] = themeId;
    } else {
      if(w[d] === themeId) w[d] = null;
    }
  });
  closePushModal();
  await postThemePolicyDraft();
}
function openCodeModal(themeId){
  closeAllThemeMenus();
  window._modalThemeId = themeId;
  var m = window._themePolicyDraft.theme_meta[themeId] || {style_code:''};
  document.getElementById('modal_code_text').value = m.style_code || '';
  document.getElementById('modal_code_title').textContent = '主题样式代码 — ' + themeId;
  document.getElementById('modal_theme_code').style.display = 'flex';
}
function closeCodeModal(){
  document.getElementById('modal_theme_code').style.display = 'none';
}
async function saveCodeModal(){
  var themeId = window._modalThemeId;
  if(!themeId) return;
  var txt = document.getElementById('modal_code_text').value || '';
  if(!window._themePolicyDraft.theme_meta[themeId]) window._themePolicyDraft.theme_meta[themeId] = {hidden:false,style_code:''};
  window._themePolicyDraft.theme_meta[themeId].style_code = txt;
  closeCodeModal();
  await postThemePolicyDraft();
}
function renderThemeList(data){
  var tb = document.getElementById('theme_list_body');
  if(!tb) return;
  var themes = data.themes || [];
  var kw = (document.getElementById('theme_kw')?.value || '').trim().toLowerCase();
  var onlyCustom = !!document.getElementById('only_custom')?.checked;
  var onlyHidden = !!document.getElementById('only_hidden')?.checked;
  tb.innerHTML = '';
  themes.forEach(function(t){
    if(onlyCustom && t.kind !== 'custom') return;
    if(onlyHidden && !t.hidden) return;
    if(kw){
      var hit = (t.display_name||'').toLowerCase().includes(kw) || (t.theme_id||'').toLowerCase().includes(kw);
      if(!hit) return;
    }
    var tr = document.createElement('tr');
    var statusHtml = '<div class="theme-status-line">推送：'+esc(t.push_summary)+'</div>';
    statusHtml += '<div class="theme-status-line">日历：'+esc(t.calendar_summary||'无')+'</div>';
    statusHtml += '<div class="theme-status-line">默认：'+(t.is_default?'是':'否');
    if(t.hidden) statusHtml += ' <span class="theme-badge hid">已隐藏</span>';
    if(t.is_default) statusHtml += ' <span class="theme-badge def">默认</span>';
    if(t.kind === 'custom' && t.enabled === false) statusHtml += ' <span class="theme-badge hid" style="background:#3a3a3a;color:#ddd">未启用</span>';
    statusHtml += '</div>';
    var tid = t.theme_id;
    var menuHtml = `<div class="theme-actions"><button type="button" class="theme-menu-btn" onclick="toggleThemeMenu(event, '${tid}')">⋯</button>`;
    menuHtml += `<div class="theme-dropdown" id="theme_menu_${tid}" onclick="event.stopPropagation()">`;
    if(t.kind === 'custom'){
      menuHtml += `<button type="button" onclick="openCustomEditModal('${tid}')">编辑…</button>`;
      menuHtml += `<button type="button" onclick="deleteCustomTheme('${tid}')">删除</button>`;
    } else {
      menuHtml += `<button type="button" onclick="openPushModal('${tid}')">设置推送日期</button>`;
      menuHtml += `<button type="button" onclick="themeSetDefault('${tid}')">设为默认主题</button>`;
      menuHtml += `<button type="button" onclick="themeToggleHidden('${tid}')">${t.hidden?'显示主题':'隐藏主题'}</button>`;
      menuHtml += `<button type="button" onclick="openCodeModal('${tid}')">主题代码…</button>`;
    }
    menuHtml += '</div></div>';
    var sub = (t.kind === 'custom')
      ? (esc(t.theme_id) + (t.bind_theme_id ? (' · 绑定:' + esc(t.bind_theme_id)) : ' · 未绑定'))
      : esc(t.theme_id);
    tr.innerHTML = '<td><b>'+esc(t.display_name)+'</b><div class="muted" style="font-size:11px;margin-top:2px">'+sub+'</div></td><td>'+statusHtml+'</td><td>'+menuHtml+'</td>';
    tb.appendChild(tr);
  });
  if(!tb.children.length){
    var tr = document.createElement('tr');
    tr.innerHTML = `<td colspan="3" class="muted">无匹配主题</td>`;
    tb.appendChild(tr);
  }
}

function renderCalendar(data){
  var tb = document.getElementById('cal_list_body');
  var sel = document.getElementById('cal_theme_ref');
  if(!tb || !sel) return;
  // 构造主题下拉：内置 + 自定义（不依赖 hidden/enabled，便于排期应用）
  var themes = data.themes || [];
  window._themeOptions = themes.map(function(t){
    return {id: t.theme_id, name: t.display_name || t.theme_id, kind: t.kind, bind: t.bind_theme_id || ''};
  });
  sel.innerHTML = '';
  window._themeOptions.forEach(function(opt){
    var o = document.createElement('option');
    o.value = opt.id;
    var extra = opt.kind === 'custom' ? (opt.bind ? ('（绑定:'+opt.bind+'）') : '（未绑定）') : '';
    o.textContent = opt.name + ' · ' + opt.id + extra;
    sel.appendChild(o);
  });

  var cal = data.calendar || [];
  tb.innerHTML = '';
  cal.forEach(function(it){
    if(!it || !it.start_date) return;
    var tr = document.createElement('tr');
    var ref = it.theme_ref || it.apply_theme_id || '';
    var found = window._themeOptions.find(function(x){ return x.id === ref; });
    var label = found ? (found.name + ' · ' + found.id) : ref;
    var apply = it.apply_theme_id ? ('应用:' + it.apply_theme_id) : '';
    var range = it.start_date + (it.end_date && it.end_date !== it.start_date ? (' ~ ' + it.end_date) : '');
    tr.innerHTML = `<td><b>${esc(range)}</b></td><td>${esc(label)} <span class="muted" style="margin-left:6px">${esc(apply)}</span></td><td class="theme-actions"><button type="button" onclick="deleteCalendarEntry('${esc(it.id||'')}')">删除</button></td>`;
    tb.appendChild(tr);
  });
  if(cal.length === 0){
    var tr = document.createElement('tr');
    tr.innerHTML = `<td colspan="3" class="muted">暂无日历排期</td>`;
    tb.appendChild(tr);
  }
}

async function addCalendarEntry(){
  var s = document.getElementById('cal_status');
  try{
    if(s) s.textContent = '保存中...';
    if(!window._themePolicyDraft) await loadThemePolicy();
    var sd = (document.getElementById('cal_start').value||'').trim();
    var ed = (document.getElementById('cal_end').value||'').trim();
    var ref = (document.getElementById('cal_theme_ref').value||'').trim();
    if(!sd || !ref){ if(s) s.textContent='请选择开始日期与主题'; return; }
    if(!ed) ed = sd;
    if(!Array.isArray(window._themePolicyDraft.calendar)) window._themePolicyDraft.calendar = [];
    const id = 'cal_' + Date.now().toString(36);
    window._themePolicyDraft.calendar.push({id: id, start_date: sd, end_date: ed, theme_ref: ref});
    await postThemePolicyDraft();
    if(s) s.textContent = '已保存';
  }catch(e){
    if(s) s.textContent = '保存失败：' + (e?.message || e);
  }
}

async function deleteCalendarEntry(id){
  var s = document.getElementById('cal_status');
  try{
    if(!window._themePolicyDraft) await loadThemePolicy();
    if(!confirm('删除该日历排期？')) return;
    window._themePolicyDraft.calendar = (window._themePolicyDraft.calendar||[]).filter(function(x){ return x && x.id !== id; });
    await postThemePolicyDraft();
    if(s) s.textContent = '已删除';
  }catch(e){
    if(s) s.textContent = '删除失败：' + (e?.message || e);
  }
}
async function loadThemePolicy(){
  const s = document.getElementById('theme_policy_status');
  if(!s) return;
  try{
    s.textContent = '加载中...';
    const data = await req('/api/admin/settings/theme_policy');
    var tm = data.theme_meta && typeof data.theme_meta === 'object' ? data.theme_meta : {};
    window._themePolicyDraft = {
      default_theme_id: data.default_theme_id || 'astral',
      weekly: Object.assign({}, data.weekly || {}),
      theme_meta: JSON.parse(JSON.stringify(tm)),
      custom_themes: Array.isArray(data.custom_themes) ? data.custom_themes : [],
      calendar: Array.isArray(data.calendar) ? data.calendar : [],
    };
    if(data.themes){
      data.themes.forEach(function(t){
        if(!window._themePolicyDraft.theme_meta[t.theme_id]){
          window._themePolicyDraft.theme_meta[t.theme_id] = {hidden:!!t.hidden, style_code:t.style_code||''};
        }
      });
    }
    renderCalendar(data);
    renderThemeList(data);
    s.textContent = '北京 ' + (data.beijing_date||'-') + ' · 当日生效：' + (data.effective_theme_id||data.default_theme_id||'');
    try{
      document.getElementById('theme_kw')?.addEventListener('input', function(){ renderThemeList(data); });
      document.getElementById('only_custom')?.addEventListener('change', function(){ renderThemeList(data); });
      document.getElementById('only_hidden')?.addEventListener('change', function(){ renderThemeList(data); });
    }catch(e){}
  }catch(e){
    s.textContent = '加载失败：' + (e?.message || e);
  }
}
loadGraphCaptchaSetting();
loadPrivacyTerms();
loadAbpSystemPrompt();
loadAppUpdateManifest();
if(window.location.hash === '#users'){ switchTab('users'); }
else if(window.location.hash === '#themes'){ switchTab('themes'); }
else { switchTab('settings'); }
</script>
</body></html>"""
    return HTMLResponse(html)


@app.get("/api/admin/customers")
async def api_admin_customers(request: Request, keyword: str = "", limit: int = 200, offset: int = 0):
    if not _is_admin_request(request):
        return JSONResponse({"message": "未授权"}, status_code=401)
    try:
        return JSONResponse(_payment.admin_list_customers(keyword=keyword, limit=limit, offset=offset))
    except Exception as e:
        logger.exception("api_admin_customers: %s", e)
        return JSONResponse({"message": str(e)[:200]}, status_code=500)


@app.post("/api/admin/customers/{user_id}/plans/{plan_id}/set_status")
async def api_admin_set_plan_status(request: Request, user_id: str, plan_id: str):
    if not _is_admin_request(request):
        return JSONResponse({"message": "未授权"}, status_code=401)
    try:
        body = await request.json()
        ok = _payment.admin_upsert_plan_override(
            user_id=user_id,
            plan_id=plan_id,
            status=(body.get("status") or "").strip().lower(),
            remaining_days=int(body.get("remaining_days")) if str(body.get("remaining_days") or "").strip() else None,
            note=(body.get("note") or "").strip(),
        )
        if not ok:
            return JSONResponse({"message": "参数无效"}, status_code=400)
        return JSONResponse({"ok": True})
    except Exception as e:
        logger.exception("api_admin_set_plan_status: %s", e)
        return JSONResponse({"message": str(e)[:200]}, status_code=500)


@app.post("/api/admin/customers/{user_id}/plans/{plan_id}/clear_override")
async def api_admin_clear_plan_override(request: Request, user_id: str, plan_id: str):
    if not _is_admin_request(request):
        return JSONResponse({"message": "未授权"}, status_code=401)
    try:
        ok = _payment.admin_clear_plan_override(user_id=user_id, plan_id=plan_id)
        return JSONResponse({"ok": ok})
    except Exception as e:
        logger.exception("api_admin_clear_plan_override: %s", e)
        return JSONResponse({"message": str(e)[:200]}, status_code=500)


@app.get("/api/admin/legal/privacy_terms")
async def api_admin_get_privacy_terms(request: Request):
    if not _is_admin_request(request):
        return JSONResponse({"message": "未授权"}, status_code=401)
    try:
        doc = _get_legal_doc(_DOC_KEY_PRIVACY_TERMS)
        return JSONResponse({
            "doc_key": _DOC_KEY_PRIVACY_TERMS,
            "title": "隐私条款",
            "content": doc.get("content") or _DEFAULT_PRIVACY_TERMS,
            "updated_at": doc.get("updated_at") or 0,
            "updated_by": doc.get("updated_by") or "",
        })
    except Exception as e:
        logger.exception("api_admin_get_privacy_terms: %s", e)
        return JSONResponse({"message": str(e)[:200]}, status_code=500)


@app.post("/api/admin/legal/privacy_terms")
async def api_admin_set_privacy_terms(request: Request):
    if not _is_admin_request(request):
        return JSONResponse({"message": "未授权"}, status_code=401)
    try:
        body = await request.json()
        content = (body.get("content") or "").strip()
        if not content:
            return JSONResponse({"message": "content 不能为空"}, status_code=400)
        saved = _save_legal_doc(_DOC_KEY_PRIVACY_TERMS, content, updated_by="admin")
        return JSONResponse({
            "ok": True,
            "doc_key": saved.get("doc_key"),
            "updated_at": saved.get("updated_at"),
            "updated_by": saved.get("updated_by"),
        })
    except Exception as e:
        logger.exception("api_admin_set_privacy_terms: %s", e)
        return JSONResponse({"message": str(e)[:200]}, status_code=500)


@app.get("/api/admin/settings/abp_system_prompt")
async def api_admin_get_abp_system_prompt(request: Request):
    """后台读取项目助理（工具调用）System Prompt，用于管理页编辑。"""
    if not _is_admin_request(request):
        return JSONResponse({"message": "未授权"}, status_code=401)
    try:
        import hibi_abp_tools as _abp

        doc = _get_legal_doc(_DOC_KEY_ABP_SYSTEM_PROMPT)
        content = (doc.get("content") or "").strip()
        if not content:
            content = _abp.DEFAULT_SYSTEM_PROMPT
        return JSONResponse({
            "doc_key": _DOC_KEY_ABP_SYSTEM_PROMPT,
            "title": "项目助理 System Prompt（工具调用）",
            "content": content,
            "updated_at": doc.get("updated_at") or 0,
            "updated_by": doc.get("updated_by") or "",
            "priority_note": "若 ECS 配置了 HIBI_ABP_SYSTEM_PROMPT_FILE 且文件非空，运行时优先读该文件，此处保存的内容不生效。",
        })
    except Exception as e:
        logger.exception("api_admin_get_abp_system_prompt: %s", e)
        return JSONResponse({"message": str(e)[:200]}, status_code=500)


@app.post("/api/admin/settings/abp_system_prompt")
async def api_admin_set_abp_system_prompt(request: Request):
    """保存或清除（传空字符串）项目助理 System Prompt。"""
    if not _is_admin_request(request):
        return JSONResponse({"message": "未授权"}, status_code=401)
    try:
        body = await request.json()
        if body.get("content") is None:
            return JSONResponse({"message": "缺少 content 字段"}, status_code=400)
        text = (body.get("content") or "").strip()
        if not text:
            with _legal_db() as c:
                c.execute("DELETE FROM legal_documents WHERE doc_key = ?", (_DOC_KEY_ABP_SYSTEM_PROMPT,))
            return JSONResponse({
                "ok": True,
                "reset": True,
                "message": "已清除库内文案；无文件覆盖时运行时使用代码默认 prompt。",
            })
        saved = _save_legal_doc(_DOC_KEY_ABP_SYSTEM_PROMPT, text, updated_by="admin")
        return JSONResponse({
            "ok": True,
            "doc_key": saved.get("doc_key"),
            "updated_at": saved.get("updated_at"),
            "updated_by": saved.get("updated_by"),
        })
    except Exception as e:
        logger.exception("api_admin_set_abp_system_prompt: %s", e)
        return JSONResponse({"message": str(e)[:200]}, status_code=500)


@app.get("/api/admin/settings/graph_captcha_enabled")
async def api_admin_get_graph_captcha_enabled(request: Request):
    """读取登录/注册是否要求图形认证。"""
    if not _is_admin_request(request):
        return JSONResponse({"message": "未授权"}, status_code=401)
    try:
        return JSONResponse({"enabled": _graph_captcha_enabled_for_auth()})
    except Exception as e:
        logger.exception("api_admin_get_graph_captcha_enabled: %s", e)
        return JSONResponse({"message": str(e)[:200]}, status_code=500)


@app.post("/api/admin/settings/graph_captcha_enabled")
async def api_admin_set_graph_captcha_enabled(request: Request):
    """开启/关闭登录与注册的图形认证。"""
    if not _is_admin_request(request):
        return JSONResponse({"message": "未授权"}, status_code=401)
    try:
        body = await request.json()
        if "enabled" not in body:
            return JSONResponse({"message": "缺少 enabled 字段（布尔）"}, status_code=400)
        en = body.get("enabled")
        if not isinstance(en, bool):
            return JSONResponse({"message": "enabled 须为布尔值"}, status_code=400)
        _save_legal_doc(
            _DOC_KEY_GRAPH_CAPTCHA_ENABLED,
            "true" if en else "false",
            updated_by="admin",
        )
        return JSONResponse({"ok": True, "enabled": en})
    except Exception as e:
        logger.exception("api_admin_set_graph_captcha_enabled: %s", e)
        return JSONResponse({"message": str(e)[:200]}, status_code=500)


@app.get("/api/admin/settings/app_update_manifest")
async def api_admin_get_app_update_manifest(request: Request):
    if not _is_admin_request(request):
        return JSONResponse({"message": "未授权"}, status_code=401)
    try:
        return JSONResponse(get_app_update_manifest_dict())
    except Exception as e:
        logger.exception("api_admin_get_app_update_manifest: %s", e)
        return JSONResponse({"message": str(e)[:200]}, status_code=500)


@app.post("/api/admin/settings/app_update_manifest")
async def api_admin_set_app_update_manifest(request: Request):
    if not _is_admin_request(request):
        return JSONResponse({"message": "未授权"}, status_code=401)
    try:
        body = await request.json()
        if not isinstance(body, dict):
            return JSONResponse({"message": "body 须为 JSON 对象"}, status_code=400)
        merged = _normalize_app_update_manifest(body)
        _save_legal_doc(
            _DOC_KEY_APP_UPDATE_MANIFEST,
            json.dumps(merged, ensure_ascii=False),
            updated_by="admin",
        )
        return JSONResponse({"ok": True, **get_app_update_manifest_dict()})
    except Exception as e:
        logger.exception("api_admin_set_app_update_manifest: %s", e)
        return JSONResponse({"message": str(e)[:200]}, status_code=500)


@app.get("/api/admin/settings/theme_policy")
async def api_admin_get_theme_policy(request: Request):
    if not _is_admin_request(request):
        return JSONResponse({"message": "未授权"}, status_code=401)
    try:
        return JSONResponse(get_theme_policy_dict())
    except Exception as e:
        logger.exception("api_admin_get_theme_policy: %s", e)
        return JSONResponse({"message": str(e)[:200]}, status_code=500)


@app.post("/api/admin/settings/theme_policy")
async def api_admin_set_theme_policy(request: Request):
    if not _is_admin_request(request):
        return JSONResponse({"message": "未授权"}, status_code=401)
    try:
        body = await request.json()
        if not isinstance(body, dict):
            return JSONResponse({"message": "body 须为 JSON 对象"}, status_code=400)
        merged = _normalize_theme_policy(body)
        _save_legal_doc(
            _DOC_KEY_THEME_POLICY,
            json.dumps(merged, ensure_ascii=False),
            updated_by="admin",
        )
        return JSONResponse({"ok": True, **get_theme_policy_dict()})
    except Exception as e:
        logger.exception("api_admin_set_theme_policy: %s", e)
        return JSONResponse({"message": str(e)[:200]}, status_code=500)


@app.post("/api/admin/uploads/app_package")
async def api_admin_upload_app_package(
    request: Request,
    file: UploadFile = File(...),
    platform: str = Form(""),
):
    """
    后台上传安装包文件（Windows/Android/Linux/可选 iOS 企业包）。
    返回可公开下载的 URL，供写入 app_update_manifest.urls。
    """
    if not _is_admin_request(request):
        return JSONResponse({"message": "未授权"}, status_code=401)
    try:
        plat = (platform or "").strip().lower()
        if not plat:
            return JSONResponse({"message": "缺少 platform（windows/android/ios/linux）"}, status_code=400)
        if plat not in ("windows", "android", "ios", "linux"):
            return JSONResponse({"message": "platform 不合法（windows/android/ios/linux）"}, status_code=400)
        if file is None or not file.filename:
            return JSONResponse({"message": "缺少文件"}, status_code=400)

        _ensure_upload_dir()
        orig = _safe_filename(file.filename)
        ext = _ext_lower(orig)
        allowed = _allowed_package_ext(plat)
        if ext not in allowed:
            return JSONResponse(
                {"message": f"文件类型不支持：{ext or '(无后缀)'}；{plat} 仅允许：{', '.join(sorted(allowed))}"},
                status_code=400,
            )

        now = datetime.now().strftime("%Y%m%d_%H%M%S")
        rand = secrets.token_hex(4)
        final_name = _safe_filename(f"{plat}_{now}_{rand}{ext}")
        dst = os.path.join(_APP_PACKAGE_UPLOAD_DIR, final_name)
        size = await _save_upload_file(file, dst)
        url = _build_public_download_url(request, final_name)
        return JSONResponse(
            {
                "ok": True,
                "platform": plat,
                "filename": final_name,
                "size_bytes": size,
                "download_url": url,
            }
        )
    except ValueError as e:
        logger.warning("api_admin_upload_app_package bad request: %s", e)
        return JSONResponse({"message": str(e)[:200]}, status_code=400)
    except Exception as e:
        logger.exception("api_admin_upload_app_package: %s", e)
        return JSONResponse({"message": str(e)[:200]}, status_code=500)


@app.get("/api/app/packages/{filename}")
async def api_app_download_package(filename: str):
    """公开下载安装包（配合后台上传）。"""
    try:
        _ensure_upload_dir()
        safe = _safe_filename(filename)
        path = os.path.join(_APP_PACKAGE_UPLOAD_DIR, safe)
        if not os.path.isfile(path):
            return JSONResponse({"message": "文件不存在"}, status_code=404)
        return FileResponse(path, filename=safe, media_type="application/octet-stream")
    except Exception as e:
        logger.exception("api_app_download_package: %s", e)
        return JSONResponse({"message": str(e)[:200]}, status_code=500)


@app.get("/api/payment/my_entitlements")
async def api_payment_my_entitlements(request: Request):
    """当前用户会员权益：pro（最高 PRO 档）、basic_plans（生效的基础服务）、pro_valid_until。需登录。"""
    user_id = _bearer_user_id(request)
    if not user_id:
        return JSONResponse({"message": "未登录"}, status_code=401)
    try:
        data = _payment.get_user_entitlements(user_id)
        return JSONResponse(data)
    except Exception as e:
        logger.exception("api_payment_my_entitlements: %s", e)
        return JSONResponse({"message": str(e)[:200]}, status_code=500)


@app.api_route("/api/payment/notify", methods=["GET", "POST"])
async def api_payment_notify(request: Request):
    """数捷支付异步通知（SDK2 兼容 GET/POST），验签后更新订单。"""
    try:
        form: dict[str, str] = {}
        raw_text = ""

        if request.method == "GET":
            for k, v in request.query_params.items():
                form[k] = v
            raw_text = urllib.parse.urlencode(form)
        else:
            body = await request.body()
            raw_text = body.decode("utf-8", errors="ignore")
            content_type = (request.headers.get("content-type") or "").lower()
            if "application/json" in content_type:
                try:
                    data = json.loads(raw_text or "{}")
                    if isinstance(data, dict):
                        form = {str(k): "" if v is None else str(v) for k, v in data.items()}
                except Exception:
                    form = {}
            else:
                # 按 x-www-form-urlencoded 解析
                for part in raw_text.split("&"):
                    if "=" in part:
                        k, v = part.split("=", 1)
                        form[urllib.parse.unquote_plus(k)] = urllib.parse.unquote_plus(v)
            # POST 且 body 未解析出键值时，兼容 query-string 回调
            if not form and request.query_params:
                for k, v in request.query_params.items():
                    form[k] = v

        ok, msg = _payment.verify_notify_and_update(form)
        order_id = (form.get("out_trade_no") or form.get("order_id") or form.get("mch_order_no") or "").strip()
        if order_id:
            # 无论成功/失败都落库，便于排查“支付成功未到账”。
            _payment.save_notify_raw(order_id, f"[ok={ok}] {raw_text[:2000]}")
        # 按 SDK 约定返回纯文本 success/fail（HTTP 200），便于补单与网关回调判定。
        return PlainTextResponse("success" if ok else "fail", status_code=200)
    except Exception as e:
        logger.exception("api_payment_notify: %s", e)
        return PlainTextResponse("fail", status_code=200)


@app.get("/api/payment/pay_page")
async def api_payment_pay_page(request: Request, order_id: str = ""):
    """未配置数捷时，创建订单后跳转的说明页；也可用于 return_url 落地页。"""
    # 兼容不同支付网关回跳参数命名
    order_id = (
        order_id
        or (request.query_params.get("order_id") or "").strip()
        or (request.query_params.get("out_trade_no") or "").strip()
        or (request.query_params.get("trade_no") or "").strip()
        or (request.query_params.get("merchant_order_no") or "").strip()
    )
    # 若支付平台把同步回跳参数带到 return_url（/pay_page），这里直接按 notify 规则做一次入账兜底。
    qp = {k: v for k, v in request.query_params.items()}
    return_verify_msg = ""
    if qp.get("sign") and (qp.get("out_trade_no") or qp.get("order_id")):
        ok, msg = _payment.verify_notify_and_update(qp)
        oid = (qp.get("out_trade_no") or qp.get("order_id") or "").strip()
        if oid:
            _payment.save_notify_raw(oid, f"[return_page ok={ok}] {urllib.parse.urlencode(qp)[:2000]}")
        return_verify_msg = "success" if ok else f"fail:{msg}"
        # 若回跳验签失败，但已带成功态和 trade_no，则主动查单补齐，减少手工补单。
        if (not ok) and oid:
            status = (qp.get("trade_status") or qp.get("status") or "").strip().lower()
            if status in ("trade_success", "success", "paid", "1"):
                trade_no_hint = (qp.get("trade_no") or qp.get("transaction_id") or "").strip()
                synced = _payment.reconcile_order_with_gateway(oid, trade_no_hint=trade_no_hint)
                if synced:
                    return_verify_msg = "success(reconciled)"

    mode = (request.query_params.get("mode") or "").strip().lower()
    packed = (request.query_params.get("p") or "").strip()
    if mode == "shujie_post" and packed:
        try:
            pad = "=" * ((4 - len(packed) % 4) % 4)
            decoded = base64.urlsafe_b64decode((packed + pad).encode("ascii")).decode("utf-8")
            obj = json.loads(decoded)
            submit_url = str(obj.get("submit_url") or "").strip()
            params = obj.get("params") or {}
            if not submit_url.startswith("http"):
                raise ValueError("invalid submit_url")
            if not isinstance(params, dict) or not params:
                raise ValueError("invalid params")
            hidden = []
            for k, v in params.items():
                hidden.append(
                    f'<input type="hidden" name="{html_utils.escape(str(k), quote=True)}" '
                    f'value="{html_utils.escape(str(v), quote=True)}"/>'
                )
            form_html = "\n".join(hidden)
            html_text = f"""<!DOCTYPE html><html><head><meta charset="utf-8"><title>正在跳转支付</title></head>
<body>
<form id="hibiPayForm" action="{html_utils.escape(submit_url, quote=True)}" method="post">
{form_html}
</form>
<p>正在跳转到支付页面，请稍候...</p>
<script>document.getElementById('hibiPayForm').submit();</script>
</body></html>"""
            return HTMLResponse(html_text)
        except Exception as e:
            logger.exception("api_payment_pay_page(post bridge) decode error: %s", e)
            return HTMLResponse("<p>支付参数无效，请返回应用重新发起支付。</p>", status_code=400)

    if return_verify_msg.startswith("success"):
        status_title = "支付已完成"
        status_body = "订单已收到支付结果，请返回应用查看订阅是否已更新。"
    elif return_verify_msg.startswith("fail"):
        status_title = "支付结果处理中"
        status_body = "我们正在同步支付结果，通常会在几秒内完成。"
    else:
        status_title = "支付页面已返回"
        status_body = "请返回应用点击“我已支付，查看结果”刷新订阅状态。"

    html = f"""<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>支付结果</title>
  <style>
    body {{
      margin: 0;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "PingFang SC", "Microsoft YaHei", sans-serif;
      background: #f6f8fb;
      color: #1f2937;
    }}
    .wrap {{
      max-width: 560px;
      margin: 36px auto;
      padding: 0 16px;
    }}
    .card {{
      background: #fff;
      border-radius: 14px;
      box-shadow: 0 8px 26px rgba(17, 24, 39, 0.08);
      padding: 18px 16px;
      border: 1px solid #eef2f7;
    }}
    .title {{
      margin: 0 0 10px 0;
      font-size: 20px;
      font-weight: 700;
      color: #0f172a;
    }}
    .desc {{
      margin: 0 0 12px 0;
      line-height: 1.7;
      color: #334155;
      font-size: 14px;
    }}
    .order {{
      margin: 0;
      font-size: 13px;
      color: #64748b;
      word-break: break-all;
    }}
    .tip {{
      margin-top: 14px;
      padding: 10px 12px;
      border-radius: 10px;
      background: #f1f5f9;
      color: #475569;
      font-size: 13px;
      line-height: 1.6;
    }}
  </style>
</head>
<body>
  <div class="wrap">
    <div class="card">
      <h1 class="title">{html_utils.escape(status_title)}</h1>
      <p class="desc">{html_utils.escape(status_body)}</p>
      <p class="order">订单号：{html_utils.escape(order_id or '-')}</p>
      <div class="tip">如应用内仍未更新，请稍等几秒后重试“我已支付，查看结果”。</div>
    </div>
  </div>
</body>
</html>"""
    return HTMLResponse(html)


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=PORT)
