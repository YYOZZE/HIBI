const express = require('express');
const cors = require('cors');

const app = express();
app.use(cors());
app.use(express.json());

const PORT = process.env.PORT || 3000;

/**
 * 对话接口（预留）
 * 后续在此接入豆包 API：将 userMessage + history 转成豆包请求，返回流或 JSON
 * 豆包开放平台：https://www.volcengine.com/docs/82379
 */
app.post('/api/chat', async (req, res) => {
  try {
    const { agentId, userMessage, history = [] } = req.body || {};
    if (!userMessage || typeof userMessage !== 'string') {
      return res.status(400).json({ error: '缺少 userMessage' });
    }

    // 占位：未配置豆包时返回提示
    // 接入豆包后示例：
    // const reply = await callDoubaoAPI({ messages: [...history, { role: 'user', content: userMessage }] });
    const reply = '[后端] 接口已连通。接入豆包 API 后，此处将返回真实回复。';

    res.json({ reply });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: '服务器错误', reply: '请求失败，请稍后重试。' });
  }
});

/**
 * 健康检查（部署到云服务器后可用于探活）
 */
app.get('/health', (req, res) => {
  res.json({ status: 'ok', service: 'backend_jideshi_hibi_app' });
});

app.listen(PORT, () => {
  console.log(`backend_jideshi_hibi_app 运行在 http://localhost:${PORT}`);
});
