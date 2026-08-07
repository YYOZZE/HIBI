#!/bin/bash
# ECS 上一键排查：端口、.env、服务状态，并可选重启
# 用法：上传到 /root/jideshi_hibi_backend 后 chmod +x ecs_check_and_fix.sh && ./ecs_check_and_fix.sh

set -e
cd /root/jideshi_hibi_backend
echo "========== 1. 端口 7861 是否监听 =========="
if ss -tlnp 2>/dev/null | grep -q 7861; then
  echo "  [OK] 7861 已在监听"
else
  echo "  [!!] 7861 未监听，服务可能未启动"
fi

echo ""
echo "========== 2. .env 是否存在 =========="
if [ -f .env ]; then
  echo "  [OK] .env 存在"
  echo "  MODEL_BASE_URL 是否设置: $(grep -q '^MODEL_BASE_URL=' .env && echo '是' || echo '否')"
  echo "  MODEL_API_KEY 是否设置: $(grep -q '^MODEL_API_KEY=' .env && [ -n "$(grep '^MODEL_API_KEY=' .env | cut -d= -f2)" ] && echo '是（已填值）' || echo '否或为空')"
  echo "  MODEL_ID 是否设置: $(grep -q '^MODEL_ID=' .env && echo '是' || echo '否')"
  echo "  ASR_APP_KEY 是否设置: $(grep -q '^ASR_APP_KEY=' .env && [ -n "$(grep '^ASR_APP_KEY=' .env | cut -d= -f2)" ] && echo '是' || echo '否或为空')"
  echo "  ASR_ACCESS_KEY 是否设置: $(grep -q '^ASR_ACCESS_KEY=' .env && [ -n "$(grep '^ASR_ACCESS_KEY=' .env | cut -d= -f2)" ] && echo '是' || echo '否或为空')"
  # 不打印密钥内容，只提示
  if grep -q 'MODEL_BASE_URL=.*dashscope\|aliyuncs' .env 2>/dev/null; then
    echo "  [!!] MODEL_BASE_URL 当前为阿里云地址，豆包请改为: https://ark.cn-beijing.volces.com/api/v3"
  fi
else
  echo "  [!!] .env 不存在，请从 .env.example 复制并填写："
  echo "       cp .env.example .env && nano .env"
fi

echo ""
echo "========== 3. 本机请求 /docs =========="
code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 http://127.0.0.1:7861/docs 2>/dev/null || echo "000")
if [ "$code" = "200" ]; then
  echo "  [OK] http://127.0.0.1:7861/docs 返回 200"
else
  echo "  [!!] 返回 $code，服务可能未运行或未就绪"
fi

echo ""
echo "========== 4. systemd 服务状态 =========="
if systemctl is-active --quiet jideshi-hibi-api 2>/dev/null; then
  echo "  [OK] jideshi-hibi-api 正在运行"
else
  echo "  [!!] jideshi-hibi-api 未运行，尝试启动: systemctl start jideshi-hibi-api"
  systemctl start jideshi-hibi-api 2>/dev/null || true
fi

echo ""
echo "========== 5. 重启服务（使 .env 生效） =========="
echo "  若刚修改过 .env，请执行: systemctl restart jideshi-hibi-api"
if [ -t 0 ]; then
  read -p "是否现在重启 jideshi-hibi-api? [y/N] " -n 1 r
  echo
  if [ "$r" = "y" ] || [ "$r" = "Y" ]; then
    systemctl restart jideshi-hibi-api
    echo "  已执行 systemctl restart jideshi-hibi-api"
    sleep 2
    systemctl status jideshi-hibi-api --no-pager || true
  fi
fi

echo ""
echo "========== 后续请确认 =========="
echo "1. 阿里云安全组：入方向放行 TCP 7861（来源 0.0.0.0/0 或按需限制）"
echo "2. .env 中 MODEL_BASE_URL 必须为: https://ark.cn-beijing.volces.com/api/v3"
echo "3. MODEL_API_KEY 从火山方舟控制台复制完整 API Key（401 多为 Key 错误或未生效，改完需重启服务）"
echo "4. 语音识别：在 .env 中配置 ASR_APP_KEY、ASR_ACCESS_KEY 后重启，再访问 http://121.41.6.21:7861/api/asr/config"
echo "5. 验证: curl -s http://121.41.6.21:7861/docs 或浏览器打开 http://121.41.6.21:7861/docs"
