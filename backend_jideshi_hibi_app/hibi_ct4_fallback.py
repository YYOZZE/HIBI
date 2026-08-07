"""
阿里云图形认证网页端 SDK（ct4.js）内嵌回退。

官方要求：将控制台下载的 ct4.js 上传到自有静态资源，再以完整 URL 用 script 引入。
若 ECS 上遗漏 static/ct4.js，/api/auth/captcha/sdk.js 会 404；此处从随包 Base64 还原，
保证接口始终返回 JS（与 static/ct4.js 同源，部署后仍应以磁盘文件为准）。

更新内嵌：当仓库内 static/ct4.js 变更后，重新生成 hibi_ct4_fallback_b64.txt：

  python -c "import base64,pathlib; p=pathlib.Path('static/ct4.js'); open('hibi_ct4_fallback_b64.txt','w').write(base64.b64encode(p.read_bytes()).decode())"
"""
from __future__ import annotations

import base64
import os

_B64_NAME = "hibi_ct4_fallback_b64.txt"


def get_ct4_js_bytes() -> bytes | None:
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), _B64_NAME)
    if not os.path.isfile(path):
        return None
    try:
        raw = open(path, "r", encoding="ascii").read().strip()
        return base64.b64decode(raw)
    except Exception:
        return None
