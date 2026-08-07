"""
命令行测试豆包 SAUC 识别（与官方 sauc_websocket_demo 用途相同）。

使用前在 shell 中设置与线上一致的环境变量，例如：
  ASR_APP_ID / ASR_TOKEN
或在 ECS 上：source 或复制 .env 中的 ASR_* 后再运行。

示例（在项目 backend_jideshi_hibi_app 目录下）：
  python asr_cli_demo.py --file your.wav
"""
from __future__ import annotations

import argparse
import asyncio
import sys


async def _main() -> None:
    parser = argparse.ArgumentParser(description="HIBI 豆包 SAUC 识别（调用 hibi_asr.run_asr）")
    parser.add_argument("--file", type=str, required=True, help="16kHz 16bit 单声道 WAV 路径")
    args = parser.parse_args()

    import hibi_asr

    with open(args.file, "rb") as f:
        data = f.read()
    text = await hibi_asr.run_asr(data)
    print(text or "")


if __name__ == "__main__":
    asyncio.run(_main())
