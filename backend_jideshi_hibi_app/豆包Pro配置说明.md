# 豆包 Pro 接入说明

> **若之前按「阿里云 / 通义」文档部署**：请务必把 `MODEL_BASE_URL` 改为火山方舟地址 `https://ark.cn-beijing.volces.com/api/v3`。否则请求会打到阿里云，豆包 Key 会报 401，错误链接会指向 `help.aliyun.com`。

官方给你的示例是 **Responses API**（`/api/v3/responses`），我们后端用的是 **OpenAI 兼容的 Chat Completions**（`/api/v3/chat/completions`）。火山方舟同时支持这两种，**当前项目不需要改任何代码**，只需在服务器 `.env` 里填对豆包参数即可。

---

## 后端 .env 要填的内容

在服务器上编辑 `/root/jideshi_hibi_backend/.env`（或你实际部署目录下的 `.env`），按下面配置：

```env
# 豆包 Pro（火山方舟 OpenAI 兼容接口）
MODEL_BASE_URL=https://ark.cn-beijing.volces.com/api/v3
MODEL_API_KEY=9a46eba4-10c8-43e3-8744-b43a6c22952b
MODEL_ID=doubao-seed-2-0-pro-260215

PORT=7861
```

说明：

| 变量 | 说明 | 你填的值 |
|------|------|----------|
| MODEL_BASE_URL | 固定为火山方舟 API 根地址 | `https://ark.cn-beijing.volces.com/api/v3` |
| MODEL_API_KEY | 豆包控制台里的 API Key（你示例里的 Bearer 后面的那串） | 你的密钥，如 `9a46eba4-10c8-43e3-8744-b43a6c22952b` |
| MODEL_ID | 模型/接入点 ID | 你给的 `doubao-seed-2-0-pro-260215`；若控制台用的是「推理接入点 ID」（`ep-` 开头），则改为该 ID |

保存后重启容器：

```bash
docker restart jideshi_hibi_api
```

---

## 为何不用改项目代码？

- 官方示例是 **Responses API**：`POST https://ark.cn-beijing.volces.com/api/v3/responses`，请求体是 `model` + `input`（内容格式和我们的不一样）。
- 我们后端调用的是 **Chat Completions API**：`POST https://ark.cn-beijing.volces.com/api/v3/chat/completions`，请求体是 `model` + `messages`（和 OpenAI 一致）。
- 火山方舟同时提供上述两种接口；我们的逻辑已经按 Chat Completions 写好了，所以**只需改 .env，不用改代码**。

---

## 若仍报 401、错误里出现 help.aliyun.com（还没跑通）

说明请求还在走**阿里云**，不是火山方舟。请在**服务器**上按下面做一遍：

### 1. 确认当前生效的配置

```bash
# 看容器里实际用的环境变量（重点看 MODEL_BASE_URL）
docker exec jideshi_hibi_api env | grep MODEL_
```

若看到 `MODEL_BASE_URL=https://dashscope.aliyuncs.com/...`，就是还在用阿里云，必须改掉。

### 2. 改 .env 为豆包（三行必对）

在服务器上编辑 `~/jideshi_hibi_backend/.env`（或你部署目录下的 `.env`），保证内容是：

```env
MODEL_BASE_URL=https://ark.cn-beijing.volces.com/api/v3
MODEL_API_KEY=你的豆包API密钥
MODEL_ID=你的推理接入点ID或模型ID
PORT=7861
```

**注意**：`MODEL_BASE_URL` 必须是 `https://ark.cn-beijing.volces.com/api/v3`，不能含 `dashscope`、`aliyun`。

### 3. 用 .env 重新启动容器（关键）

若当初是用 `docker run -e MODEL_BASE_URL=...` 这样写的**固定参数**启动的，只改 .env 再 `docker restart` **不会生效**，因为 -e 已经写死。需要删掉容器后用 `--env-file` 再起一次：

```bash
cd ~/jideshi_hibi_backend
docker stop jideshi_hibi_api
docker rm jideshi_hibi_api
docker run -d \
  --name jideshi_hibi_api \
  --restart unless-stopped \
  -p 7861:7861 \
  --env-file .env \
  jideshi_hibi_api
```

这样容器才会从 `.env` 里读豆包配置。

### 4. 再确认

```bash
docker exec jideshi_hibi_api env | grep MODEL_BASE_URL
```

应显示：`MODEL_BASE_URL=https://ark.cn-beijing.volces.com/api/v3`。然后再在前端发一句「你好」测试。

---

## 若返回 404 或 model 不存在

部分豆包模型在兼容接口里要用「推理接入点 ID」（`ep-xxxxx`）而不是模型名。请到火山方舟控制台查看你开通的豆包 Pro 对应的**推理接入点 ID**，把 `.env` 里的 `MODEL_ID` 改成该接入点 ID 后再重启容器。
