"""
服务增值支付：订单 + 订阅状态 + 自动续费策略（3 天宽限中断）。
"""
import os
import time
import logging
import sqlite3
import secrets
import urllib.parse
import base64
import json
from typing import Optional, Tuple, Dict, Any

logger = logging.getLogger(__name__)

_DATA_DIR = os.environ.get("HIBI_DATA_DIR", "").strip()
if _DATA_DIR:
    import os as _os
    _os.makedirs(_DATA_DIR, exist_ok=True)
    DB_PATH = os.path.join(_DATA_DIR, "hibi_users.db")
else:
    DB_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "hibi_users.db")

AUTO_RENEW_GRACE_DAYS = 3

# 套餐中心（后端真实价格/时长配置）
PLANS: Dict[str, Dict[str, Any]] = {
    "data_service": {
        "amount_cents": 100,
        "name": "数据服务",
        "price_label": "1元/季",
        "description": "三端实时同步，阿里云云备份，数据不丢失",
        "duration_days": 90,
        "is_pro": False,
        "is_basic": True,
    },
    "assistant_service": {
        "amount_cents": 200,
        "name": "助理服务",
        "price_label": "2元/季",
        "description": "接入主流 AI 模型，智能日程与项目安排",
        "duration_days": 90,
        "is_pro": False,
        "is_basic": True,
    },
    "theme_service": {
        "amount_cents": 100,
        "name": "主题服务",
        "price_label": "1元/季",
        "description": "解锁全部主题，含隐藏开发者主题",
        "duration_days": 90,
        "is_pro": False,
        "is_basic": True,
    },
    "pro_max": {
        "amount_cents": 1200,
        "name": "HIBI-PRO-MAX",
        "price_label": "12元/年",
        "description": "解锁数据服务、助理服务、主题服务全部功能",
        "duration_days": 365,
        "is_pro": True,
        "is_basic": False,
    },
    "pro_max_1tb": {
        "amount_cents": 10000,
        "name": "HIBI-PRO-MAX-1TB",
        "price_label": "100元/月",
        "description": "解锁全部服务，专享开发者下午茶",
        "duration_days": 30,
        "is_pro": True,
        "is_basic": False,
    },
    # 全功能试用：0 元、每账号仅一次、到期不可续订、不参与自动续费
    "trial_all": {
        "amount_cents": 0,
        "name": "试用",
        "price_label": "0元/半年",
        "description": "试用全部功能（每账号限一次，到期不可续订）",
        "duration_days": 182,
        "is_pro": False,
        "is_basic": False,
        "auto_renew": False,
        "is_trial": True,
    },
}

TRIAL_PLAN_ID = "trial_all"

BASIC_PLANS = tuple([pid for pid, cfg in PLANS.items() if cfg.get("is_basic")])
PRO_PLANS = ("pro_max", "pro_max_1tb")  # 从高到低


def _db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def _ensure_column(conn, table: str, column: str, ddl: str):
    try:
        conn.execute(f"ALTER TABLE {table} ADD COLUMN {column} {ddl}")
    except sqlite3.OperationalError:
        pass


def init_payment_db():
    with _db() as c:
        c.executescript("""
        CREATE TABLE IF NOT EXISTS payment_orders (
            id TEXT PRIMARY KEY,
            user_id TEXT NOT NULL,
            plan_id TEXT NOT NULL,
            amount_cents INTEGER NOT NULL,
            subject TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'pending',
            external_order_id TEXT,
            created_at REAL NOT NULL,
            paid_at REAL,
            notify_raw TEXT,
            valid_until REAL,
            pay_url TEXT,
            order_kind TEXT NOT NULL DEFAULT 'manual',
            source_order_id TEXT,
            fail_reason TEXT,
            FOREIGN KEY(user_id) REFERENCES users(id)
        );
        CREATE INDEX IF NOT EXISTS idx_payment_orders_user ON payment_orders(user_id);
        CREATE INDEX IF NOT EXISTS idx_payment_orders_status ON payment_orders(status);
        CREATE INDEX IF NOT EXISTS idx_payment_orders_user_plan ON payment_orders(user_id, plan_id);
        CREATE TABLE IF NOT EXISTS admin_plan_overrides (
            user_id TEXT NOT NULL,
            plan_id TEXT NOT NULL,
            forced_status TEXT NOT NULL,
            forced_valid_until REAL,
            forced_grace_until REAL,
            note TEXT,
            updated_at REAL NOT NULL,
            PRIMARY KEY(user_id, plan_id)
        );
        CREATE INDEX IF NOT EXISTS idx_admin_plan_overrides_user ON admin_plan_overrides(user_id);
        """)
        _ensure_column(c, "payment_orders", "valid_until", "REAL")
        _ensure_column(c, "payment_orders", "pay_url", "TEXT")
        _ensure_column(c, "payment_orders", "order_kind", "TEXT NOT NULL DEFAULT 'manual'")
        _ensure_column(c, "payment_orders", "source_order_id", "TEXT")
        _ensure_column(c, "payment_orders", "fail_reason", "TEXT")
        c.execute("CREATE INDEX IF NOT EXISTS idx_payment_orders_kind ON payment_orders(order_kind)")


def _shujie_env():
    return {
        "submit_url": os.getenv("SHUJIEPAY_SUBMIT_URL", "").strip(),
        "notify_url": os.getenv("SHUJIEPAY_NOTIFY_URL", "").strip(),
        "return_url": os.getenv("SHUJIEPAY_RETURN_URL", "").strip(),
        "mch_id": os.getenv("SHUJIEPAY_MCH_ID", "").strip(),
        "mch_private_key": os.getenv("SHUJIEPAY_MCH_PRIVATE_KEY", "").strip(),
        "default_type": os.getenv("SHUJIEPAY_DEFAULT_TYPE", "alipay").strip(),
        # SDK_2.0 示例固定 sign_type=RSA，但签名摘要算法仍是 SHA256。
        "sign_type": os.getenv("SHUJIEPAY_SIGN_TYPE", "RSA").strip(),
        "sign_hash": os.getenv("SHUJIEPAY_SIGN_HASH", "SHA256").strip(),
        # 仅在历史网关兼容时开启（0/1）。
        "legacy_rsa_sha1_fallback": os.getenv("SHUJIEPAY_LEGACY_RSA_SHA1_FALLBACK", "0").strip(),
    }


def _normalize_private_key_pem(raw_key: str) -> bytes:
    k = (raw_key or "").strip()
    if "\\n" in k:
        k = k.replace("\\n", "\n")
    if "BEGIN" in k and "END" in k:
        return k.encode("utf-8")
    body = "".join([line.strip() for line in k.splitlines() if line.strip()])
    wrapped = "\n".join(body[i:i + 64] for i in range(0, len(body), 64))
    pem = f"-----BEGIN PRIVATE KEY-----\n{wrapped}\n-----END PRIVATE KEY-----"
    return pem.encode("utf-8")


def _normalize_public_key_pem(raw_key: str) -> bytes:
    k = (raw_key or "").strip()
    if "\\n" in k:
        k = k.replace("\\n", "\n")
    if "BEGIN" in k and "END" in k:
        return k.encode("utf-8")
    body = "".join([line.strip() for line in k.splitlines() if line.strip()])
    wrapped = "\n".join(body[i:i + 64] for i in range(0, len(body), 64))
    pem = f"-----BEGIN PUBLIC KEY-----\n{wrapped}\n-----END PUBLIC KEY-----"
    return pem.encode("utf-8")


def _sign_content_for_gateway(params: Dict[str, Any]) -> str:
    items = []
    for k in sorted(params.keys()):
        v = params.get(k)
        if k in ("sign", "sign_type"):
            continue
        if v is None:
            continue
        sv = str(v).strip()
        if not sv:
            continue
        items.append(f"{k}={sv}")
    return "&".join(items)


def _build_query_url_from_submit(submit_url: str) -> str:
    u = (submit_url or "").strip()
    if not u:
        return ""
    if "/api/pay/submit" in u:
        return u.replace("/api/pay/submit", "/api/pay/query")
    if u.endswith("/"):
        return f"{u}api/pay/query"
    return f"{u}/api/pay/query"


def _safe_json_parse(text: str) -> Optional[dict]:
    try:
        data = json.loads(text or "{}")
        if isinstance(data, dict):
            return data
    except Exception:
        return None
    return None


def _looks_paid_status(value: str) -> bool:
    v = (value or "").strip().lower()
    return v in {
        "1", "success", "succeed", "succeeded", "paid", "pay_success", "trade_success", "finished", "complete",
        "00", "0000", "02",
    }


def _extract_paid_from_query_response(data: dict) -> Tuple[bool, str]:
    # 兼容多种返回结构：顶层/嵌套 data/info/order 中的 status/trade_status 等
    def pick(container: dict, key: str) -> Optional[str]:
        if not isinstance(container, dict):
            return None
        v = container.get(key)
        if v is None:
            return None
        return str(v).strip()

    nodes = [data]
    for k in ("data", "info", "order", "result"):
        v = data.get(k)
        if isinstance(v, dict):
            nodes.append(v)
    status_keys = ("status", "trade_status", "pay_status", "state", "bizSts", "result_code", "code")
    trade_keys = ("trade_no", "transaction_id", "platform_order_no", "channel_order_no", "order_no")

    for node in nodes:
        for sk in status_keys:
            s = pick(node, sk)
            if s and _looks_paid_status(s):
                ext = ""
                for tk in trade_keys:
                    tv = pick(node, tk)
                    if tv:
                        ext = tv
                        break
                return True, ext
    return False, ""


def _try_sync_order_from_gateway(order_id: str, trade_no_hint: str = "") -> bool:
    """当本地订单 pending 时，主动查网关状态并尽量自动入账，减少手动补单。"""
    env = _shujie_env()
    query_url = _build_query_url_from_submit(env.get("submit_url") or "")
    mch_id = env.get("mch_id") or ""
    mch_private_key = env.get("mch_private_key") or ""
    if not query_url or not mch_id or not mch_private_key:
        return False
    try:
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import padding
        from cryptography.hazmat.backends import default_backend
        import httpx

        key = serialization.load_pem_private_key(
            _normalize_private_key_pem(mch_private_key),
            password=None,
            backend=default_backend(),
        )

        base = {
            "pid": mch_id,
            "timestamp": str(int(time.time())),
            "sign_type": "RSA",  # SDK2 默认 sign_type=RSA，摘要算法仍为 SHA256
        }
        candidates = []
        if trade_no_hint:
            candidates.append({"trade_no": trade_no_hint})
        candidates.extend([
            {"trade_no": order_id},     # 部分网关允许用商户单号查询
            {"out_trade_no": order_id}, # 兼容字段
        ])
        for extra in candidates:
            params = {**base, **extra}
            sign_source = _sign_content_for_gateway(params)
            signature = key.sign(sign_source.encode("utf-8"), padding.PKCS1v15(), hashes.SHA256())
            params["sign"] = base64.b64encode(signature).decode("ascii")
            try:
                resp = httpx.post(query_url, data=params, timeout=10.0)
                data = _safe_json_parse(resp.text)
                if not data:
                    continue
                paid, ext_trade = _extract_paid_from_query_response(data)
                if paid:
                    return update_order_paid(order_id, ext_trade)
            except Exception:
                continue
    except Exception:
        return False
    return False


def reconcile_order_with_gateway(order_id: str, trade_no_hint: str = "") -> bool:
    """公开给路由层调用：用网关查询结果尝试补齐本地 pending 订单。"""
    return _try_sync_order_from_gateway(order_id, trade_no_hint=trade_no_hint)


def _plan(plan_id: str) -> Optional[Dict[str, Any]]:
    return PLANS.get(plan_id)


def _serialize_plan(plan_id: str) -> Dict[str, Any]:
    cfg = PLANS[plan_id]
    return {
        "plan_id": plan_id,
        "name": cfg["name"],
        "description": cfg.get("description") or "",
        "amount_cents": int(cfg["amount_cents"]),
        "amount": round(int(cfg["amount_cents"]) / 100.0, 2),
        "price_label": cfg.get("price_label") or "",
        "duration_days": int(cfg["duration_days"]),
        "is_pro": bool(cfg.get("is_pro")),
        "is_basic": bool(cfg.get("is_basic")),
        "auto_renew": bool(cfg.get("auto_renew", True)),
        "grace_days_after_renewal_failure": AUTO_RENEW_GRACE_DAYS,
        "is_trial": bool(cfg.get("is_trial")),
    }


def get_public_plan_catalog() -> Dict[str, Any]:
    return {
        "plans": [_serialize_plan(pid) for pid in PLANS.keys()],
        "auto_renew": True,
        "grace_days_after_renewal_failure": AUTO_RENEW_GRACE_DAYS,
    }


def user_has_completed_trial(user_id: str) -> bool:
    """是否曾有过试用订单（含已过期），用于「每账号仅一次」。"""
    with _db() as c:
        r = c.execute(
            """SELECT 1 FROM payment_orders
               WHERE user_id = ? AND plan_id = ? AND status = 'paid' LIMIT 1""",
            (user_id, TRIAL_PLAN_ID),
        ).fetchone()
        return r is not None


def create_order(user_id: str, plan_id: str, pay_type: Optional[str] = None) -> Optional[dict]:
    """手动创建订单（用户点击订阅）。"""
    return _create_order_internal(
        user_id,
        plan_id,
        order_kind="manual",
        source_order_id=None,
        allow_fallback_pay_page=True,
        pay_type=pay_type,
    )


def _create_order_internal(
    user_id: str,
    plan_id: str,
    order_kind: str,
    source_order_id: Optional[str],
    allow_fallback_pay_page: bool,
    pay_type: Optional[str] = None,
) -> Optional[dict]:
    cfg = _plan(plan_id)
    if not cfg:
        return None
    amount_cents = int(cfg["amount_cents"])
    subject = cfg["name"]

    # ---------- 全功能试用：0 元立即入账，不走路由收银台；每账号仅一次 ----------
    if plan_id == TRIAL_PLAN_ID:
        if user_has_completed_trial(user_id):
            return {
                "error": "trial_already_used",
                "message": "每个账号仅可试用一次，试用资格已使用或已过期",
            }
        if amount_cents != 0:
            return None
        order_id = "hibi_" + secrets.token_hex(12)
        now = time.time()
        with _db() as c:
            c.execute(
                """INSERT INTO payment_orders
                   (id, user_id, plan_id, amount_cents, subject, status, created_at, pay_url, order_kind, source_order_id, fail_reason)
                   VALUES (?,?,?,?,?,?,?,?,?,?,?)""",
                (
                    order_id,
                    user_id,
                    plan_id,
                    0,
                    subject,
                    "pending",
                    now,
                    None,
                    order_kind,
                    source_order_id,
                    None,
                ),
            )
        if not update_order_paid(order_id, external_order_id="trial_zero"):
            return None
        row = get_order(order_id, user_id=user_id)
        vu = row.get("valid_until") if row else None
        return {
            "order_id": order_id,
            "pay_url": "",
            "amount": 0.0,
            "amount_cents": 0,
            "subject": subject,
            "plan_id": plan_id,
            "status": "paid",
            "order_kind": order_kind,
            "auto_renew": False,
            "immediate": True,
            "valid_until": vu,
        }

    order_id = "hibi_" + secrets.token_hex(12)
    now = time.time()
    pay_url = ""
    fail_reason = None

    env = _shujie_env()
    if env["submit_url"] and env["notify_url"] and env["mch_id"] and env["mch_private_key"]:
        try:
            pay_url = _build_shujiepay_order(
                submit_url=env["submit_url"],
                mch_id=env["mch_id"],
                mch_private_key=env["mch_private_key"],
                out_trade_no=order_id,
                amount_cents=amount_cents,
                subject=subject,
                notify_url=env["notify_url"],
                return_url=env["return_url"],
                pay_type=pay_type,
                sign_type=env["sign_type"],
                sign_hash=env["sign_hash"],
                legacy_rsa_sha1_fallback=env["legacy_rsa_sha1_fallback"],
            )
        except Exception as e:
            logger.exception("数捷下单请求失败: %s", e)
            fail_reason = f"submit_error:{str(e)[:120]}"
    else:
        fail_reason = "shujie_env_not_ready"

    if not pay_url and allow_fallback_pay_page:
        base_url = os.getenv("HIBI_BASE_URL", "http://121.41.6.21:7861").strip().rstrip("/")
        pay_url = f"{base_url}/api/payment/pay_page?order_id={order_id}"

    status = "pending" if pay_url else "failed"
    with _db() as c:
        c.execute(
            """INSERT INTO payment_orders
               (id, user_id, plan_id, amount_cents, subject, status, created_at, pay_url, order_kind, source_order_id, fail_reason)
               VALUES (?,?,?,?,?,?,?,?,?,?,?)""",
            (
                order_id,
                user_id,
                plan_id,
                amount_cents,
                subject,
                status,
                now,
                pay_url or None,
                order_kind,
                source_order_id,
                fail_reason,
            ),
        )

    return {
        "order_id": order_id,
        "pay_url": pay_url or "",
        "amount": amount_cents / 100.0,
        "amount_cents": amount_cents,
        "subject": subject,
        "plan_id": plan_id,
        "status": status,
        "order_kind": order_kind,
        "auto_renew": order_kind == "renewal",
    }


def _build_shujiepay_order(
    submit_url: str,
    mch_id: str,
    mch_private_key: str,
    out_trade_no: str,
    amount_cents: int,
    subject: str,
    notify_url: str,
    return_url: str,
    pay_type: Optional[str] = None,
    sign_type: str = "RSA",
    sign_hash: str = "SHA256",
    legacy_rsa_sha1_fallback: str = "0",
) -> str:
    """
    兼容两种数捷接入形式：
    1) SDK2 页面跳转：/api/pay/submit（返回可直接打开的 URL）
    2) V2 API 下单：POST 提交后解析 pay_url/pay_data/url
    """
    try:
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import padding
        from cryptography.hazmat.backends import default_backend
    except ImportError:
        logger.warning("未安装 cryptography，无法调用数捷下单")
        return ""

    def _normalize_private_key(raw_key: str) -> bytes:
        k = (raw_key or "").strip()
        if "\\n" in k:
            k = k.replace("\\n", "\n")
        if "BEGIN" in k and "END" in k:
            return k.encode("utf-8")
        body = "".join([line.strip() for line in k.splitlines() if line.strip()])
        wrapped = "\n".join(body[i:i + 64] for i in range(0, len(body), 64))
        pem = f"-----BEGIN PRIVATE KEY-----\n{wrapped}\n-----END PRIVATE KEY-----"
        return pem.encode("utf-8")

    def _sign_content(params: Dict[str, Any]) -> str:
        items = []
        for k in sorted(params.keys()):
            v = params.get(k)
            if k in ("sign", "sign_type"):
                continue
            if v is None:
                continue
            sv = str(v).strip()
            if not sv:
                continue
            items.append(f"{k}={sv}")
        return "&".join(items)

    def _append_return_order_params(raw_url: str, oid: str) -> str:
        base = (raw_url or "").strip()
        if not base:
            return ""
        try:
            parsed = urllib.parse.urlparse(base)
            q = dict(urllib.parse.parse_qsl(parsed.query, keep_blank_values=True))
            if "order_id" not in q:
                q["order_id"] = oid
            if "out_trade_no" not in q:
                q["out_trade_no"] = oid
            rebuilt = parsed._replace(query=urllib.parse.urlencode(q))
            return urllib.parse.urlunparse(rebuilt)
        except Exception:
            sep = "&" if "?" in base else "?"
            return f"{base}{sep}order_id={urllib.parse.quote(oid)}&out_trade_no={urllib.parse.quote(oid)}"

    timestamp = str(int(time.time()))
    selected_pay_type = (pay_type or "").strip().lower()
    allowed_types = {"alipay", "wxpay", "qqpay", "bank", "jdpay"}
    if selected_pay_type not in allowed_types:
        selected_pay_type = os.getenv("SHUJIEPAY_DEFAULT_TYPE", "alipay").strip().lower() or "alipay"
    if selected_pay_type not in allowed_types:
        selected_pay_type = "alipay"

    key = serialization.load_pem_private_key(
        _normalize_private_key(mch_private_key),
        password=None,
        backend=default_backend(),
    )
    import base64

    import httpx
    lower_url = submit_url.lower()

    def _money_variants(cents: int) -> list[str]:
        fixed = f"{cents / 100.0:.2f}"
        compact = fixed.rstrip("0").rstrip(".")
        return [fixed] if fixed == compact else [fixed, compact]

    def _normalize_sign_type(raw: str) -> str:
        st = (raw or "").strip().upper()
        if st in ("RSA", "SHA1WITHRSA", "SHA1_WITH_RSA"):
            return "RSA"
        if st in ("SHA256WITHRSA", "SHA256_WITH_RSA"):
            return "SHA256WithRSA"
        return "SHA256WithRSA"

    def _normalize_sign_hash(raw: str) -> str:
        sh = (raw or "").strip().upper()
        if sh in ("SHA1", "SHA-1"):
            return "SHA1"
        return "SHA256"

    def _build_submit_url(money_value: str, sign_type_value: str, sign_hash_value: str) -> str:
        sdk_params = {
            "pid": mch_id,
            "out_trade_no": out_trade_no,
            "name": subject,
            "money": money_value,
            "type": selected_pay_type,
            "notify_url": notify_url,
            "return_url": resolved_return_url,
            "timestamp": timestamp,
        }
        sign_source = _sign_content(sdk_params)
        digest = hashes.SHA1() if sign_hash_value == "SHA1" else hashes.SHA256()
        signature = key.sign(sign_source.encode("utf-8"), padding.PKCS1v15(), digest)
        sdk_params["sign"] = base64.b64encode(signature).decode("ascii")
        sdk_params["sign_type"] = sign_type_value
        return f"{submit_url}?{urllib.parse.urlencode(sdk_params)}"

    def _build_submit_params(money_value: str, sign_type_value: str, sign_hash_value: str) -> Dict[str, str]:
        sdk_params = {
            "pid": mch_id,
            "out_trade_no": out_trade_no,
            "name": subject,
            "money": money_value,
            "type": selected_pay_type,
            "notify_url": notify_url,
            "return_url": resolved_return_url,
            "timestamp": timestamp,
        }
        sign_source = _sign_content(sdk_params)
        digest = hashes.SHA1() if sign_hash_value == "SHA1" else hashes.SHA256()
        signature = key.sign(sign_source.encode("utf-8"), padding.PKCS1v15(), digest)
        sdk_params["sign"] = base64.b64encode(signature).decode("ascii")
        sdk_params["sign_type"] = sign_type_value
        return sdk_params

    preferred_sign_type = _normalize_sign_type(sign_type)
    preferred_sign_hash = _normalize_sign_hash(sign_hash)
    enable_legacy_sha1 = str(legacy_rsa_sha1_fallback).strip().lower() in ("1", "true", "yes", "on")

    def _looks_sign_failed(text: str) -> bool:
        t = (text or "").strip()
        if not t:
            return False
        hints = (
            "RSA签名校验失败",
            "签名校验失败",
            "签名错误",
            "invalid sign",
            "验签失败",
        )
        low = t.lower()
        return any(h.lower() in low for h in hints)

    # SDK2 文档要求 return_url 不带自定义 query；否则回跳验签可能失败。
    resolved_return_url = (return_url or notify_url).strip()

    # SDK2 主流程：直接拼接 submit 链接，前端可立即拉起浏览器（Windows/移动端一致）
    if "/api/pay/submit" in lower_url:
        # 优先使用配置的签名算法；仅在显式开启时尝试 RSA+SHA1 历史兼容。
        candidates = []
        for mv in _money_variants(amount_cents):
            candidates.append((mv, preferred_sign_type, preferred_sign_hash))
            if preferred_sign_type != "SHA256WithRSA" or preferred_sign_hash != "SHA256":
                candidates.append((mv, "SHA256WithRSA", "SHA256"))
            if preferred_sign_type != "RSA" or preferred_sign_hash != "SHA256":
                candidates.append((mv, "RSA", "SHA256"))
            if enable_legacy_sha1:
                candidates.append((mv, "RSA", "SHA1"))

        first_url = ""
        selected_params: Optional[Dict[str, str]] = None
        for mv, st, sh in candidates:
            params = _build_submit_params(mv, st, sh)
            url = f"{submit_url}?{urllib.parse.urlencode(params)}"
            if not first_url:
                first_url = url
                selected_params = params
            try:
                # 按 SDK 页面提交流程做预检：POST form 到 submit，检查是否仍提示验签失败。
                resp = httpx.post(submit_url, data=params, timeout=8.0, follow_redirects=True)
                if _looks_sign_failed(resp.text):
                    logger.warning("数捷 submit 预检签名失败，尝试下一组参数: sign_type=%s money=%s hash=%s", st, mv, sh)
                    continue
                selected_params = params
                break
            except Exception:
                # 网络或站点波动不阻断下单，继续尝试下一组；最终至少返回首个候选。
                continue
        if not selected_params:
            # 保底从首个 URL 解析参数，避免空返回。
            q = urllib.parse.urlparse(first_url).query
            selected_params = {k: (v[-1] if isinstance(v, list) else v)
                               for k, v in urllib.parse.parse_qs(q).items()}
        # 与 SDK 的 pagePay 一致：先打开我方页面，再自动 POST 到 submit。
        base_url = os.getenv("HIBI_BASE_URL", "http://121.41.6.21:7861").strip().rstrip("/")
        post_payload = {
            "submit_url": submit_url,
            "params": selected_params,
        }
        packed = base64.urlsafe_b64encode(
            json.dumps(post_payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        ).decode("ascii").rstrip("=")
        return f"{base_url}/api/payment/pay_page?order_id={out_trade_no}&mode=shujie_post&p={urllib.parse.quote(packed)}"

    # V2 API 流程：尝试直接提交并解析返回 JSON
    api_params = {
        "mch_id": mch_id,
        "out_trade_no": out_trade_no,
        "total_fee": str(amount_cents),
        "subject": subject,
        "notify_url": notify_url,
        "return_url": resolved_return_url,
        "timestamp": timestamp,
    }
    api_sign_source = _sign_content(api_params)
    api_signature = key.sign(api_sign_source.encode("utf-8"), padding.PKCS1v15(), hashes.SHA256())
    api_params["sign"] = base64.b64encode(api_signature).decode("ascii")
    api_params["sign_type"] = "SHA256WithRSA"

    sdk_like_params = {
        "pid": mch_id,
        "out_trade_no": out_trade_no,
        "name": subject,
        "money": f"{amount_cents / 100.0:.2f}",
        "type": selected_pay_type,
        "notify_url": notify_url,
        "return_url": resolved_return_url,
        "timestamp": timestamp,
    }
    sdk_like_sign_source = _sign_content(sdk_like_params)
    sdk_like_signature = key.sign(sdk_like_sign_source.encode("utf-8"), padding.PKCS1v15(), hashes.SHA256())
    sdk_like_params["sign"] = base64.b64encode(sdk_like_signature).decode("ascii")
    sdk_like_params["sign_type"] = "SHA256WithRSA"

    # 优先使用 SDK2 参数提交（兼容某些站点 create 也支持 pid/money），失败再回退到 v2 参数。
    for post_data in (sdk_like_params, api_params):
        try:
            resp = httpx.post(submit_url, data=post_data, timeout=15.0)
            resp.raise_for_status()
            data = resp.json()
        except Exception:
            continue
        pay_url = (data.get("pay_url") or data.get("pay_data") or data.get("url") or "").strip()
        if not pay_url and isinstance(data.get("pay_data"), dict):
            pay_url = (data["pay_data"].get("pay_url") or data["pay_data"].get("url") or "").strip()
        if not pay_url and isinstance(data.get("data"), dict):
            pay_url = (data["data"].get("pay_url") or data["data"].get("url") or "").strip()
        if pay_url:
            return pay_url

    return ""


def get_order(order_id: str, user_id: Optional[str] = None) -> Optional[dict]:
    with _db() as c:
        if user_id:
            row = c.execute(
                """SELECT id, user_id, plan_id, amount_cents, subject, status, created_at, paid_at,
                          valid_until, pay_url, order_kind, source_order_id, fail_reason
                   FROM payment_orders WHERE id = ? AND user_id = ?""",
                (order_id, user_id),
            ).fetchone()
        else:
            row = c.execute(
                """SELECT id, user_id, plan_id, amount_cents, subject, status, created_at, paid_at,
                          valid_until, pay_url, order_kind, source_order_id, fail_reason
                   FROM payment_orders WHERE id = ?""",
                (order_id,),
            ).fetchone()
    if not row:
        return None
    if row["status"] == "pending":
        # 支付成功但回调偶发丢失时，查询订单接口触发一次主动对账，尽量自动入账。
        if _try_sync_order_from_gateway(order_id):
            return get_order(order_id, user_id=user_id)
    return {
        "order_id": row["id"],
        "plan_id": row["plan_id"],
        "amount_cents": row["amount_cents"],
        "amount": round((row["amount_cents"] or 0) / 100.0, 2),
        "subject": row["subject"],
        "status": row["status"],
        "created_at": row["created_at"],
        "paid_at": row["paid_at"],
        "valid_until": row["valid_until"],
        "pay_url": row["pay_url"],
        "order_kind": row["order_kind"],
        "source_order_id": row["source_order_id"],
        "fail_reason": row["fail_reason"],
    }


def _mark_order_failed(order_id: str, reason: str = "") -> bool:
    with _db() as c:
        cur = c.execute(
            "UPDATE payment_orders SET status = 'failed', fail_reason = ? WHERE id = ? AND status = 'pending'",
            (reason[:200] if reason else None, order_id),
        )
        return cur.rowcount > 0


def update_order_paid(order_id: str, external_order_id: str = "") -> bool:
    now = time.time()
    with _db() as c:
        row = c.execute(
            "SELECT user_id, plan_id FROM payment_orders WHERE id = ? AND status = 'pending'",
            (order_id,),
        ).fetchone()
        if not row:
            return False
        user_id = row["user_id"]
        plan_id = row["plan_id"]
        days = int((_plan(plan_id) or {}).get("duration_days") or 0)
        active_row = c.execute(
            """SELECT MAX(valid_until) AS latest_active_until
               FROM payment_orders
               WHERE user_id = ? AND plan_id = ? AND status = 'paid' AND valid_until IS NOT NULL AND valid_until > ?""",
            (user_id, plan_id, now),
        ).fetchone()
        anchor = active_row["latest_active_until"] if active_row and active_row["latest_active_until"] else now
        valid_until = (float(anchor) + days * 86400) if days else None
        cur = c.execute(
            """UPDATE payment_orders
               SET status = 'paid', paid_at = ?, external_order_id = ?, valid_until = ?, fail_reason = NULL
               WHERE id = ? AND status = 'pending'""",
            (now, external_order_id or None, valid_until, order_id),
        )
        return cur.rowcount > 0


def save_notify_raw(order_id: str, raw: str):
    with _db() as c:
        c.execute("UPDATE payment_orders SET notify_raw = ? WHERE id = ?", (raw[:2000] if raw else None, order_id))


def _get_latest_paid(c, user_id: str, plan_id: str):
    return c.execute(
        """SELECT id, valid_until, paid_at
           FROM payment_orders
           WHERE user_id = ? AND plan_id = ? AND status = 'paid'
           ORDER BY paid_at DESC
           LIMIT 1""",
        (user_id, plan_id),
    ).fetchone()


def _get_latest_renewal_attempt(c, user_id: str, plan_id: str, min_created_at: float):
    return c.execute(
        """SELECT id, status, created_at, pay_url, fail_reason
           FROM payment_orders
           WHERE user_id = ? AND plan_id = ? AND order_kind = 'renewal' AND created_at >= ?
           ORDER BY created_at DESC
           LIMIT 1""",
        (user_id, plan_id, min_created_at),
    ).fetchone()


def _get_admin_override(c, user_id: str, plan_id: str):
    return c.execute(
        """SELECT forced_status, forced_valid_until, forced_grace_until, note, updated_at
           FROM admin_plan_overrides
           WHERE user_id = ? AND plan_id = ?""",
        (user_id, plan_id),
    ).fetchone()


def _ensure_renewal_attempts(user_id: str):
    """懒执行自动续费：发现已到期且无续费尝试时，自动创建一笔 renewal 订单。"""
    now = time.time()
    with _db() as c:
        for plan_id in PLANS.keys():
            pm = _plan(plan_id) or {}
            if plan_id == TRIAL_PLAN_ID or not pm.get("auto_renew", True):
                continue
            paid = _get_latest_paid(c, user_id, plan_id)
            if not paid:
                continue
            valid_until = paid["valid_until"] or 0
            if valid_until >= now:
                continue
            renewal = _get_latest_renewal_attempt(c, user_id, plan_id, valid_until)
            if renewal:
                continue
            # 自动续费尝试不走 pay_page 兜底，避免误判；下单失败即记录 failed，进入宽限/中断判断
            _create_order_internal(
                user_id=user_id,
                plan_id=plan_id,
                order_kind="renewal",
                source_order_id=paid["id"],
                allow_fallback_pay_page=False,
                pay_type=None,
            )


def _plan_state_from_rows(c, user_id: str, plan_id: str, now: float) -> Dict[str, Any]:
    override = _get_admin_override(c, user_id, plan_id)
    if override:
        forced_status = (override["forced_status"] or "").strip()
        forced_valid_until = override["forced_valid_until"]
        forced_grace_until = override["forced_grace_until"]
        base = {
            "plan_id": plan_id,
            "status": forced_status if forced_status else "inactive",
            "auto_renew": True,
            "remaining_seconds": 0,
            "valid_until": forced_valid_until,
            "grace_until": forced_grace_until,
            "admin_override": True,
            "override_note": override["note"] or "",
            "override_updated_at": override["updated_at"],
        }
        if forced_status in ("active", "included_by_pro"):
            base["remaining_seconds"] = int(max(0, (forced_valid_until or 0) - now))
        if forced_status == "grace":
            base["grace_remaining_seconds"] = int(max(0, (forced_grace_until or 0) - now))
        return base

    paid = _get_latest_paid(c, user_id, plan_id)
    if not paid:
        return {
            "plan_id": plan_id,
            "status": "inactive",
            "auto_renew": True,
            "remaining_seconds": 0,
            "valid_until": None,
            "grace_until": None,
            "renewal_order_id": None,
            "renewal_pay_url": None,
            "admin_override": False,
        }

    valid_until = paid["valid_until"] or 0
    plan_meta = _plan(plan_id) or {}
    plan_auto_renew = bool(plan_meta.get("auto_renew", True))

    if plan_id == TRIAL_PLAN_ID:
        if valid_until >= now:
            return {
                "plan_id": plan_id,
                "status": "active",
                "auto_renew": False,
                "remaining_seconds": int(valid_until - now),
                "valid_until": valid_until,
                "grace_until": None,
                "renewal_order_id": None,
                "renewal_pay_url": None,
                "admin_override": False,
            }
        return {
            "plan_id": plan_id,
            "status": "trial_expired",
            "auto_renew": False,
            "remaining_seconds": 0,
            "valid_until": valid_until,
            "grace_until": None,
            "grace_remaining_seconds": 0,
            "renewal_order_id": None,
            "renewal_pay_url": None,
            "admin_override": False,
        }

    if valid_until >= now:
        return {
            "plan_id": plan_id,
            "status": "active",
            "auto_renew": plan_auto_renew,
            "remaining_seconds": int(valid_until - now),
            "valid_until": valid_until,
            "grace_until": None,
            "renewal_order_id": None,
            "renewal_pay_url": None,
            "admin_override": False,
        }

    grace_until = valid_until + AUTO_RENEW_GRACE_DAYS * 86400
    renewal = _get_latest_renewal_attempt(c, user_id, plan_id, valid_until)
    renewal_id = renewal["id"] if renewal else None
    renewal_pay_url = renewal["pay_url"] if renewal else None

    if now <= grace_until:
        return {
            "plan_id": plan_id,
            "status": "grace",  # 到期后 3 天宽限，等待续费成功
            "auto_renew": True,
            "remaining_seconds": 0,
            "valid_until": valid_until,
            "grace_until": grace_until,
            "grace_remaining_seconds": int(grace_until - now),
            "renewal_order_id": renewal_id,
            "renewal_pay_url": renewal_pay_url,
            "admin_override": False,
        }

    return {
        "plan_id": plan_id,
        "status": "interrupted",  # 宽限期后中断
        "auto_renew": True,
        "remaining_seconds": 0,
        "valid_until": valid_until,
        "grace_until": grace_until,
        "grace_remaining_seconds": 0,
        "renewal_order_id": renewal_id,
        "renewal_pay_url": renewal_pay_url,
        "admin_override": False,
    }


def get_user_entitlements(user_id: str) -> dict:
    """
    返回会员总览 + 每个套餐的实时状态（供前端展示剩余时间/订阅状态）。
    状态枚举：active / included_by_pro / grace / interrupted / inactive
    """
    _ensure_renewal_attempts(user_id)
    now = time.time()
    with _db() as c:
        state_map = {pid: _plan_state_from_rows(c, user_id, pid, now) for pid in PLANS.keys()}

    # PRO 最高档判定（仅 active）
    pro = None
    pro_valid_until = None
    for pid in PRO_PLANS:
        s = state_map[pid]
        if s["status"] == "active":
            pro = pid
            pro_valid_until = s["valid_until"]
            break

    # 基础服务若无直购 active，但 PRO active，则展示为 included_by_pro
    for pid in BASIC_PLANS:
        s = state_map[pid]
        if pro and s["status"] != "active" and not s.get("admin_override"):
            s["status"] = "included_by_pro"
            s["valid_until"] = pro_valid_until
            s["remaining_seconds"] = int(max(0, (pro_valid_until or 0) - now))
            s["included_by"] = pro

    trial_active = state_map.get(TRIAL_PLAN_ID, {}).get("status") == "active"

    basic_plans = []
    if pro:
        basic_plans = list(BASIC_PLANS)
    elif trial_active:
        basic_plans = list(BASIC_PLANS)
    else:
        for pid in BASIC_PLANS:
            if state_map[pid]["status"] == "active":
                basic_plans.append(pid)

    trial_consumed = user_has_completed_trial(user_id)

    # 展示用剩余时长：全功能试用与单项订阅并行时，基础三项卡片「剩余」= 该项剩余 + 试用剩余（仅展示，不改变订单 valid_until）
    trial_rem = 0
    if trial_active:
        ts = state_map.get(TRIAL_PLAN_ID) or {}
        trial_rem = int(ts.get("remaining_seconds") or 0)
    for pid in PLANS.keys():
        s = state_map[pid]
        rem = int(s.get("remaining_seconds") or 0)
        if pid == TRIAL_PLAN_ID:
            s["display_remaining_seconds"] = rem
        elif pid in BASIC_PLANS and trial_active and trial_rem > 0:
            s["display_remaining_seconds"] = rem + trial_rem
        else:
            s["display_remaining_seconds"] = rem

    return {
        "pro": pro,
        "basic_plans": basic_plans,
        "pro_valid_until": pro_valid_until,
        "plan_configs": [_serialize_plan(pid) for pid in PLANS.keys()],
        "plans": [state_map[pid] for pid in PLANS.keys()],
        "auto_renew": True,
        "grace_days_after_renewal_failure": AUTO_RENEW_GRACE_DAYS,
        "server_now": now,
        "trial_consumed": trial_consumed,
        "trial_active": trial_active,
    }


def admin_upsert_plan_override(
    user_id: str,
    plan_id: str,
    status: str,
    remaining_days: Optional[int] = None,
    note: str = "",
) -> bool:
    """管理员强制设置单套餐状态。status: active/inactive/grace/interrupted"""
    if plan_id not in PLANS:
        return False
    status = (status or "").strip().lower()
    if status not in ("active", "inactive", "grace", "interrupted"):
        return False
    now = time.time()
    forced_valid_until = None
    forced_grace_until = None
    if status == "active":
        days = remaining_days if isinstance(remaining_days, int) and remaining_days > 0 else int(PLANS[plan_id]["duration_days"])
        forced_valid_until = now + days * 86400
    elif status == "grace":
        days = remaining_days if isinstance(remaining_days, int) and remaining_days > 0 else AUTO_RENEW_GRACE_DAYS
        forced_valid_until = now - 1
        forced_grace_until = now + days * 86400
    with _db() as c:
        c.execute(
            """INSERT INTO admin_plan_overrides
               (user_id, plan_id, forced_status, forced_valid_until, forced_grace_until, note, updated_at)
               VALUES (?,?,?,?,?,?,?)
               ON CONFLICT(user_id, plan_id) DO UPDATE SET
                 forced_status=excluded.forced_status,
                 forced_valid_until=excluded.forced_valid_until,
                 forced_grace_until=excluded.forced_grace_until,
                 note=excluded.note,
                 updated_at=excluded.updated_at""",
            (user_id, plan_id, status, forced_valid_until, forced_grace_until, (note or "").strip() or None, now),
        )
    return True


def admin_clear_plan_override(user_id: str, plan_id: str) -> bool:
    if plan_id not in PLANS:
        return False
    with _db() as c:
        c.execute("DELETE FROM admin_plan_overrides WHERE user_id = ? AND plan_id = ?", (user_id, plan_id))
        return c.rowcount > 0


def admin_list_customers(keyword: str = "", limit: int = 200, offset: int = 0) -> dict:
    kw = (keyword or "").strip().lower()
    limit = max(1, min(500, int(limit or 200)))
    offset = max(0, int(offset or 0))
    where_sql = ""
    args = []
    if kw:
        where_sql = "WHERE lower(u.phone_or_email) LIKE ? OR lower(COALESCE(u.nickname,'')) LIKE ? OR lower(u.id) LIKE ?"
        like = f"%{kw}%"
        args.extend([like, like, like])
    sql_total = f"SELECT COUNT(1) AS cnt FROM users u {where_sql}"
    sql_rows = f"""
        SELECT
          u.id, u.phone_or_email, u.nickname, u.created_at,
          u.created_ip, u.created_geo, u.last_login_at, u.last_login_ip, u.last_login_geo,
          COALESCE(SUM(CASE WHEN p.status='paid' THEN p.amount_cents ELSE 0 END),0) AS total_spent_cents
        FROM users u
        LEFT JOIN payment_orders p ON p.user_id = u.id
        {where_sql}
        GROUP BY u.id
        ORDER BY u.created_at DESC
        LIMIT ? OFFSET ?
    """
    with _db() as c:
        total = c.execute(sql_total, tuple(args)).fetchone()["cnt"]
        rows = c.execute(sql_rows, tuple(args + [limit, offset])).fetchall()
    out = []
    for r in rows:
        ent = get_user_entitlements(r["id"])
        out.append({
            "user_id": r["id"],
            "phone_or_email": r["phone_or_email"],
            "nickname": r["nickname"] or "",
            "created_at": r["created_at"],
            "created_ip": r["created_ip"],
            "created_geo": r["created_geo"],
            "last_login_at": r["last_login_at"],
            "last_login_ip": r["last_login_ip"],
            "last_login_geo": r["last_login_geo"],
            "total_spent_cents": int(r["total_spent_cents"] or 0),
            "total_spent_amount": round(int(r["total_spent_cents"] or 0) / 100.0, 2),
            "entitlements": ent,
        })
    return {
        "total": int(total or 0),
        "limit": limit,
        "offset": offset,
        "items": out,
    }


def get_payment_config_status() -> dict:
    """返回数捷相关环境变量是否已配置（仅键名，不返回具体值），便于跑通自检。"""
    keys = (
        "SHUJIEPAY_SUBMIT_URL",
        "SHUJIEPAY_NOTIFY_URL",
        "SHUJIEPAY_MCH_ID",
        "SHUJIEPAY_MCH_PRIVATE_KEY",
        "SHUJIEPAY_PLATFORM_PUBLIC_KEY",
        "HIBI_BASE_URL",
    )
    status = {k: bool(os.getenv(k, "").strip()) for k in keys}
    status["ready"] = all((
        status["SHUJIEPAY_SUBMIT_URL"],
        status["SHUJIEPAY_NOTIFY_URL"],
        status["SHUJIEPAY_MCH_ID"],
        status["SHUJIEPAY_MCH_PRIVATE_KEY"],
        status["SHUJIEPAY_PLATFORM_PUBLIC_KEY"],
    ))
    return status


def verify_notify_and_update(form_dict: dict) -> Tuple[bool, str]:
    """验签并更新订单；返回 (是否成功, order_id 或错误信息)。"""
    order_id = (form_dict.get("out_trade_no") or form_dict.get("order_id") or form_dict.get("mch_order_no") or "").strip()
    if not order_id:
        return False, "missing out_trade_no"

    platform_public_key = os.getenv("SHUJIEPAY_PLATFORM_PUBLIC_KEY", "").strip()
    if platform_public_key:
        if "\\n" in platform_public_key:
            platform_public_key = platform_public_key.replace("\\n", "\n")
        sign = (form_dict.get("sign") or "").strip().replace(" ", "+")
        if not sign:
            return False, "missing sign"
        try:
            from cryptography.hazmat.primitives import hashes, serialization
            from cryptography.hazmat.primitives.asymmetric import padding
            from cryptography.hazmat.backends import default_backend
            import base64
            exclude = {"sign", "sign_type", "order_id"}
            param_str = "&".join(
                f"{k}={form_dict[k]}"
                for k in sorted(form_dict.keys())
                if k not in exclude and form_dict.get(k) not in (None, "")
            )
            key = serialization.load_pem_public_key(
                _normalize_public_key_pem(platform_public_key),
                backend=default_backend(),
            )
            signature = base64.b64decode(sign)
            sign_type = (form_dict.get("sign_type") or "").strip().upper()
            verify_ok = False
            try:
                key.verify(signature, param_str.encode("utf-8"), padding.PKCS1v15(), hashes.SHA256())
                verify_ok = True
            except Exception:
                # 兼容少量历史网关的 RSA(SHA1) 回调，仅在 sign_type 指向 RSA 时再尝试。
                if sign_type in ("RSA", "SHA1WITHRSA", "SHA1_WITH_RSA"):
                    key.verify(signature, param_str.encode("utf-8"), padding.PKCS1v15(), hashes.SHA1())
                    verify_ok = True
            if not verify_ok:
                raise ValueError("sign verify failed")
        except Exception as e:
            logger.exception("验签失败: %s", e)
            # 回调验签失败不直接将订单标记 failed，避免后续合法重试回调无法入账。
            return False, "sign verify failed"
    else:
        logger.warning("未配置 SHUJIEPAY_PLATFORM_PUBLIC_KEY，按测试模式处理回调")

    # 兼容不同网关/版本的状态字段命名：
    # - trade_status/status/pay_status: success/paid/trade_success...
    # - bizSts: 02=成功, 03=失败（部分一码付/聚合通道）
    # - respCode/code/result_code: 0000/00/success 等
    raw_statuses = [
        form_dict.get("trade_status"),
        form_dict.get("status"),
        form_dict.get("pay_status"),
        form_dict.get("bizSts"),
        form_dict.get("biz_status"),
        form_dict.get("result"),
        form_dict.get("result_code"),
        form_dict.get("respCode"),
        form_dict.get("code"),
        form_dict.get("state"),
    ]
    statuses = [(str(v).strip().lower()) for v in raw_statuses if v is not None and str(v).strip()]
    status_set = set(statuses)

    success_values = {
        "success", "succeed", "succeeded", "paid", "pay_success", "trade_success", "finished", "complete",
        "1", "00", "0000", "02",
    }
    failed_values = {
        "fail", "failed", "closed", "close", "cancel", "canceled", "cancelled", "expired", "timeout",
        "03",
    }

    is_success = bool(status_set & success_values)
    is_failed = bool(status_set & failed_values)
    biz_sts = (form_dict.get("bizSts") or form_dict.get("biz_status") or "").strip()
    if biz_sts == "02":
        is_success = True
    elif biz_sts == "03":
        is_failed = True

    external_trade_id = (
        form_dict.get("trade_no")
        or form_dict.get("transaction_id")
        or form_dict.get("channel_order_no")
        or form_dict.get("platform_order_no")
        or form_dict.get("orderNo")
        or ""
    )

    if is_success:
        if update_order_paid(order_id, external_trade_id):
            return True, order_id
        return False, "order not found or already handled"
    if is_failed:
        _mark_order_failed(order_id, f"trade_status:{','.join(statuses)[:120]}")
        return False, "trade_status failed"
    # 中间态不改订单，等待后续成功/失败回调
    return False, "trade_status not final"
