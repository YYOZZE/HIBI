# ECS 排查与修复步骤（AI 对话 + 语音识别）

**约定：后端仅在 ECS 上运行，不在本机启动或调试后端。**  
跑通 = 本机用 `sync_to_server.ps1` 同步代码 → ECS 上服务监听 7861 → 安全组放行 7861 → `.env` 配置正确。

适用于当前 ECS：**121.41.6.21**，端口 **7861**，后端以 **Python venv + systemd** 方式运行（无 Docker）。

---

## 一、用 PuTTY / SSH 登录 ECS

1. **PuTTY**  
   - Host: `121.41.6.21`  
   - Port: `22`  
   - Connection type: SSH  
   - 打开后登录名填 `root`，密码填你当前密码（如 `Asd123...`，后续请自行修改）。

2. **本机 PowerShell / 终端**  
   ```bash
   ssh root@121.41.6.21
   ```
   按提示输入密码。

---

## 二、本机同步代码并触发 ECS 重启（推荐）

在**项目根目录**执行（输入一次密码即可完成同步 + ECS 重启）：

```powershell
.\backend_jideshi_hibi_app\sync_to_server.ps1
```

脚本会把后端代码与 `ecs_check_and_fix.sh` 传到 ECS，并在 ECS 上执行 `systemctl restart jideshi-hibi-api`。验证：浏览器打开 http://121.41.6.21:7861/docs 。

---

## 三、在 ECS 上运行一键排查脚本（可选）

若需检查端口、`.env`、服务状态，可 SSH 登录 ECS 后执行（脚本已由 sync_to_server.ps1 同步到服务器）：

**在 ECS 上执行：**
```bash
cd /root/jideshi_hibi_backend
chmod +x ecs_check_and_fix.sh
./ecs_check_and_fix.sh
```

脚本会检查：7861 是否监听、`.env` 是否存在及关键变量是否填写、本机 `/docs` 是否 200、systemd 服务是否在跑，并询问是否重启服务。按提示操作即可。

---

## 四、根据现象逐项修复

### 1. 连接被拒绝（SocketException: connection refused）

- **原因**：7861 未监听或阿里云安全组未放行。
- **在 ECS 上执行：**
  ```bash
  ss -tlnp | grep 7861
  curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:7861/docs
  ```
  - 若 7861 未监听或 curl 非 200：启动/重启服务  
    ```bash
    systemctl start jideshi-hibi-api   # 或 systemctl restart jideshi-hibi-api
    ```
  - 若本机 curl 为 200 但外网仍连不上：到 **阿里云 ECS 控制台 → 安全组 → 入方向规则**，添加 **TCP 7861**，来源 `0.0.0.0/0`（或按需限制）。

### 2. AI 对话 401（API key format is incorrect / Unauthorized）

- **原因**：后端请求大模型时使用的 `MODEL_API_KEY` 格式错误、未填或未生效；或 `MODEL_BASE_URL` 仍为阿里云地址。
- **在 ECS 上编辑 .env：**
  ```bash
  cd /root/jideshi_hibi_backend
  nano .env
  ```
  确保至少包含且**无拼写错误**：
  ```env
  MODEL_BASE_URL=https://ark.cn-beijing.volces.com/api/v3
  MODEL_API_KEY=你的豆包API密钥
  MODEL_ID=你的模型ID或推理接入点ID
  PORT=7861
  ```
  - `MODEL_BASE_URL` 必须是 `https://ark.cn-beijing.volces.com/api/v3`，不能是 `dashscope`、`aliyuncs`。
  - `MODEL_API_KEY` 从**火山方舟控制台**复制完整 Key；若 401 仍出现，检查 Key 是否过期、是否复制完整。
  - 保存后**必须重启**服务环境变量才会生效：
    ```bash
    systemctl restart jideshi-hibi-api
    ```

### 3. 语音识别“请先配置后端 ASR”

- **原因**：后端未配置 `ASR_APP_KEY`、`ASR_ACCESS_KEY`，或配置后未重启。
- **在 ECS 上编辑 .env，增加：**
  ```env
  ASR_APP_KEY=你的应用APP_ID
  ASR_ACCESS_KEY=你的Access_Token
  ```
  参见项目内 `ASR语音识别配置说明.md`（火山引擎豆包语音控制台获取）。保存后：
  ```bash
  systemctl restart jideshi-hibi-api
  ```
- **验证：** 浏览器或本机执行  
  `curl -s http://121.41.6.21:7861/api/asr/config`  
  应返回 `{"configured":true}`。

---

## 五、无需改动的部分

- **前端**：`lib/config/api_config.dart` 已指向 `http://121.41.6.21:7861`，无需修改。
- **后端代码**：当前 401/ASR 问题均为**配置与运行环境**问题，按上述修改 `.env` 并重启即可。

---

## 六、验证清单

| 项目           | 命令或操作 |
|----------------|------------|
| 端口监听       | `ss -tlnp \| grep 7861` |
| 本机接口       | `curl -s http://127.0.0.1:7861/docs` 返回页面 |
| 外网接口文档   | 浏览器打开 http://121.41.6.21:7861/docs |
| 大模型配置     | `.env` 中 MODEL_BASE_URL / MODEL_API_KEY / MODEL_ID 正确且重启 |
| 语音配置       | `curl -s http://121.41.6.21:7861/api/asr/config` 返回 `{"configured":true}` |
| 安全组         | 入方向 TCP 7861 已放行 |

---

*说明：我无法从当前环境直接 SSH 登录你的 ECS，以上步骤请你在本机/服务器上按顺序执行；完成后若仍有报错，可把终端输出或截图发给我继续排查。*
