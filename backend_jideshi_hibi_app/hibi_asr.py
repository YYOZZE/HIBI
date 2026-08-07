"""
希比 HIBI 语音转文字：对接火山引擎豆包语音「大模型流式语音识别」SAUC WebSocket。

协议层与官方示例 `sauc_python/sauc_websocket_demo.py` 对齐，见 `hibi_sauc_protocol.py`。
文档：https://www.volcengine.com/docs/6561/1354869

环境变量（在 ECS .env 中配置）：
- ASR_APP_ID / ASR_TOKEN（推荐）或 ASR_APP_KEY / ASR_ACCESS_KEY（兼容）
- ASR_RESOURCE_ID、ASR_WS_URL 等见 ASR语音识别配置说明.md

请求：POST multipart WAV 文件，16kHz 16bit 单声道；返回 {"text": "识别结果"}。
"""
from __future__ import annotations

import os
import json
import logging
import asyncio
from typing import Any, Dict, List, Optional, Tuple

import aiohttp

import hibi_sauc_protocol as _sauc

logger = logging.getLogger(__name__)

DEFAULT_SAMPLE_RATE = 16000
ASR_WS_URL = os.getenv("ASR_WS_URL", "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream").strip()
if ASR_WS_URL.endswith("/bigmodel"):
    ASR_WS_URL = ASR_WS_URL.rstrip("/") + "_nostream"
ASR_RESOURCE_ID = os.getenv("ASR_RESOURCE_ID", "volc.bigasr.sauc.duration").strip() or "volc.bigasr.sauc.duration"


def _asr_enabled() -> bool:
    return os.getenv("ASR_ENABLED", "true").strip().lower() not in ("0", "false", "no", "off")


def _first_non_empty(*keys: str) -> str:
    for key in keys:
        value = os.environ.get(key, "").strip()
        if value:
            return value
    return ""


def get_asr_credentials() -> Tuple[str, str]:
    app_id = _first_non_empty("ASR_APP_ID", "ASR_APP_KEY")
    token = _first_non_empty("ASR_TOKEN", "ASR_ACCESS_KEY")
    return app_id, token


def _include_connect_id_header() -> bool:
    """官方 demo 无此头；旧版 HIBI 曾发送。默认开启以兼容已部署 ECS，可设 ASR_INCLUDE_CONNECT_ID=0 关闭。"""
    v = (os.environ.get("ASR_INCLUDE_CONNECT_ID") or "1").strip().lower()
    return v not in ("0", "false", "no", "off")


def _asr_user_uid() -> str:
    return (os.environ.get("ASR_USER_UID") or "hibi_asr").strip() or "hibi_asr"


def _new_auth_headers(app_key: str, access_key: str, swap_keys: bool = False) -> Dict[str, str]:
    return _sauc.build_auth_headers(
        app_key,
        access_key,
        ASR_RESOURCE_ID,
        swap_keys=swap_keys,
        include_connect_id=_include_connect_id_header(),
    )


def _new_full_client_request(seq: int) -> bytes:
    return _sauc.new_full_client_request(
        seq,
        uid=_asr_user_uid(),
        sample_rate=DEFAULT_SAMPLE_RATE,
        model_name="bigmodel",
        enable_nonstream=False,
    )


def _new_stream_full_client_request(seq: int) -> bytes:
    return _new_full_client_request(seq)


def _new_audio_only_request(seq: int, segment: bytes, is_last: bool) -> bytes:
    return _sauc.new_audio_only_request(seq, segment, is_last)


def _parse_response(msg: bytes) -> Dict[str, Any]:
    r = _sauc.ResponseParser.parse_response(msg)
    return _sauc.asr_response_to_legacy_dict(r)


def _read_wav_info(data: bytes) -> Tuple[int, int, int, int, bytes]:
    return _sauc.CommonUtils.read_wav_info(data)


def _extract_text_from_payload(payload: Optional[Dict]) -> str:
    if not payload:
        return ""
    for key in (
        "asr_text",
        "text",
        "transcript",
        "sentence",
        "content",
        "recognition_text",
        "result_text",
        "utterance",
    ):
        v = payload.get(key)
        if isinstance(v, str) and v.strip():
            return v.strip()
    # 豆包/火山常见：result 为嵌套对象或数组
    r = payload.get("result")
    if isinstance(r, dict):
        nested = _extract_text_from_payload(r)
        if nested:
            return nested
    if isinstance(r, str) and r.strip():
        return r.strip()
    if isinstance(r, list):
        parts: List[str] = []
        for item in r:
            if isinstance(item, dict):
                parts.append(_extract_text_from_payload(item))
            elif isinstance(item, str):
                parts.append(item)
        if parts:
            return "".join(parts).strip()
    results = payload.get("results")
    if isinstance(results, list):
        parts: List[str] = []
        for item in results:
            if isinstance(item, dict):
                parts.append(_extract_text_from_payload(item))
            elif isinstance(item, str):
                parts.append(item.strip())
        joined = "".join(parts).strip()
        if joined:
            return joined

    utterances = payload.get("utterances") or payload.get("segments")
    if isinstance(utterances, list):
        parts = []
        for u in utterances:
            if isinstance(u, dict):
                parts.append((u.get("text") or u.get("content") or "").strip())
            elif isinstance(u, str):
                parts.append(u.strip())
        if parts:
            return "".join(parts).strip()
    return ""


def payload_is_final(payload: Optional[Dict[str, Any]]) -> bool:
    if not isinstance(payload, dict):
        return False
    for key in ("is_final", "final", "definite", "is_end", "last"):
        v = payload.get(key)
        if isinstance(v, bool) and v:
            return True
        if isinstance(v, (int, float, str)) and str(v).strip().lower() in ("1", "true", "yes", "final"):
            return True
    utterances = payload.get("utterances")
    if isinstance(utterances, list):
        for u in utterances:
            if isinstance(u, dict):
                for key in ("definite", "is_final", "final"):
                    vv = u.get(key)
                    if isinstance(vv, bool) and vv:
                        return True
    return False


def get_stream_ws_url() -> str:
    base = ASR_WS_URL.strip()
    if base.endswith("_nostream"):
        return base[: -len("_nostream")]
    return base


def get_stream_ws_candidates() -> List[str]:
    """
    仅用于 /api/asr/stream 流式识别。候选中不得包含 bigmodel_nostream：
    该路径面向「非流式整包」协议，用作流式握手时常见 HTTP 400 / Invalid response status。
    """
    urls: List[str] = []
    preferred = get_stream_ws_url().strip()
    if preferred:
        urls.append(preferred)
    if preferred.endswith("/bigmodel"):
        urls.append(preferred + "_async")
    if preferred.endswith("/bigmodel_async"):
        urls.append(preferred[: -len("_async")])
    base = ASR_WS_URL.strip()
    if base:
        if base.endswith("_nostream"):
            stem = base[: -len("_nostream")]
            urls.append(stem + "_async")
            urls.append(stem)
        else:
            urls.append(base)
            if base.endswith("/bigmodel"):
                urls.append(base + "_async")
    dedup: List[str] = []
    seen = set()
    for u in urls:
        if not u or u in seen:
            continue
        seen.add(u)
        dedup.append(u)
    return dedup


def is_asr_configured() -> bool:
    app_id, token = get_asr_credentials()
    return _asr_enabled() and bool(app_id and token)


async def run_asr(wav_bytes: bytes) -> str:
    app_id, token = get_asr_credentials()
    if not app_id or not token:
        raise RuntimeError("ASR 未配置（需 ASR_APP_ID/ASR_TOKEN 或 ASR_APP_KEY/ASR_ACCESS_KEY）")
    swap_keys = os.environ.get("ASR_SWAP_KEYS", "").strip().lower() in ("1", "true", "yes")
    if len(wav_bytes) < 44:
        raise ValueError("音频过短")
    try:
        num_channels, samp_width, sample_rate, _, wave_data = _read_wav_info(wav_bytes)
    except Exception as e:
        raise ValueError(f"无效 WAV: {e}") from e

    segment_duration_ms = int(os.environ.get("ASR_SEGMENT_MS", "200") or "200")
    size_per_sec = num_channels * samp_width * sample_rate
    segment_size = max(1, size_per_sec * segment_duration_ms // 1000)
    segments = [wave_data[i : i + segment_size] for i in range(0, len(wave_data), segment_size)]
    if not segments:
        return ""

    texts: List[str] = []
    seq = 1
    headers = _new_auth_headers(app_id, token, swap_keys=swap_keys)

    async with aiohttp.ClientSession() as session:
        try:
            ws = await session.ws_connect(
                ASR_WS_URL, headers=headers, timeout=aiohttp.ClientTimeout(total=30)
            )
        except aiohttp.ClientError as e:
            logger.exception("ASR WebSocket 建连失败: %s", e)
            raise RuntimeError(
                f"语音服务连接失败，请检查 ASR_APP_ID/ASR_TOKEN（或 ASR_APP_KEY/ASR_ACCESS_KEY）及网络: {e!s}"
            ) from e
        async with ws:
            await ws.send_bytes(_new_full_client_request(seq))
            seq += 1
            msg = await ws.receive()
            if msg.type == aiohttp.WSMsgType.ERROR:
                raise RuntimeError(f"ASR WebSocket 错误: {ws.exception() or '未知'}")
            if msg.type == aiohttp.WSMsgType.CLOSE:
                raise RuntimeError("ASR 服务端关闭连接，请检查控制台 APP ID 与 Access Token 是否正确")
            if msg.type != aiohttp.WSMsgType.BINARY:
                raise RuntimeError("ASR 首包非二进制")
            first = _parse_response(msg.data)
            code = first.get("code")
            if code is not None and code != 0:
                payload = first.get("payload_msg") or {}
                err_msg = payload.get("message") or payload.get("msg") or str(code)
                logger.warning("ASR 服务返回错误: code=%s payload=%s", code, payload)
                raise RuntimeError(f"语音识别失败({code}): {err_msg}")

            for i, seg in enumerate(segments):
                is_last = i == len(segments) - 1
                await ws.send_bytes(_new_audio_only_request(seq, seg, is_last))
                if not is_last:
                    seq += 1
                await asyncio.sleep(segment_duration_ms / 1000.0)

            while True:
                try:
                    msg = await asyncio.wait_for(ws.receive(), timeout=10.0)
                except asyncio.TimeoutError:
                    break
                if msg.type == aiohttp.WSMsgType.BINARY:
                    resp = _parse_response(msg.data)
                    if resp.get("payload_msg"):
                        t = _extract_text_from_payload(resp["payload_msg"])
                        if t:
                            texts.append(t)
                    if resp.get("is_last") or (resp.get("code") and resp["code"] != 0):
                        break
                elif msg.type in (aiohttp.WSMsgType.CLOSE, aiohttp.WSMsgType.ERROR):
                    break

    return "".join(texts).strip()
