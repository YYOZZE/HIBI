# 数捷支付 SDK 接入笔记（HIBI）

> 适用项目：`jideshi_hibi`  
> 更新时间：2026-03-23  
> 目标：记录我们这次数捷支付接入的**技术原理**、**签名算法踩坑**、**当前前后端完整方案**与**排障注意事项**。

---

## 1. 接入目标与现状

我们当前支付接入覆盖：

- 支付渠道：`支付宝` / `微信支付` / `网银支付`（前端传 `pay_type`）
- 业务链路：创建订单 -> 拉起支付页 -> 回调验签 -> 订单入账 -> 前端查询确认 -> 刷新权益
- 订阅权益：基础服务（数据/助理/主题）+ PRO（含全部基础服务）
- 自动续费逻辑：后端按订单有效期与宽限期计算（非本文重点，已在支付模块实现）

当前核心后端文件：

- `backend_jideshi_hibi_app/hibi_payment.py`
- `backend_jideshi_hibi_app/api_only_app.py`

当前核心前端文件：

- `lib/features/profile/payment_service.dart`
- `lib/features/profile/value_added_page.dart`

---

## 2. 为什么我们卡了很久：签名算法是最大坑

### 2.1 表面现象

最常见报错是：

- `RSA签名校验失败`
- `签名校验失败`
- `invalid sign`

看起来像“私钥不对”，但实际常常是**参数规范不一致**导致的（尤其是 sign_type、摘要算法、金额格式、拼串字段）。

### 2.2 这次踩到的关键差异

我们最终确认：数捷不同网关/文档版本里，存在“看起来一样、实际不完全一样”的规则。

主要差异点：

1. **`sign_type` 字段值与真实摘要算法不是同一层概念**
   - SDK2 示例里常看到 `sign_type=RSA`
   - 但摘要算法可能仍需用 `SHA256`（不是 SHA1）
2. **同一个 submit 地址，不同商户环境接受的写法存在差异**
   - 有的更偏 `SHA256WithRSA`
   - 有的兼容 `RSA + SHA256`
3. **金额字段格式差异会影响验签**
   - `1.00` 与 `1` 都可能出现，某些网关只认其中一种参与签名
4. **签名拼串必须严格按规则**
   - 按 key 排序
   - 跳过空值
   - 排除 `sign` 和 `sign_type`
5. **异步回调验签算法也可能有历史兼容差异**
   - 主验 `SHA256`
   - 少量历史环境回调 `sign_type=RSA` 时可能要兼容 `SHA1`

---

## 3. 我们当前后端签名方案（已落地）

### 3.1 环境变量与开关（核心）

后端读取：

- `SHUJIEPAY_SUBMIT_URL`
- `SHUJIEPAY_NOTIFY_URL`
- `SHUJIEPAY_RETURN_URL`
- `SHUJIEPAY_MCH_ID`
- `SHUJIEPAY_MCH_PRIVATE_KEY`
- `SHUJIEPAY_PLATFORM_PUBLIC_KEY`
- `SHUJIEPAY_DEFAULT_TYPE`（默认渠道）
- `SHUJIEPAY_SIGN_TYPE`（默认 `RSA`）
- `SHUJIEPAY_SIGN_HASH`（默认 `SHA256`）
- `SHUJIEPAY_LEGACY_RSA_SHA1_FALLBACK`（默认 `0`，仅历史兼容时开启）
- `HIBI_BASE_URL`（用于支付中转页 URL 生成）

推荐默认：

- `SHUJIEPAY_SIGN_TYPE=RSA`
- `SHUJIEPAY_SIGN_HASH=SHA256`
- `SHUJIEPAY_LEGACY_RSA_SHA1_FALLBACK=0`

### 3.2 统一签名原文生成

在 `hibi_payment.py` 中，我们统一按以下规则拼签名原文：

- 参数按 key 升序
- 排除：`sign`、`sign_type`
- 过滤空值
- 用 `k=v&k2=v2...` 拼接

这是对齐 SDK 逻辑的关键点之一。

### 3.3 SDK2 主流程（当前主路径）

当 `submit_url` 包含 `/api/pay/submit` 时，走 SDK2 路径：

1. 组装参数（`pid/out_trade_no/name/money/type/notify_url/return_url/timestamp`）
2. 按当前配置先签一版
3. 做“预检 POST”到 submit（检查响应是否含验签失败关键词）
4. 若疑似验签失败，自动尝试下一组候选参数

候选顺序（按 money 变体 + 签名参数组合）：

- 首选：环境配置值（如 `RSA + SHA256`）
- 再试：`SHA256WithRSA + SHA256`
- 再试：`RSA + SHA256`
- 最后（仅显式开启兼容开关）：`RSA + SHA1`

金额变体也会尝试：

- `x.xx`（如 `1.00`）
- `x`（如 `1`，若可压缩）

### 3.4 前端拉起稳定性方案：POST 中转页

不是直接把 submit URL 给 App 打开，而是返回我们自己的中转页：

- `/api/payment/pay_page?mode=shujie_post&p=...`

中转页会自动构建 HTML form 并 `POST` 到数捷 submit 地址。

这样做的收益：

- 行为与 SDK pagePay 更一致
- 避免某些端（尤其桌面/移动混合）对复杂 query 拉起不稳定
- 规避直接 GET 触发的兼容问题

### 3.5 V2 API 兜底方案（备用路径）

若不是 SDK2 submit 场景，后端会尝试 POST 下单并解析返回中的：

- `pay_url`
- `pay_data.url`
- `data.pay_url`

优先尝试 SDK-like 参数，再回退 V2 参数。

---

## 4. 异步回调验签与订单状态更新

回调入口：

- `GET/POST /api/payment/notify`（兼容 SDK2 的 `$_GET` 示例）

核心逻辑：

1. 解析 query/form/json（GET/POST 全兼容）
2. 提取订单号（`out_trade_no/order_id/mch_order_no`）
3. 用 `SHUJIEPAY_PLATFORM_PUBLIC_KEY` 验签
   - 默认 `SHA256`
   - 若失败且 `sign_type` 指向 RSA，尝试 `SHA1` 兼容
4. 根据 `trade_status` 更新订单
   - success/paid/trade_success -> 标记 paid
   - fail/closed/expired 等 -> 标记 failed

特别注意：

- 回调响应按 SDK 习惯返回纯文本：`success` / `fail`（HTTP 200）
- 验签失败不再直接把订单置为 failed（避免误伤后续有效重试回调）
- 回调原文会保存截断版（`notify_raw`）用于审计

---

## 5. 前端完整方案（当前线上）

### 5.1 订阅页支付入口

`value_added_page.dart`：

- 弹窗选择渠道：`alipay` / `wxpay` / `bank`
- 调 `PaymentService.createOrderAndGetPayUrl(planId, token, payType)`
- 拿到 `pay_url` 后用 `url_launcher` 外部拉起
- 用户支付后点“我已支付，查看结果”轮询 `GET /api/payment/order/{order_id}`

### 5.2 前端服务层接口

`payment_service.dart` 已封装：

- `fetchPlanCatalog()`
- `createOrderAndGetPayUrl()`
- `fetchOrderStatus()`
- `fetchMyEntitlements()`
- `fetchConfigStatus()`

---

## 6. 后端接口总览（支付相关）

- `POST /api/payment/create_order`（需登录）
- `GET /api/payment/order/{order_id}`（需登录）
- `GET /api/payment/my_entitlements`（需登录）
- `GET /api/payment/plans`（公开）
- `GET /api/payment/config_status`（公开）
- `GET/POST /api/payment/notify`（支付平台回调，SDK2 补单可走 GET）
- `GET /api/payment/pay_page`（支付中转/兜底说明页）

---

## 7. 典型故障与排查手册

### 7.1 下单成功但支付页提示验签失败

先查：

1. 私钥格式是否正确（PEM / 换行）
2. `sign_type`、`sign_hash` 配置值
3. 金额格式是否触发兼容差异
4. 参数拼串是否含了空值或未排除 sign 字段

我们现在的代码已对 2~4 做自动兼容尝试；若仍失败，优先核验商户后台约定与平台文档版本。

### 7.2 回调验签失败

先查：

1. `SHUJIEPAY_PLATFORM_PUBLIC_KEY` 是否对应当前网关
2. 回调字段有无代理层改写
3. 是否存在历史 SHA1 回调（可通过 sign_type 和日志判断）

### 7.3 前端显示“支付参数无效”

常见原因：

- 中转参数 `p` 解码失败
- submit_url 非法
- params 空

先看 `api_only_app.py` 的 pay_page decode 日志。

### 7.4 一直 pending

先确认：

- 是否收到 notify
- notify 验签是否通过
- 用户是否在前端点了“我已支付，查看结果”

当前代码额外兜底（已上线）：

- 若 `pay_page(return_url)` 带签名参数，会在回跳页直接验签并尝试入账；
- 若订单仍 `pending`，`GET /api/payment/order/{id}` 会触发一次主动查单（query）并尝试自动入账。

---

## 8. 运维与安全注意事项

1. 私钥、公钥只放 ECS `.env`，不要写入代码库。
2. `config_status` 仅返回布尔，不回显密钥内容（当前已这样实现）。
3. 回调接口要保持公网可达、低延迟，避免平台重试风暴。
4. 建议把支付日志与异常日志长期保留，至少保留 30 天。
5. 生产环境默认关闭 `SHUJIEPAY_LEGACY_RSA_SHA1_FALLBACK`，仅兼容排障时临时开启。

---

## 9. 我们这版“最终共识”配置建议

### 9.1 首选策略

- 走 SDK2 submit + 后端 POST 中转页（当前主方案）
- 签名摘要默认 SHA256
- 回调验签主用 SHA256，RSA(SHA1) 仅兼容兜底

### 9.2 为什么这样定

- 与数捷 SDK2 行为最接近，端上拉起稳定
- 对历史差异（sign_type/金额格式）有自动兜底
- 排障信息可追踪（fail_reason / notify_raw / 订单状态）

---

## 10. 后续优化建议（可选）

1. 增加“签名候选命中统计”指标，明确线上最终采用哪组参数。
2. 在后台增加“最近支付失败原因”聚合面板，缩短运维排查时间。
3. 将支付关键路径日志结构化（JSON）并接入告警。
4. 对回调做幂等与重试可观测增强（当前已有幂等基础）。

---

## 11. 2026-03-23 更新记录（本次问题修复）

### 11.1 修复补单 `Method Not Allowed`

- 原因：SDK2 示例 `notify_url.php` 用 `$_GET`，而我们早期只支持 `POST /notify`。
- 修复：`/api/payment/notify` 改为 `GET+POST`，并兼容 query/form/json 三种入参。
- 验证：访问 `http://121.41.6.21:7861/api/payment/notify?out_trade_no=test` 返回 `fail`（不再 405）。

### 11.2 修复“支付成功但没自动开通”的高频场景

- 新增 `return_url(/pay_page)` 回跳验签入账：当回跳 URL 带 `sign + out_trade_no` 时，后端直接按 notify 规则尝试入账。
- 新增“查单兜底”：订单为 `pending` 时，查询订单接口会主动向网关 query 并尝试转 `paid`。
- 回调状态兼容增强：不仅识别 `trade_status`，也兼容 `bizSts=02/03`、`result_code/code/state` 等常见字段。
- 修复致命 bug：`update_order_paid/_mark_order_failed` 误用 `sqlite3.Connection.rowcount`，导致回跳处理 500、订单无法入账；已改为 `cursor.rowcount`。
- 实测回放真实回调 URL 后，`pay_page` 显示 `回跳校验：success`，并返回 200（不再 Internal Server Error）。

### 11.3 自动续订能力边界（避免误解）

- 当前实现：**自动创建续费订单 + 宽限期/中断状态**。
- 非当前实现：**自动扣费（代扣）**。
- SDK2（当前目录）仅含 `submit/create/query/refund`，未见签约代扣接口；若要自动扣费需单独接入渠道“签约代扣”产品能力。

---

## 12. 一句话总结

这次支付接入最大的难点不是“会不会 RSA”，而是“**同一网关下文档/字段/算法约定的细微差异**”。  
我们现在的方案本质是：**以 SHA256 为主、兼容历史差异、并通过后端中转将端上支付行为稳定化**。

