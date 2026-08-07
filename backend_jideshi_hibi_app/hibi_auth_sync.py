"""
希比 HIBI 用户注册/登录与用户数据同步（思维节点、日程、助理）。
- 注册需邀请码（与常量 INVITE_CODE 一致）
- SQLite 存储用户与三份 JSON 同步数据；登录后前端拉取，退出/切换前推送
"""
import os
import json
import sqlite3
import hashlib
import secrets
import time
from typing import Optional

# 邀请码：仅注册时校验，写死可后续改为环境变量或表内多码
INVITE_CODE = "tsinghibi2024"

# 数据库路径：默认在脚本同目录；若设环境变量 HIBI_DATA_DIR（如 Docker 挂载 /app/data），
# 则库文件落在该目录，容器删掉重建时只要卷还在，用户与同步数据就不会丢。
_DATA_DIR = os.environ.get("HIBI_DATA_DIR", "").strip()
if _DATA_DIR:
    os.makedirs(_DATA_DIR, exist_ok=True)
    DB_PATH = os.path.join(_DATA_DIR, "hibi_users.db")
else:
    DB_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "hibi_users.db")
TOKEN_EXPIRE_SECONDS = 60 * 60 * 24 * 30  # 30 天


def _db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def init_db():
    with _db() as c:
        c.executescript("""
        CREATE TABLE IF NOT EXISTS users (
            id TEXT PRIMARY KEY,
            phone_or_email TEXT UNIQUE NOT NULL,
            password_hash TEXT NOT NULL,
            salt TEXT NOT NULL,
            nickname TEXT,
            created_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS sessions (
            token TEXT PRIMARY KEY,
            user_id TEXT NOT NULL,
            created_at REAL NOT NULL,
            FOREIGN KEY(user_id) REFERENCES users(id)
        );
        CREATE TABLE IF NOT EXISTS user_data (
            user_id TEXT NOT NULL,
            data_key TEXT NOT NULL,
            payload TEXT NOT NULL,
            updated_at REAL NOT NULL,
            PRIMARY KEY(user_id, data_key),
            FOREIGN KEY(user_id) REFERENCES users(id)
        );
        """)
        # 兼容旧表：补充客户管理所需元数据字段
        try:
            c.execute("ALTER TABLE users ADD COLUMN created_ip TEXT")
        except sqlite3.OperationalError:
            pass
        try:
            c.execute("ALTER TABLE users ADD COLUMN created_geo TEXT")
        except sqlite3.OperationalError:
            pass
        try:
            c.execute("ALTER TABLE users ADD COLUMN last_login_at REAL")
        except sqlite3.OperationalError:
            pass
        try:
            c.execute("ALTER TABLE users ADD COLUMN last_login_ip TEXT")
        except sqlite3.OperationalError:
            pass
        try:
            c.execute("ALTER TABLE users ADD COLUMN last_login_geo TEXT")
        except sqlite3.OperationalError:
            pass
        try:
            c.execute("ALTER TABLE users ADD COLUMN avatar_url TEXT")
        except sqlite3.OperationalError:
            pass


def _hash_password(password: str, salt: str) -> str:
    return hashlib.sha256((salt + password).encode("utf-8")).hexdigest()


def create_user(phone_or_email: str, password: str, nickname: Optional[str]) -> str:
    user_id = secrets.token_hex(16)
    salt = secrets.token_hex(16)
    pw_hash = _hash_password(password, salt)
    now = time.time()
    with _db() as c:
        c.execute(
            "INSERT INTO users (id, phone_or_email, password_hash, salt, nickname, created_at) VALUES (?,?,?,?,?,?)",
            (user_id, phone_or_email.strip().lower(), pw_hash, salt, (nickname or "").strip() or None, now),
        )
    return user_id


def verify_user(phone_or_email: str, password: str) -> Optional[str]:
    with _db() as c:
        row = c.execute(
            "SELECT id, password_hash, salt FROM users WHERE phone_or_email = ?",
            (phone_or_email.strip().lower(),),
        ).fetchone()
    if not row:
        return None
    if _hash_password(password, row["salt"]) != row["password_hash"]:
        return None
    return row["id"]


def create_session(user_id: str) -> str:
    token = secrets.token_urlsafe(32)
    now = time.time()
    with _db() as c:
        c.execute("INSERT INTO sessions (token, user_id, created_at) VALUES (?,?,?)", (token, user_id, now))
    return token


def get_user_id_from_token(token: str) -> Optional[str]:
    if not token:
        return None
    with _db() as c:
        row = c.execute(
            "SELECT user_id, created_at FROM sessions WHERE token = ?", (token,)
        ).fetchone()
    if not row:
        return None
    if time.time() - row["created_at"] > TOKEN_EXPIRE_SECONDS:
        with _db() as c:
            c.execute("DELETE FROM sessions WHERE token = ?", (token,))
        return None
    return row["user_id"]


def delete_session(token: str):
    with _db() as c:
        c.execute("DELETE FROM sessions WHERE token = ?", (token,))


def get_user_profile(user_id: str) -> Optional[dict]:
    with _db() as c:
        row = c.execute(
            "SELECT id, phone_or_email, nickname, avatar_url FROM users WHERE id = ?", (user_id,)
        ).fetchone()
    if not row:
        return None
    return {
        "user_id": row["id"],
        "phone_or_email": row["phone_or_email"],
        "nickname": row["nickname"] or "",
        "avatar_url": row["avatar_url"] or "",
    }


def update_user_profile(user_id: str, nickname: Optional[str] = None, avatar_url: Optional[str] = None) -> Optional[dict]:
    sets = []
    args = []
    if nickname is not None:
        sets.append("nickname = ?")
        args.append((nickname or "").strip() or None)
    if avatar_url is not None:
        sets.append("avatar_url = ?")
        args.append((avatar_url or "").strip() or None)
    if sets:
        with _db() as c:
            c.execute(f"UPDATE users SET {', '.join(sets)} WHERE id = ?", (*args, user_id))
    return get_user_profile(user_id)


def touch_user_login_meta(
    user_id: str,
    ip: Optional[str] = None,
    geo: Optional[str] = None,
    set_created_if_empty: bool = False,
):
    """记录用户登录 IP/定位；可在注册时补充首次注册来源。"""
    now = time.time()
    with _db() as c:
        c.execute(
            "UPDATE users SET last_login_at = ?, last_login_ip = ?, last_login_geo = ? WHERE id = ?",
            (now, (ip or "").strip() or None, (geo or "").strip() or None, user_id),
        )
        if set_created_if_empty:
            c.execute(
                """UPDATE users
                   SET created_ip = COALESCE(created_ip, ?),
                       created_geo = COALESCE(created_geo, ?)
                   WHERE id = ?""",
                ((ip or "").strip() or None, (geo or "").strip() or None, user_id),
            )


def save_user_data(user_id: str, data_key: str, payload: str):
    now = time.time()
    with _db() as c:
        c.execute(
            """INSERT INTO user_data (user_id, data_key, payload, updated_at)
               VALUES (?,?,?,?)
               ON CONFLICT(user_id, data_key) DO UPDATE SET payload=excluded.payload, updated_at=excluded.updated_at""",
            (user_id, data_key, payload, now),
        )


def get_user_data(user_id: str, data_key: str) -> Optional[str]:
    with _db() as c:
        row = c.execute(
            "SELECT payload FROM user_data WHERE user_id = ? AND data_key = ?",
            (user_id, data_key),
        ).fetchone()
    return row["payload"] if row else None
