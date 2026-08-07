"""
豆包语音 SAUC WebSocket 二进制协议（与官方 sauc_python/sauc_websocket_demo.py 对齐）。

来源：火山引擎「大模型流式语音识别」Python 示例。
文档：https://www.volcengine.com/docs/6561/1354869

本模块仅实现协议编解码，不包含业务环境变量读取；由 hibi_asr 注入鉴权与资源 ID。
"""
from __future__ import annotations

import json
import struct
import gzip
import uuid
from typing import Any, Dict, List, Optional, Tuple

# ---------- 与官方 demo 一致的常量 ----------


class ProtocolVersion:
    V1 = 0b0001


class MessageType:
    CLIENT_FULL_REQUEST = 0b0001
    CLIENT_AUDIO_ONLY_REQUEST = 0b0010
    SERVER_FULL_RESPONSE = 0b1001
    SERVER_ERROR_RESPONSE = 0b1111


class MessageTypeSpecificFlags:
    NO_SEQUENCE = 0b0000
    POS_SEQUENCE = 0b0001
    NEG_SEQUENCE = 0b0010
    NEG_WITH_SEQUENCE = 0b0011


class SerializationType:
    NO_SERIALIZATION = 0b0000
    JSON = 0b0001


class CompressionType:
    GZIP = 0b0001


class CommonUtils:
    @staticmethod
    def gzip_compress(data: bytes) -> bytes:
        return gzip.compress(data)

    @staticmethod
    def gzip_decompress(data: bytes) -> bytes:
        return gzip.decompress(data)

    @staticmethod
    def read_wav_info(data: bytes) -> Tuple[int, int, int, int, bytes]:
        if len(data) < 44:
            raise ValueError("Invalid WAV file: too short")
        if data[:4] != b"RIFF" or data[8:12] != b"WAVE":
            raise ValueError("Invalid WAV file: not WAVE")
        num_channels = struct.unpack("<H", data[22:24])[0]
        bits_per_sample = struct.unpack("<H", data[34:36])[0]
        pos = 36
        while pos < len(data) - 8:
            subchunk_id = data[pos : pos + 4]
            subchunk_size = struct.unpack("<I", data[pos + 4 : pos + 8])[0]
            if subchunk_id == b"data":
                wave_data = data[pos + 8 : pos + 8 + subchunk_size]
                sample_rate = struct.unpack("<I", data[24:28])[0]
                return (
                    num_channels,
                    bits_per_sample // 8,
                    sample_rate,
                    subchunk_size // (num_channels * (bits_per_sample // 8)),
                    wave_data,
                )
            pos += 8 + subchunk_size
        raise ValueError("Invalid WAV file: no data subchunk found")


class AsrRequestHeader:
    def __init__(self) -> None:
        self.message_type = MessageType.CLIENT_FULL_REQUEST
        self.message_type_specific_flags = MessageTypeSpecificFlags.POS_SEQUENCE
        self.serialization_type = SerializationType.JSON
        self.compression_type = CompressionType.GZIP
        self.reserved_data = bytes([0x00])

    def with_message_type(self, message_type: int) -> "AsrRequestHeader":
        self.message_type = message_type
        return self

    def with_message_type_specific_flags(self, flags: int) -> "AsrRequestHeader":
        self.message_type_specific_flags = flags
        return self

    def to_bytes(self) -> bytes:
        header = bytearray()
        header.append((ProtocolVersion.V1 << 4) | 1)
        header.append((self.message_type << 4) | self.message_type_specific_flags)
        header.append((self.serialization_type << 4) | self.compression_type)
        header.extend(self.reserved_data)
        return bytes(header)

    @staticmethod
    def default_header() -> "AsrRequestHeader":
        return AsrRequestHeader()


class AsrResponse:
    def __init__(self) -> None:
        self.code = 0
        self.event = 0
        self.is_last_package = False
        self.payload_sequence = 0
        self.payload_size = 0
        self.payload_msg: Optional[Dict[str, Any]] = None

    def to_dict(self) -> Dict[str, Any]:
        return {
            "code": self.code,
            "event": self.event,
            "is_last_package": self.is_last_package,
            "payload_sequence": self.payload_sequence,
            "payload_size": self.payload_size,
            "payload_msg": self.payload_msg,
        }


class ResponseParser:
    """与官方 sauc_websocket_demo.ResponseParser 一致的二进制响应解析。"""

    @staticmethod
    def parse_response(msg: bytes) -> AsrResponse:
        response = AsrResponse()
        if len(msg) < 4:
            return response

        header_size = msg[0] & 0x0F
        message_type = msg[1] >> 4
        message_type_specific_flags = msg[1] & 0x0F
        serialization_method = msg[2] >> 4
        message_compression = msg[2] & 0x0F

        payload = msg[header_size * 4 :]

        if message_type_specific_flags & 0x01:
            response.payload_sequence = struct.unpack(">i", payload[:4])[0]
            payload = payload[4:]
        if message_type_specific_flags & 0x02:
            response.is_last_package = True
        if message_type_specific_flags & 0x04:
            response.event = struct.unpack(">i", payload[:4])[0]
            payload = payload[4:]

        if message_type == MessageType.SERVER_FULL_RESPONSE:
            if len(payload) >= 4:
                response.payload_size = struct.unpack(">I", payload[:4])[0]
                payload = payload[4:]
        elif message_type == MessageType.SERVER_ERROR_RESPONSE:
            if len(payload) >= 8:
                response.code = struct.unpack(">i", payload[:4])[0]
                response.payload_size = struct.unpack(">I", payload[4:8])[0]
                payload = payload[8:]

        if not payload:
            return response

        if message_compression == CompressionType.GZIP:
            try:
                payload = CommonUtils.gzip_decompress(payload)
            except Exception:
                return response

        try:
            if serialization_method == SerializationType.JSON:
                response.payload_msg = json.loads(payload.decode("utf-8"))
        except Exception:
            pass

        return response


def build_auth_headers(
    app_key: str,
    access_key: str,
    resource_id: str,
    *,
    swap_keys: bool = False,
    include_connect_id: bool = False,
) -> Dict[str, str]:
    """
    WebSocket 握手鉴权头（与官方 demo 一致，另可选 X-Api-Connect-Id 兼容旧部署）。
    """
    if swap_keys:
        app_key, access_key = access_key, app_key
    reqid = str(uuid.uuid4())
    headers: Dict[str, str] = {
        "X-Api-Resource-Id": resource_id,
        "X-Api-Request-Id": reqid,
        "X-Api-Access-Key": access_key,
        "X-Api-App-Key": app_key,
    }
    if include_connect_id:
        headers["X-Api-Connect-Id"] = str(uuid.uuid4())
    return headers


def new_full_client_request(
    seq: int,
    *,
    uid: str = "hibi_asr",
    sample_rate: int = 16000,
    model_name: str = "bigmodel",
    enable_nonstream: bool = False,
) -> bytes:
    header = (
        AsrRequestHeader.default_header()
        .with_message_type_specific_flags(MessageTypeSpecificFlags.POS_SEQUENCE)
    )
    payload = {
        "user": {"uid": uid},
        "audio": {
            # SAUC 流式分片发送的是裸 PCM，不是带头 WAV。
            # 这里用 pcm，可避免服务端持续返回「Invalid audio format」类错误。
            "format": "pcm",
            "codec": "raw",
            "rate": sample_rate,
            "bits": 16,
            "channel": 1,
        },
        "request": {
            "model_name": model_name,
            "enable_itn": True,
            "enable_punc": True,
            "enable_ddc": True,
            "show_utterances": True,
            "enable_nonstream": enable_nonstream,
        },
    }
    payload_bytes = json.dumps(payload).encode("utf-8")
    compressed = CommonUtils.gzip_compress(payload_bytes)
    request = bytearray()
    request.extend(header.to_bytes())
    request.extend(struct.pack(">i", seq))
    request.extend(struct.pack(">I", len(compressed)))
    request.extend(compressed)
    return bytes(request)


def new_audio_only_request(seq: int, segment: bytes, is_last: bool) -> bytes:
    header = AsrRequestHeader.default_header()
    if is_last:
        header.with_message_type_specific_flags(MessageTypeSpecificFlags.NEG_WITH_SEQUENCE)
        seq = -seq
    else:
        header.with_message_type_specific_flags(MessageTypeSpecificFlags.POS_SEQUENCE)
    header.with_message_type(MessageType.CLIENT_AUDIO_ONLY_REQUEST)

    request = bytearray()
    request.extend(header.to_bytes())
    request.extend(struct.pack(">i", seq))
    compressed_segment = CommonUtils.gzip_compress(segment)
    request.extend(struct.pack(">I", len(compressed_segment)))
    request.extend(compressed_segment)
    return bytes(request)


def asr_response_to_legacy_dict(r: AsrResponse) -> Dict[str, Any]:
    """供 hibi_asr 旧逻辑使用的扁平 dict（含 is_last）。"""
    return {
        "code": r.code,
        "is_last": r.is_last_package,
        "payload_msg": r.payload_msg,
    }
