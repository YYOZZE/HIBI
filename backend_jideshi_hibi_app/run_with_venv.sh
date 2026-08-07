#!/bin/bash
# 无 Docker 时在服务器本机用 Python 运行后端（api_only_app 会读同目录 .env）
set -e
cd /root/jideshi_hibi_backend
mkdir -p data
export HIBI_DATA_DIR="$(pwd)/data"
PORT=${PORT:-7861}
if [ ! -d venv ]; then
  python3 -m venv venv 2>/dev/null || true
fi
if [ -f venv/bin/pip ]; then
  venv/bin/pip install -q -r requirements.txt -i https://pypi.tuna.tsinghua.edu.cn/simple
  exec venv/bin/python -m uvicorn api_only_app:app --host 0.0.0.0 --port "$PORT"
else
  pip3 install -q -r requirements.txt -i https://pypi.tuna.tsinghua.edu.cn/simple 2>/dev/null || true
  exec python3 -m uvicorn api_only_app:app --host 0.0.0.0 --port "$PORT"
fi
