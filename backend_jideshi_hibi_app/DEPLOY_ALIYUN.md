# 阿里云轻量服务器部署步骤（Docker 版）

按顺序在**你本机**和**服务器**上执行即可跑通前后端。

---

## 第一步：在服务器上确认 Docker

在阿里云 Workbench 的 Shell 里执行：

```bash
docker --version
```

若显示 `Docker version 26.x.x` 即正常。若无 docker，可先执行：

```bash
sudo yum install -y docker  # 或 sudo apt-get install -y docker.io
sudo systemctl start docker
sudo systemctl enable docker
```

---

## 第二步：在服务器上创建目录并上传后端代码

在服务器 Shell 执行：

```bash
mkdir -p ~/jideshi_hibi_backend
cd ~/jideshi_hibi_backend
```

接下来要把本机的 `backend_jideshi_hibi_app` 里的文件放到服务器 `~/jideshi_hibi_backend`。

**方式 A：用 Workbench 左侧「文件管理」**

1. 在左侧点「文件管理」，进入 `/home/admin`。
2. 新建文件夹 `jideshi_hibi_backend`（若没有）。
3. 在本机打开 `C:\ALI_Z14\.TSING_important\Tsingcoop_products\pd\jideshi_hibi\backend_jideshi_hibi_app`，把下面文件**上传**到服务器 `~/jideshi_hibi_backend`：
   - `api_only_app.py`
   - `requirements.txt`
   - `Dockerfile`
   - `.env.example`（上传后改名为 `.env` 再编辑）

**方式 B：本机用 SCP 上传（在 Windows PowerShell 或 CMD 执行）**

先查服务器**公网 IP**（阿里云控制台 → 轻量应用服务器 → 你的实例 → 概览里有公网 IP）。假设为 `123.45.67.89`，在**本机**执行（把路径和 IP 换成你的）：

```powershell
cd C:\ALI_Z14\.TSING_important\Tsingcoop_products\pd\jideshi_hibi
scp backend_jideshi_hibi_app\api_only_app.py backend_jideshi_hibi_app\requirements.txt backend_jideshi_hibi_app\Dockerfile backend_jideshi_hibi_app\.env.example admin@123.45.67.89:~/jideshi_hibi_backend/
```

上传后在**服务器**上执行：

```bash
cd ~/jideshi_hibi_backend
cp .env.example .env
```

---

## 第三步：在服务器上配置 .env

在服务器上编辑 `~/jideshi_hibi_backend/.env`：

```bash
cd ~/jideshi_hibi_backend
vi .env
```

或用 Workbench 文件管理里双击 `.env` 编辑。内容示例（必改三项）：

```env
MODEL_BASE_URL=https://dashscope.aliyuncs.com/compatible-mode/v1
MODEL_API_KEY=你的通义API密钥
MODEL_ID=qwen-plus
PORT=7861
```

保存后确认文件存在：

```bash
cat .env
```

---

## 第四步：在服务器上用 Docker 构建并运行后端

在服务器 Shell 执行：

```bash
cd ~/jideshi_hibi_backend
sudo docker build -t jideshi_hibi_api .
```

构建完成后，用 `.env` 里的变量启动容器（把 `你的API密钥` 等换成真实值，或直接使用已写好的 .env 路径）：

```bash
sudo docker run -d \
  --name jideshi_hibi_api \
  --restart unless-stopped \
  -p 7861:7861 \
  -e MODEL_BASE_URL="https://dashscope.aliyuncs.com/compatible-mode/v1" \
  -e MODEL_API_KEY="你的通义API密钥" \
  -e MODEL_ID="qwen-plus" \
  -e PORT="7861" \
  jideshi_hibi_api
```

若希望用服务器上的 `.env` 文件传环境变量（避免在命令里写密钥），可先停掉上面容器再改用：

```bash
sudo docker rm -f jideshi_hibi_api 2>/dev/null
sudo docker run -d \
  --name jideshi_hibi_api \
  --restart unless-stopped \
  -p 7861:7861 \
  --env-file .env \
  jideshi_hibi_api
```

检查是否在跑：

```bash
sudo docker ps
curl -s http://127.0.0.1:7861/
```

若返回 `{"message":"希比 HIBI 智能体 API",...}` 说明后端已跑通。

---

## 第五步：开放服务器 7861 端口（安全组）

1. 登录阿里云控制台 → **轻量应用服务器** → 你的实例。
2. 进入 **防火墙 / 安全组**。
3. 添加入方向规则：**端口 7861**，协议 **TCP**，来源 **0.0.0.0/0**（或按需限制 IP），保存。

保存后可在本机浏览器访问：`http://你的公网IP:7861/`，应看到同样的 JSON。

---

## 第六步：本机 Flutter 配置并运行前端

1. 打开项目中的 `lib/config/api_config.dart`。
2. 把 `assistantApiBaseUrl` 改成你的服务器地址，例如：

```dart
static const String assistantApiBaseUrl = 'http://你的公网IP:7861';
```

3. 保存后在本机运行 Flutter 应用（Windows / Android 等）：

```powershell
cd C:\ALI_Z14\.TSING_important\Tsingcoop_products\pd\jideshi_hibi
flutter run -d windows
```

4. 在应用里进入「助理」→ 选一个智能体 → 发消息，应能收到大模型回复。

---

## 常用运维命令（在服务器上）

```bash
# 查看后端日志
sudo docker logs -f jideshi_hibi_api

# 停止
sudo docker stop jideshi_hibi_api

# 启动
sudo docker start jideshi_hibi_api

# 重新构建并运行（代码或 Dockerfile 更新后）
cd ~/jideshi_hibi_backend
sudo docker rm -f jideshi_hibi_api
sudo docker build -t jideshi_hibi_api .
sudo docker run -d --name jideshi_hibi_api --restart unless-stopped -p 7861:7861 --env-file .env jideshi_hibi_api
```

---

## 故障排查

| 现象 | 可能原因 | 处理 |
|------|----------|------|
| 本机访问 `http://IP:7861` 超时 | 安全组未放行 7861 | 在控制台防火墙/安全组添加 7861 |
| 返回 502 / 连接被拒 | 容器未启动或崩溃 | `sudo docker ps`、`sudo docker logs jideshi_hibi_api` |
| 对话返回「未配置大模型」 | .env 未生效或未传进容器 | 用 `--env-file .env` 或 `-e` 显式传 MODEL_* |
| 对话报错 401/403 | MODEL_API_KEY 错误或过期 | 检查通义/豆包控制台密钥并更新 .env |

按以上步骤做完后，前后端即可在阿里云上跑通。若某一步报错，把**当前步骤**和**完整报错/截图**发给我即可继续排查。
