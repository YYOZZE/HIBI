#!/bin/bash
# 在云服务器 /root/jideshi_hibi_backend 目录下执行，用当前 .env 重建并启动容器
# 挂载 ./data -> /app/data，用户库 hibi_users.db 落在宿主机，删容器不丢库
set -e
cd /root/jideshi_hibi_backend
mkdir -p data
echo "停止并删除旧容器..."
docker stop jideshi_hibi_api 2>/dev/null || true
docker rm jideshi_hibi_api 2>/dev/null || true
echo "构建镜像..."
docker build -t jideshi_hibi_api .
echo "使用 .env + 数据卷启动容器..."
docker run -d \
  --name jideshi_hibi_api \
  --restart unless-stopped \
  -p 7861:7861 \
  --env-file .env \
  -v "$(pwd)/data:/app/data" \
  jideshi_hibi_api
echo "验证环境变量..."
docker exec jideshi_hibi_api env | grep MODEL_BASE_URL
echo "数据目录: $(pwd)/data （hibi_users.db 在此，重建容器会保留）"
echo "完成。可再执行: docker logs -f jideshi_hibi_api 查看日志。"
