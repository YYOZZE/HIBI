# ECS 自动登录 + 同步/重启/健康检查（项目笔记）

更新时间：2026-03-27 19:05  
适用项目：`jideshi_hibi`  
ECS：`121.41.6.21`，用户：`root`，后端目录：`/root/jideshi_hibi_backend`，服务：`jideshi-hibi-api`

---

## 目标

在本机一键完成：

1. 自动登录 ECS  
2. 同步后端代码到 ECS  
3. 重启后端服务  
4. 健康检查（`/docs`、`/api/asr/config`、`/api/chat`）

---

## 方式 A（当前可用）：密码直连（plink + pscp）

> 适合马上使用。缺点是命令行会出现密码，安全性一般。跑通后建议改成方式 B（SSH 免密）。
> **本项目后续默认首选此方式（PuTTY）**，不要临时改成安装新模块（如 Posh-SSH）以免环境差异导致失败。

### 前置条件

- Windows 已安装 PuTTY 命令行工具：`plink`、`pscp`（当前机器已可用）
- 在项目根目录执行命令：
  `C:\ALI_Z14\.TSING_important\Tsingcoop_products\pd\jideshi_hibi`

### 一条命令：同步 + 重启 + 健康检查

```powershell
$PW = "Asd123..."
$IP = "121.41.6.21"
$LOCAL = "c:\ALI_Z14\.TSING_important\Tsingcoop_products\pd\jideshi_hibi\backend_jideshi_hibi_app\*"
$REMOTE = "/root/jideshi_hibi_backend/"

# 1) 同步
pscp -pw "$PW" -r "$LOCAL" root@$IP:$REMOTE

# 2) 安装依赖 + 重启
plink -pw "$PW" root@$IP "cd /root/jideshi_hibi_backend && /root/jideshi_hibi_backend/venv/bin/pip install -r requirements.txt -i https://pypi.tuna.tsinghua.edu.cn/simple && systemctl restart jideshi-hibi-api"

# 3) 健康检查
plink -pw "$PW" root@$IP "systemctl is-active jideshi-hibi-api && curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:7861/docs && echo && curl -s http://127.0.0.1:7861/api/asr/config"
```

### 方式 A-1（推荐稳定版）：不用 SSH 连接复用，直接三步执行

> 说明：在部分终端环境里，OpenSSH 的 ControlMaster 可能报错 `getsockname failed: Not a socket`。  
> 遇到这种情况，直接用下面这组 **pscp + plink** 命令最稳。

```powershell
$PW = "你的ECS密码"
$IP = "121.41.6.21"
$REMOTE = "/root/jideshi_hibi_backend/"

# 1) 同步后端目录（不覆盖服务器已有 .env）
pscp -pw "$PW" -r "c:\ALI_Z14\.TSING_important\Tsingcoop_products\pd\jideshi_hibi\backend_jideshi_hibi_app\api_only_app.py" root@$IP:$REMOTE
pscp -pw "$PW" -r "c:\ALI_Z14\.TSING_important\Tsingcoop_products\pd\jideshi_hibi\backend_jideshi_hibi_app\hibi_payment.py" root@$IP:$REMOTE
pscp -pw "$PW" -r "c:\ALI_Z14\.TSING_important\Tsingcoop_products\pd\jideshi_hibi\backend_jideshi_hibi_app\requirements.txt" root@$IP:$REMOTE

# 2) 安装依赖 + 重启服务
plink -pw "$PW" root@$IP "cd /root/jideshi_hibi_backend && /root/jideshi_hibi_backend/venv/bin/pip install -r requirements.txt -i https://pypi.tuna.tsinghua.edu.cn/simple && systemctl restart jideshi-hibi-api"

# 3) 健康检查
plink -pw "$PW" root@$IP "systemctl is-active jideshi-hibi-api && curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:7861/docs && echo && curl -s http://127.0.0.1:7861/api/asr/config"
```

### 方式 A-2：支付回调修复后的专项验证（补单/回调必测）

```powershell
# 1) notify 路由是否支持 GET（旧版会返回 Method Not Allowed）
curl.exe -m 8 -sS "http://121.41.6.21:7861/api/payment/notify?out_trade_no=test"

# 2) pay_page 文案是否为新版（用于确认后端是否已更新）
curl.exe -m 8 -sS "http://121.41.6.21:7861/api/payment/pay_page"

# 3) 配置是否就绪
curl.exe -m 8 -sS "http://121.41.6.21:7861/api/payment/config_status"
```

期望：
- 第 1 条：返回 `fail`（参数不全属于正常），**而不是** `{"detail":"Method Not Allowed"}`；
- 第 2 条：看到新版提示文案（支付返回后回应用内“我已支付，查看结果”）；
- 第 3 条：`ready=true`。

健康检查期望结果：

- `systemctl is-active` 输出：`active`
- `/docs` 返回：`200`
- `/api/asr/config` 返回：`{"configured":true}`（或 `false`，取决于是否配置 ASR）

---

## 方式 B（推荐）：SSH 免密登录（后续自动化首选）

### 1) 生成密钥（本机）

```powershell
ssh-keygen -t ed25519 -f $HOME\.ssh\id_ed25519_hibi -N ""
```

### 2) 把公钥写入 ECS

```powershell
type $HOME\.ssh\id_ed25519_hibi.pub | ssh root@121.41.6.21 "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys"
```

### 3) 免密测试

```powershell
ssh -i $HOME\.ssh\id_ed25519_hibi root@121.41.6.21 "echo ok"
```

---

## 免密后一条命令（推荐日常使用）

```powershell
$KEY = "$HOME\.ssh\id_ed25519_hibi"
$IP = "121.41.6.21"

scp -i $KEY -r "c:\ALI_Z14\.TSING_important\Tsingcoop_products\pd\jideshi_hibi\backend_jideshi_hibi_app\*" root@$IP:/root/jideshi_hibi_backend/
ssh -i $KEY root@$IP "cd /root/jideshi_hibi_backend && /root/jideshi_hibi_backend/venv/bin/pip install -r requirements.txt -i https://pypi.tuna.tsinghua.edu.cn/simple && systemctl restart jideshi-hibi-api && systemctl is-active jideshi-hibi-api && curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:7861/docs && echo && curl -s http://127.0.0.1:7861/api/asr/config"
```

---

## 常见故障与处理

1. `connection refused`
   - 检查服务状态：`systemctl status jideshi-hibi-api`
   - 检查监听：`ss -tlnp | grep 7861`
   - 检查安全组：阿里云入方向 TCP 7861

2. 服务反复重启（`auto-restart`）
   - 看日志：`journalctl -u jideshi-hibi-api -n 100 --no-pager`
   - 常见缺依赖：`aiohttp`、`python-multipart`

3. 聊天 401（`The API key format is incorrect`）
   - 检查 ECS `.env`：
     - `MODEL_BASE_URL=https://ark.cn-beijing.volces.com/api/v3`
     - `MODEL_API_KEY` 正确
     - `MODEL_ID` 正确
   - 改完执行：`systemctl restart jideshi-hibi-api`

4. `getsockname failed: Not a socket`
   - 原因：多见于 OpenSSH 连接复用（ControlMaster）在当前终端环境不兼容。
   - 处理：不要走连接复用脚本，直接按本文 **方式 A-1（pscp + plink 三步）** 执行。
   - 结论：本项目后端同步默认使用 PuTTY 工具链（`pscp`/`plink`）。

5. 支付回调页出现 `500 Internal Server Error`
   - 先查日志：`journalctl -u jideshi-hibi-api -n 120 --no-pager`
   - 若日志含 `AttributeError: 'sqlite3.Connection' object has no attribute 'rowcount'`：
     - 说明后端支付文件未更新到修复版本；
     - 重新同步 `hibi_payment.py` 后执行 `systemctl restart jideshi-hibi-api`。
   - 修复后验收：回放支付回跳 URL 时，`/api/payment/pay_page` 应返回 200 且显示 `回跳校验：success`（而不是 500）。

6. `sync_to_server.ps1` 执行后提示 `unexpected EOF while looking for matching \`''`
   - 现象：`scp` 100% 上传完成，但重启步骤失败，日志含：
     - `bash: -c: line 0: unexpected EOF while looking for matching \`''`
   - 原因：PowerShell 到 `ssh "..."` 的远程命令引号在当前终端环境被破坏（命令串含单引号，远端 `bash -c` 解析失败）。
   - 处理：已修复 `backend_jideshi_hibi_app/sync_to_server.ps1`：
     - 去掉复杂单行拼接，改为两次 `ssh`（先目录/权限，再重启/状态）；
     - 同时补充同步文件：`hibi_graph_captcha.py`。
   - 验收：终端出现 `Started HIBI API (jideshi_hibi_backend).` 即为重启成功。

7. 图形认证报错 `initAlicom4 is not defined` 或 `captcha sdk not found`
   - 现象：
     - Windows 端点击图形认证后，提示 `initAlicom4 is not defined`；
     - 或提示 `图形认证 SDK 加载失败: http://<ip>:7861/api/auth/captcha/sdk.js`。
   - 原因：
     - 客户端初始化时序不对（SDK 未加载完成先调用）；
     - ECS 上 `/api/auth/captcha/sdk.js` 对应文件缺失。
   - 处理：
     - 前端改为“先加载 SDK，再初始化”；
     - 桌面端增加本地 `ct4.js` 注入兜底（即使远端 SDK 失败也能继续）；
     - `sync_to_server.ps1` 增加同步：`backend_jideshi_hibi_app/static/ct4.js` -> `/root/jideshi_hibi_backend/static/ct4.js`。
   - 验收命令：
     - `GET /api/auth/captcha_config?platform=web` 可返回 `sdk_url`
     - `GET /api/auth/captcha/sdk.js` 返回 200（推荐）

---

## 2026-03-27 实际结果记录

- 使用修复后的 `.\backend_jideshi_hibi_app\sync_to_server.ps1` 已完成：
  - 文件同步到 `/root/jideshi_hibi_backend`
  - `jideshi-hibi-api` 重启成功（systemd 日志显示 Stopped -> Started）
- 结论：ECS 后端已更新到最新图形认证相关代码版本。
- 补充记录（19:00 后）：
  - 图形认证链路已完成 Windows 端最终跑通；
  - 登录/注册页不再向用户展示 `appId`；
  - 当 ECS `sdk.js` 异常时，客户端可使用本地内置 SDK 兜底，避免阻塞登录/注册流程。

---

## 安全建议（务必执行）

- 当前密码已在历史中使用过，建议尽快在 ECS 上执行 `passwd` 修改 root 密码。
- 长期建议：关闭 root 密码登录，仅保留密钥登录。
- 不要把明文密码提交到 Git 或写入长期脚本。

