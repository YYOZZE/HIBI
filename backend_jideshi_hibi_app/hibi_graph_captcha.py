"""
阿里云图形认证（Alicaptcha / initAlicom4）服务端二次校验。

官方文档：
- H5 接入（ct4.js）：https://help.aliyun.com/zh/pnvs/developer-reference/integrate-the-sdk-with-h5-pages
- 服务端二次校验：https://help.aliyun.com/zh/pnvs/developer-reference/graphical-authentication-server-integration
- 控制台（方案与 appId/appKey）：https://dypns.console.aliyun.com/graphSolution

控制台方案与默认 appId（方案编码 FG* 仅供运维对照，请求接口只使用 appId）：

| 用途        | 方案名称        | 方案编码              |
|------------|-----------------|-----------------------|
| win 端 H5  | hibi23h52       | FG000000009822094004 |
| 鸿蒙       | hibi23hm2       | FG000000009772444004 |
| iOS        | hibi23pg2       | FG000000009702314004 |
| 安卓       | hibi23az2       | FG000000009851764004 |
"""
from __future__ import annotations

import hashlib
import hmac
import os
from typing import Dict, Optional, Tuple

import httpx

_API_URL = "https://captcha.alicaptcha.com/validate"

# 与控制台表一致；生产建议用环境变量 GRAPH_CAPTCHA_* 覆盖，避免密钥常驻仓库。
_DEFAULTS = {
    "web": {
        "app_id": "7cbe038048b4be54f004373f63ca3a86",
        "app_key": "ec5e2503f96f2c791313194ca095839f",
    },
    "harmony": {
        "app_id": "38b49eb185433cc60cf9fae64eba26b0",
        "app_key": "f5f52cc329c3fddbb4cd46934d809f88",
    },
    "ios": {
        "app_id": "ae43dbbddb3eb925f81a47da7cf460b7",
        "app_key": "ee90f83c78598ac152ee8ab80efaf238",
    },
    "android": {
        "app_id": "114c902dbd26b325b8a5359cac5d13b1",
        "app_key": "19aa380e6185999e209c1c4aa9df8eb2",
    },
}


def _normalize_platform(platform: Optional[str]) -> str:
    p = (platform or "").strip().lower()
    if p in ("android", "ios", "web", "harmony"):
        return p
    if p in ("鸿蒙", "hmos", "ohos"):
        return "harmony"
    if p in ("h5", "win_h5", "windows_h5"):
        return "web"
    return "web"


def _env_key(name: str, platform: str) -> str:
    return f"GRAPH_CAPTCHA_{platform.upper()}_{name.upper()}"


def _config(platform: Optional[str] = None) -> dict:
    p = _normalize_platform(platform)
    d = _DEFAULTS[p]
    sdk_url = (
        os.environ.get(_env_key("sdk_url", p))
        or os.environ.get("GRAPH_CAPTCHA_SDK_URL")
        or ""
    ).strip()
    return {
        "platform": p,
        "app_id": (os.environ.get(_env_key("app_id", p)) or os.environ.get("GRAPH_CAPTCHA_APP_ID") or d["app_id"]).strip(),
        "app_key": (os.environ.get(_env_key("app_key", p)) or os.environ.get("GRAPH_CAPTCHA_APP_KEY") or d["app_key"]).strip(),
        "sdk_url": sdk_url,
    }


def is_configured(platform: Optional[str] = None) -> bool:
    cfg = _config(platform)
    return bool(cfg["app_id"] and cfg["app_key"])


def public_config(platform: Optional[str] = None) -> dict:
    cfg = _config(platform)
    return {
        "configured": bool(cfg["app_id"] and cfg["app_key"]),
        "platform": cfg["platform"],
        "app_id": cfg["app_id"] if cfg["app_id"] else "",
        "sdk_url": cfg["sdk_url"],
    }


def verify(payload: Dict[str, str], platform: Optional[str] = None) -> Tuple[bool, str]:
    """
    校验图形认证参数。
    payload 应包含：lot_number/captcha_output/pass_token/gen_time。
    返回：(是否通过, 原因)。
    """
    if not is_configured(platform):
        return False, "图形认证未配置"

    lot_number = (payload.get("lot_number") or "").strip()
    captcha_output = (payload.get("captcha_output") or "").strip()
    pass_token = (payload.get("pass_token") or "").strip()
    gen_time = (payload.get("gen_time") or "").strip()
    if not lot_number or not captcha_output or not pass_token or not gen_time:
        return False, "图形认证参数不完整"

    cfg = _config(platform)
    sign_token = hmac.new(
        cfg["app_key"].encode("utf-8"),
        lot_number.encode("utf-8"),
        digestmod=hashlib.sha256,
    ).hexdigest()

    form = {
        "lot_number": lot_number,
        "captcha_output": captcha_output,
        "pass_token": pass_token,
        "gen_time": gen_time,
        "sign_token": sign_token,
    }
    # 推荐将 captcha_id 放在 query，便于日志定位。
    url = f"{_API_URL}?captcha_id={cfg['app_id']}"
    try:
        resp = httpx.post(
            url,
            data=form,
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            timeout=6.0,
        )
        if resp.status_code != 200:
            return False, f"图形认证服务异常({resp.status_code})"
        body = resp.json()
        if body.get("status") == "success" and body.get("result") == "success":
            return True, ""
        reason = (body.get("reason") or body.get("msg") or "图形认证未通过").strip()
        return False, reason
    except Exception as e:
        return False, f"图形认证校验异常: {str(e)[:80]}"
