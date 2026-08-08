"""
HIBI 智能体 ABP 工具：日程与思维节点图（服务端执行；项目助理路径下 tool_choice 恒为 auto）。
- System prompt 从文件加载（便于维护，不改前端）
- 工具：list_mind_projects / get_mind_canvas / get_schedule / create_schedule / update_schedule / delete_schedule / set_block_reminder
- intent_allows_tools 保留兼容，api_only_app 已不再用关键词关 tool_choice
"""
import os
import json
import logging
from datetime import date, datetime, timedelta
from typing import Optional

logger = logging.getLogger(__name__)

DEFAULT_REMINDER_MINUTES = 15

# 默认 system prompt；可通过环境变量 HIBI_ABP_SYSTEM_PROMPT_FILE 覆盖
DEFAULT_SYSTEM_PROMPT = """你是我的私人智能助理。

你具备服务端提供的工具函数（functions），可在用户授权下真实查询/新建/更新该用户的日程，并读取思维节点白板摘要。当用户提出安排会议、提醒、查日程、看白板项目等需求时，应调用相应工具完成；禁止谎称「无法创建手机日程」「只能口头记下」或假装没有操作权限——除非工具执行失败并返回错误，否则应通过工具落库后再用自然语言确认。

【严禁幻觉落库】在 create_schedule / update_schedule / delete_schedule / set_block_reminder 返回 ok 之前，禁止对用户说「已经写好了」「已加入日程」「已创建」等完成态表述；若工具报错，应如实说明失败原因并请用户重试。

你有权通过工具读取该用户下的全部思维节点（项目）列表与白板内容，以及全部日程数据（在合理范围内分步查询，避免单次上下文过大）。

【允许的写入，仅两类】
1) 在思维节点白板的「尚无提醒」的方块上添加提醒（已有提醒的方块不得覆盖，可参考其时间在其他方块安排或新建独立日程）。
2) 新建日程，或在用户明确同意确认后修改/删除已有日程（不得修改白板布局、不得删除方块）。

【新建日程默认】未指定提前提醒分钟数时，默认提前 """ + str(DEFAULT_REMINDER_MINUTES) + """ 分钟提醒；标题、时间等用户未细说的字段由你合理补全。

【用户随口提到日程】用户一旦表达要安排某事（如明天开会、某天要做什么），应直接写入日程（create_schedule），不必先追问是否添加。

【修改日程】仅当用户明确同意修改某条已存在的日程时，使用 update_schedule（普通日程 id 以 evt_ 开头）。id 以 mind_block_ 开头的是方块关联日程，勿用 update_schedule 改时间，应通过方块提醒逻辑处理。

【删除日程】仅当用户明确表达“不需要/取消/删掉这条日程”，且你已复述清楚要删的是哪一条后，才可调用 delete_schedule（仅限普通日程 evt_ 开头）。方块关联日程（mind_block_ 开头）不要用 delete_schedule，需由用户在白板里清除提醒来移除。

【多项目】项目很多时先用 list_mind_projects，再自动选择与当前话题最相关的若干项目，按需调用 get_mind_canvas，不要一次塞满无关项目全文。

【非业务闲聊】不调用工具，只做普通回答。

【对用户说话的方式】用户多在语音场景使用本应用：回复要口语化、简短、像当面聊天，避免书面报告腔或念参数。确认日程时只说标题、日期时间、地点、提前多久提醒等用户关心的信息即可。

【禁止向用户暴露内部标识】任何日程 id（如 evt_…）、方块/白板 id、mind_block_… 等仅供你在需要时调用工具使用，禁止在回复里写出、朗读或强调；用户不需要也看不懂这些 id。"""

# 保留供测试或旧逻辑引用；/api/chat 已不再用其控制 tool_choice
INTENT_KEYWORDS = [
    "思维导图", "项目排期", "时间规划", "查日程", "看日程", "加入日程", "添加日程", "设置提醒",
    "思维节点", "白板", "排期", "日程", "看项目", "安排项目进程", "项目进展", "安排项目进展",
    "根据思维节点图安排项目进展", "开个会", "开会", "需要做什么", "安排一下",
]


def load_system_prompt() -> str:
    """从环境变量指定文件或默认内容加载（供独立脚本使用）。

    线上 `/api/chat` 项目助理实际使用 `api_only_app._resolve_abp_system_prompt()`：
    文件 → SQLite 后台保存 → 本模块 DEFAULT_SYSTEM_PROMPT。
    """
    path = os.getenv("HIBI_ABP_SYSTEM_PROMPT_FILE", "").strip()
    if path and os.path.isfile(path):
        try:
            with open(path, encoding="utf-8") as f:
                return f.read().strip() or DEFAULT_SYSTEM_PROMPT
        except Exception as e:
            logger.warning("读取 HIBI_ABP_SYSTEM_PROMPT_FILE 失败: %s，使用默认", e)
    return DEFAULT_SYSTEM_PROMPT


def intent_allows_tools(user_message: str) -> bool:
    """用户消息是否包含关键词（遗留接口；项目助理已不再用其控制 tool_choice）。"""
    if not (user_message or "").strip():
        return False
    msg = user_message.strip()
    return any(kw in msg for kw in INTENT_KEYWORDS)


def _block_summary_for_tool(b: dict) -> dict:
    """白板方块摘要：供模型排期；不含布局坐标（避免误改布局）。"""
    rs = b.get("reminderStartTimeMs")
    re = b.get("reminderEndTimeMs")
    has_rem = rs is not None and re is not None
    return {
        "id": b.get("id"),
        "text": (b.get("text") or "")[:2000],
        "completed": bool(b.get("completed")),
        "dotColor": b.get("dotColor"),
        "reminderStartTimeMs": rs,
        "reminderEndTimeMs": re,
        "hasReminder": has_rem,
    }


def _event_overlaps_date_range(e: dict, start_d: str, end_d: str) -> bool:
    """日程事件与 [start_d, end_d]（仅日期 YYYY-MM-DD）是否有交集。"""
    st = (e.get("startTime") or "")[:10]
    et_raw = e.get("endTime") or e.get("startTime") or ""
    et = (et_raw[:10]) if et_raw else st
    if not st:
        return False
    return not (et < start_d or st > end_d)


def get_tools_definitions() -> list:
    """返回 OpenAI/豆包兼容的 tools 数组（function calling）。"""
    return [
        {
            "type": "function",
            "function": {
                "name": "list_mind_projects",
                "description": "列出当前用户全部思维节点（项目）的 id 与标题。项目多时应先调用本工具，再选择与用户话题最相关的若干项目去 get_mind_canvas。",
                "parameters": {"type": "object", "properties": {}, "required": []},
            },
        },
        {
            "type": "function",
            "function": {
                "name": "get_mind_canvas",
                "description": "获取指定思维节点（项目）的白板：方块(block)与连线(line)。按 project_name 匹配项目标题；若用户指「当前项目」且未传名称，可传空 project_name（后端结合 current_mind_node_id）。",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "project_name": {
                            "type": "string",
                            "description": "项目标题，与思维节点名称完全一致；当前项目且无名称时可传空字符串",
                        },
                    },
                    "required": [],
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "get_schedule",
                "description": "查询用户在日期范围内的日程（与范围内日期有交集即返回）。若未传 start_date/end_date，则默认从「今天」起连续若干天（见 days）。",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "start_date": {"type": "string", "description": "开始日期，仅日期 YYYY-MM-DD，可选"},
                        "end_date": {"type": "string", "description": "结束日期，仅日期 YYYY-MM-DD，可选"},
                        "days": {
                            "type": "integer",
                            "description": "未指定起止日期时，从今天是第 1 天起共包含多少天，默认 7",
                            "default": 7,
                        },
                    },
                    "required": [],
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "create_schedule",
                "description": "创建一条日程。未传 reminder_minutes 时默认提前 "
                + str(DEFAULT_REMINDER_MINUTES)
                + " 分钟提醒。",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "title": {"type": "string", "description": "日程标题"},
                        "start_time": {"type": "string", "description": "开始时间 ISO8601"},
                        "end_time": {"type": "string", "description": "结束时间 ISO8601"},
                        "is_all_day": {"type": "boolean", "description": "是否全天", "default": False},
                        "location": {"type": "string", "description": "地点"},
                        "reminder_minutes": {
                            "type": "integer",
                            "description": f"提前多少分钟提醒；省略则用默认 {DEFAULT_REMINDER_MINUTES}",
                        },
                        "essence": {"type": "string", "description": "要义/要点"},
                    },
                    "required": ["title", "start_time", "end_time"],
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "update_schedule",
                "description": "在用户已明确同意时，按 id 更新一条已有日程（不得删除）。勿用于 id 以 mind_block_ 开头的方块关联日程。",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "event_id": {"type": "string", "description": "日程 id（evt_...）"},
                        "title": {"type": "string", "description": "新标题"},
                        "start_time": {"type": "string", "description": "新开始时间 ISO8601"},
                        "end_time": {"type": "string", "description": "新结束时间 ISO8601"},
                        "is_all_day": {"type": "boolean"},
                        "location": {"type": "string"},
                        "reminder_minutes": {"type": "integer"},
                        "essence": {"type": "string"},
                    },
                    "required": ["event_id"],
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "delete_schedule",
                "description": "删除普通日程（evt_...）。仅当用户明确要求删除且你已确认要删的是哪一条后使用。",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "event_id": {"type": "string", "description": "日程 id（evt_...）"},
                    },
                    "required": ["event_id"],
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "set_block_reminder",
                "description": "在尚无提醒的方块上设置提醒时间并同步一条 mind_block_ 日程。若方块已有提醒则拒绝覆盖，请改用其他方块或 create_schedule。",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "project_name": {
                            "type": "string",
                            "description": "项目标题；若与 current_mind_node_id 同时可用可二选一",
                        },
                        "block_id": {"type": "string", "description": "方块 id"},
                        "start_time": {"type": "string", "description": "提醒开始时间 ISO8601"},
                        "end_time": {"type": "string", "description": "提醒结束时间 ISO8601"},
                    },
                    "required": ["block_id", "start_time", "end_time"],
                },
            },
        },
    ]


def _get_mind(user_id: str, get_user_data) -> list:
    raw = get_user_data(user_id, "mind")
    if not raw:
        return []
    try:
        return json.loads(raw) if isinstance(raw, str) else raw
    except Exception:
        return []


def _normalize_iso_datetime(s: str) -> str:
    """LLM 可能返回 `2026-03-28 20:00:00`，与 Dart DateTime.parse 兼容性处理对齐。"""
    t = (s or "").strip()
    if len(t) >= 19 and t[10] == " ":
        t = t[:10] + "T" + t[11:]
    return t


def _get_schedule(user_id: str, get_user_data) -> list:
    raw = get_user_data(user_id, "schedule")
    if not raw:
        return []
    try:
        return json.loads(raw) if isinstance(raw, str) else raw
    except Exception:
        return []


def _save_schedule(user_id: str, events: list, save_user_data) -> None:
    save_user_data(user_id, "schedule", json.dumps(events, ensure_ascii=False))


def _save_mind(user_id: str, nodes: list, save_user_data) -> None:
    save_user_data(user_id, "mind", json.dumps(nodes, ensure_ascii=False))


def _mind_canvas_payload(node: dict) -> dict:
    items = node.get("canvasItems") or []
    blocks = [i for i in items if isinstance(i, dict) and i.get("type") == "block"]
    lines = [i for i in items if isinstance(i, dict) and i.get("type") == "line"]
    return {
        "project_id": node.get("id"),
        "project_title": node.get("title"),
        "blocks": [_block_summary_for_tool(b) for b in blocks],
        "lines": [{"id": l.get("id"), "fromId": l.get("fromId"), "toId": l.get("toId")} for l in lines],
    }


def execute_tool(
    name: str,
    arguments: dict,
    user_id: str,
    get_user_data,
    save_user_data,
    *,
    current_mind_node_id: Optional[str] = None,
) -> str:
    """执行工具并返回给模型的字符串结果。"""
    if name == "list_mind_projects":
        nodes = _get_mind(user_id, get_user_data)
        out = []
        for node in nodes:
            if not isinstance(node, dict):
                continue
            out.append({
                "id": node.get("id"),
                "title": (node.get("title") or "").strip(),
            })
        return json.dumps({"projects": out, "count": len(out)}, ensure_ascii=False, indent=2)

    if name == "get_mind_canvas":
        project_name = (arguments.get("project_name") or "").strip()
        nodes = _get_mind(user_id, get_user_data)
        for node in nodes:
            if not isinstance(node, dict):
                continue
            if project_name and (node.get("title") or "").strip() == project_name:
                return json.dumps(_mind_canvas_payload(node), ensure_ascii=False, indent=2)
            if current_mind_node_id and (node.get("id") == current_mind_node_id) and not project_name:
                return json.dumps(_mind_canvas_payload(node), ensure_ascii=False, indent=2)
        return json.dumps(
            {"error": f"未找到名为「{project_name}」的项目", "blocks": [], "lines": []},
            ensure_ascii=False,
        )

    if name == "get_schedule":
        days = arguments.get("days")
        try:
            ndays = max(1, int(days)) if days is not None else 7
        except (TypeError, ValueError):
            ndays = 7
        start_date = (arguments.get("start_date") or "").strip()[:10]
        end_date = (arguments.get("end_date") or "").strip()[:10]
        today = date.today()
        if not start_date or not end_date:
            start_date = today.isoformat()
            end_date = (today + timedelta(days=ndays - 1)).isoformat()
        events = _get_schedule(user_id, get_user_data)
        result = []
        for e in events:
            if not isinstance(e, dict):
                continue
            if e.get("isDeleted") is True:
                continue
            if not _event_overlaps_date_range(e, start_date, end_date):
                continue
            result.append({
                "id": e.get("id"),
                "title": e.get("title"),
                "startTime": e.get("startTime"),
                "endTime": e.get("endTime"),
                "isAllDay": e.get("isAllDay"),
                "reminderMinutes": e.get("reminderMinutes"),
                "location": e.get("location"),
            })
        meta = {"start_date": start_date, "end_date": end_date, "count": len(result)}
        return json.dumps({"meta": meta, "events": result}, ensure_ascii=False, indent=2)

    if name == "create_schedule":
        import uuid

        title = (arguments.get("title") or "").strip() or "未命名"
        start_time = _normalize_iso_datetime((arguments.get("start_time") or "").strip())
        end_time = _normalize_iso_datetime((arguments.get("end_time") or "").strip())
        if not start_time or not end_time:
            return json.dumps({"error": "start_time 与 end_time 必填"}, ensure_ascii=False)
        events = _get_schedule(user_id, get_user_data)
        event_id = "evt_" + uuid.uuid4().hex[:12]
        new_evt = {
            "id": event_id,
            "title": title,
            "startTime": start_time,
            "endTime": end_time,
            "isAllDay": arguments.get("is_all_day") is True,
            "recurrence": "none",
        }
        if arguments.get("location"):
            new_evt["location"] = str(arguments.get("location")).strip()
        if arguments.get("essence"):
            new_evt["essence"] = str(arguments.get("essence")).strip()
        if arguments.get("reminder_minutes") is not None:
            new_evt["reminderMinutes"] = int(arguments["reminder_minutes"])
        else:
            new_evt["reminderMinutes"] = DEFAULT_REMINDER_MINUTES
        events.append(new_evt)
        _save_schedule(user_id, events, save_user_data)
        # 不在工具结果中带 id，避免模型复述给用户；若需修改可先 get_schedule 再选条目
        return json.dumps(
            {
                "ok": True,
                "title": title,
                "startTime": start_time,
                "endTime": end_time,
                "reminderMinutes": new_evt.get("reminderMinutes"),
            },
            ensure_ascii=False,
        )

    if name == "update_schedule":
        event_id = (arguments.get("event_id") or "").strip()
        if not event_id:
            return json.dumps({"error": "event_id 必填"}, ensure_ascii=False)
        if event_id.startswith("mind_block_"):
            return json.dumps(
                {"error": "方块关联日程请通过 set_block_reminder 在无提醒方块上设置，勿直接 update_schedule"},
                ensure_ascii=False,
            )
        events = _get_schedule(user_id, get_user_data)
        idx = None
        for i, e in enumerate(events):
            if isinstance(e, dict) and e.get("id") == event_id:
                idx = i
                break
        if idx is None:
            return json.dumps({"error": f"未找到日程 id: {event_id}"}, ensure_ascii=False)
        ev = dict(events[idx])
        if ev.get("isDeleted") is True:
            return json.dumps({"error": "该日程已删除，无法修改"}, ensure_ascii=False)
        if arguments.get("title") is not None:
            ev["title"] = str(arguments.get("title")).strip()
        if arguments.get("start_time"):
            ev["startTime"] = str(arguments.get("start_time")).strip()
        if arguments.get("end_time"):
            ev["endTime"] = str(arguments.get("end_time")).strip()
        if arguments.get("is_all_day") is not None:
            ev["isAllDay"] = bool(arguments.get("is_all_day"))
        if arguments.get("location") is not None:
            loc = str(arguments.get("location")).strip()
            if loc:
                ev["location"] = loc
            else:
                ev.pop("location", None)
        if arguments.get("reminder_minutes") is not None:
            ev["reminderMinutes"] = int(arguments["reminder_minutes"])
        if arguments.get("essence") is not None:
            ess = str(arguments.get("essence")).strip()
            if ess:
                ev["essence"] = ess
            else:
                ev.pop("essence", None)
        events[idx] = ev
        _save_schedule(user_id, events, save_user_data)
        return json.dumps({"ok": True, "title": ev.get("title")}, ensure_ascii=False)

    if name == "delete_schedule":
        event_id = (arguments.get("event_id") or "").strip()
        if not event_id:
            return json.dumps({"error": "event_id 必填"}, ensure_ascii=False)
        if event_id.startswith("mind_block_"):
            return json.dumps({"error": "方块关联日程请在白板中清除提醒以移除"}, ensure_ascii=False)
        events = _get_schedule(user_id, get_user_data)
        idx = None
        for i, e in enumerate(events):
            if isinstance(e, dict) and e.get("id") == event_id:
                idx = i
                break
        if idx is None:
            return json.dumps({"error": f"未找到日程 id: {event_id}"}, ensure_ascii=False)
        ev = dict(events[idx])
        if ev.get("isDeleted") is True:
            return json.dumps({"ok": True, "alreadyDeleted": True}, ensure_ascii=False)
        ev["isDeleted"] = True
        ev["deletedAt"] = datetime.now().isoformat(timespec="seconds")
        events[idx] = ev
        _save_schedule(user_id, events, save_user_data)
        return json.dumps({"ok": True}, ensure_ascii=False)

    if name == "set_block_reminder":
        project_name = (arguments.get("project_name") or "").strip()
        block_id = (arguments.get("block_id") or "").strip()
        start_time = (arguments.get("start_time") or "").strip()
        end_time = (arguments.get("end_time") or "").strip()
        if not block_id or not start_time or not end_time:
            return json.dumps({"error": "block_id, start_time, end_time 必填"}, ensure_ascii=False)
        nodes = _get_mind(user_id, get_user_data)
        target = None
        for node in nodes:
            if not isinstance(node, dict):
                continue
            if project_name and (node.get("title") or "").strip() == project_name:
                target = node
                break
            if not project_name and current_mind_node_id and node.get("id") == current_mind_node_id:
                target = node
                break
        if target is None:
            return json.dumps(
                {"error": "未找到项目：请提供 project_name，或在对话上下文传入 current_mind_node_id"},
                ensure_ascii=False,
            )
        items = target.get("canvasItems") or []
        for i, item in enumerate(items):
            if not isinstance(item, dict) or item.get("type") != "block" or item.get("id") != block_id:
                continue
            rs = item.get("reminderStartTimeMs")
            re = item.get("reminderEndTimeMs")
            if rs is not None and re is not None:
                return json.dumps(
                    {
                        "error": "该方块已有提醒，不覆盖。可参考其时间在其它无提醒方块上设置提醒，或使用 create_schedule 新增独立日程。",
                        "block_id": block_id,
                        "existing_reminderStartTimeMs": rs,
                        "existing_reminderEndTimeMs": re,
                    },
                    ensure_ascii=False,
                )
            items[i] = dict(item)
            items[i]["reminderStartTimeMs"] = int(_parse_iso_to_ms(start_time))
            items[i]["reminderEndTimeMs"] = int(_parse_iso_to_ms(end_time))
            target["canvasItems"] = items
            _save_mind(user_id, nodes, save_user_data)
            events = _get_schedule(user_id, get_user_data)
            event_id = "mind_block_" + block_id
            title = (items[i].get("text") or "").strip() or "（无标题）"
            new_evt = {
                "id": event_id,
                "title": title,
                "startTime": start_time,
                "endTime": end_time,
                "isAllDay": False,
                "recurrence": "none",
                "reminderMinutes": DEFAULT_REMINDER_MINUTES,
            }
            events = [e for e in events if isinstance(e, dict) and e.get("id") != event_id]
            events.append(new_evt)
            _save_schedule(user_id, events, save_user_data)
            return json.dumps(
                {"ok": True, "block_id": block_id, "project_title": (target.get("title") or "").strip()},
                ensure_ascii=False,
            )
        return json.dumps({"error": f"未找到方块 {block_id}"}, ensure_ascii=False)

    return json.dumps({"error": f"未知工具: {name}"}, ensure_ascii=False)


def _parse_iso_to_ms(iso_str: str) -> float:
    try:
        dt = datetime.fromisoformat(iso_str.replace("Z", "+00:00"))
        return dt.timestamp() * 1000
    except Exception:
        return 0
