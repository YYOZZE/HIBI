# 希比 HIBI 智能体后端 - 用于阿里云 Docker 部署
FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt -i https://pypi.tuna.tsinghua.edu.cn/simple

COPY api_only_app.py .
COPY hibi_ct4_fallback.py .
COPY hibi_ct4_fallback_b64.txt .
COPY hibi_auth_sync.py .
COPY hibi_payment.py .

# 用户库与同步数据落盘目录；运行容器时请挂载宿主机目录到此路径，例如：
#   docker run ... -v /root/jideshi_hibi_backend/data:/app/data ...
ENV HIBI_DATA_DIR=/app/data
RUN mkdir -p /app/data

# 默认端口，可通过 -e PORT=7861 覆盖
ENV PORT=7861
EXPOSE 7861

CMD ["sh", "-c", "python -m uvicorn api_only_app:app --host 0.0.0.0 --port ${PORT}"]
