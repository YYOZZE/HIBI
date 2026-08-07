# 智能体工具调用（ABP 功能）— 功能与实现方案

本文档约定：通过 **Tool Use / Function Calling** 让智能体在对话中调用应用能力（日程、思维白板），实现「对话创建日程」与「基于思维节点图的项目规划与提醒」。

---

## 一、目标功能

### 1.1 对话创建日程

- **用户侧**：在智能体对话中说自然语言需求，例如「明天下午 3 点帮我加一个会：产品评审」「下周一全天写个日程：需求梳理」。
- **智能体侧**：理解意图后调用 **创建日程** 工具，写入标题、开始/结束时间等；可选支持全天、地点、提前提醒。
- **结果**：新日程出现在应用的「日程」页，并与现有同步机制一致（本地写盘 + 可同步云端）。

### 1.2 基于思维节点图的项目规划与提醒

- **用户侧**：在对话中指定某个思维节点项目（如按项目名称或「当前打开的项目」），请智能体根据该项目的白板内容做工作量分析和项目规划，并在合适的方块上添加提醒。
- **智能体侧**：
  1. 调用 **获取思维节点图** 工具：拿到指定项目的白板中所有 **方块（block）** 与 **连线（line）** 的信息（文本、结构、是否已有提醒等）。
  2. 根据这些内容做工作量分析、依赖关系与合理排期（纯模型推理，不新开工具）。
  3. 调用 **为方块添加提醒** 工具：在需要处理的方块上设置提醒时间（开始/结束），对应到应用内「该方块的提醒」以及日程中的一条（与现有「方块 ↔ 日程」同步一致）。

- **结果**：
  - 用户能在思维白板里看到对应方块已带提醒；
  - 日程页出现与这些方块绑定的日程条（现有逻辑：`ScheduleEventStore.mindBlockEventId(blockId)`，方块提醒与日程一一对应）。

---

## 二、概念与数据现状（简要）

| 概念 | 说明 |
|------|------|
| **思维节点（MindNode）** | 一个「项目」，有 id、title、essence；内含 `canvasItems`（白板元素列表）。 |
| **画布元素（CanvasItem）** | 类型：block（方块）、note、column、line（连线）。block 有 text、reminderStartTimeMs、reminderEndTimeMs、completed 等。 |
| **方块 ↔ 日程** | 方块的提醒时间与 `ScheduleEventStore` 中 id 为 `mind_block_<blockId>` 的日程条同步；在画布中设置提醒会写入日程，反之亦然。 |
| **日程（ScheduleEvent）** | 含 title、startTime、endTime、isAllDay、reminderMinutes、location、essence 等；存于 `ScheduleEventStore`，支持同步。 |
| **同步** | 思维节点、日程均通过 `/api/sync/push`、`/api/sync/pull` 与后端 `user_data` 按 user_id 同步；后端已有用户维度的 mind/schedule 数据。 |

---

## 三、实现思路（Tool Use / Function Calling）

### 3.1 总体流程

- 前端与现有智能体对话一致：用户发一条消息，请求发到后端 `/api/chat`。
- 后端在调用大模型时带上 **tools** 定义；若模型返回 **tool_calls**，后端在**服务端**执行对应工具（读/写该用户的 mind、schedule），将执行结果再发给模型，由模型生成最终自然语言回复。
- 后端响应中除 `reply` 外，可带「本轮是否执行过工具」等标记；前端若检测到执行过写操作，可主动触发一次 **sync pull**，使本地日程/思维节点与云端一致，界面即时更新。

### 3.2 工具定义（建议）

以下三个工具由后端实现并在 `/api/chat` 的模型请求中通过 `tools` 传入（OpenAI 兼容格式）。

| 工具名 | 用途 | 入参（示意） | 执行方 |
|--------|------|--------------|--------|
| **create_schedule** | 创建一条日程 | title, start_time, end_time, is_all_day?, location?, reminder_minutes? | 后端：写该用户 schedule 并合并到 user_data |
| **get_mind_canvas** | 获取某项目的白板内容（方块+连线） | project_id 或 project_title（或 current，表示「当前项目」需前端传入） | 后端：从 user_data 的 mind 中取对应节点及 canvasItems，过滤出 block/line，返回结构化摘要 |
| **set_block_reminder** | 为指定方块设置提醒时间 | block_id, start_time, end_time；可选 project_id 以定位节点 | 后端：在 user_data 的 mind 中找到对应节点，更新该 block 的 reminderStartTimeMs/reminderEndTimeMs，并写入一条 id 为 mind_block_&lt;blockId&gt; 的日程到 schedule |

说明：

- **get_mind_canvas** 的「当前项目」：若采用仅后端执行工具，则需前端在发 `/api/chat` 时附带当前打开的项目 id（如 `current_mind_node_id`），后端用该 id 查 mind 数据；否则只能通过 project_id / project_title 指定。
- **set_block_reminder** 的执行结果应保证与现有逻辑一致：方块上的提醒与日程条一一对应，便于现有白板与日程页正确显示和同步。

### 3.3 后端职责（概要）

1. **鉴权**：`/api/chat` 要求携带 `Authorization: Bearer <token>`，解析出 user_id；未登录可不支持工具调用或返回提示。
2. **加载用户数据**：从 `user_data` 表（或等价存储）读取该用户的 mind、schedule（与现有 sync 一致）。
3. **构建 system prompt**：在现有 agent 描述基础上，增加简短说明——本助手可以「创建日程」「查看某项目的思维节点图（方块与连线）」「在指定方块上添加提醒以做项目规划」；并说明何时用哪个工具（例如：用户要加日程用 create_schedule；用户要基于某项目白板做规划时先 get_mind_canvas 再 set_block_reminder）。
4. **调用模型**：请求体带 `tools`（上述三个）、`messages`；若响应中有 `tool_calls`，则：
   - 按 name 分发到 create_schedule / get_mind_canvas / set_block_reminder；
   - 传入解析后的 arguments，在内存中修改 mind/schedule 结构；
   - 将修改写回 user_data（与 sync 的存储格式一致）；
   - 将工具执行结果作为一条 assistant tool result 消息追加到 messages，再次请求模型得到最终 `reply`。
5. **响应**：返回 `{ "reply": "...", "tools_used": true/false 或具体列表 }`；前端若 `tools_used` 为 true，可触发一次 pull 以刷新本地。

### 3.4 前端职责（概要）

1. **发请求时**：若当前在「某思维项目」上下文（例如从该项目的白板页进入智能体），可在 body 中增加 `current_mind_node_id`（可选），供后端 get_mind_canvas 使用「当前项目」。
2. **收响应后**：若后端标明本轮使用了写类工具（如 create_schedule、set_block_reminder），则调用现有同步拉取（如 `UserSyncScheduler.pullAndNotify()` 或等价），使日程页与思维白板立即反映新数据。
3. **无需在前端实现「浏览器内核」或额外 WebView**：工具在后端执行，前端只负责对话与同步刷新。

---

## 四、需要您确认或选择的点

1. **「当前项目」的语义**  
   - 是否需要在对话里支持「根据当前打开的白板项目来规划」？若是，前端是否方便在进入智能体时传入 `current_mind_node_id`（例如从主导航进入则无，从某项目内入口进入则传该项目 id）？

2. **指定项目的方式**  
   - 除「当前项目」外，是否只支持按 **项目名称** 指定（后端在 mind 列表里按 title 匹配）？是否还需要支持按 **项目 id** 指定（例如用户说「用 node_xxx 这个项目」）？

3. **create_schedule 的粒度**  
   - 是否与现有日程页一致：支持全天、开始/结束时间、提前 N 分钟提醒、地点、要义（essence）？还是先做最小集（标题 + 开始 + 结束）？

4. **set_block_reminder 的粒度**  
   - 是否与现有白板一致：每个方块一个时间段（reminderStartTimeMs / reminderEndTimeMs），对应一条日程？是否需要支持「为同一方块设置多个时间段」（当前数据模型为单一时段，若需多时段需扩展）。

5. **Tool Use 与模型**  
   - 当前后端使用的模型（如豆包）是否已支持 OpenAI 兼容的 `tools` / `tool_calls`？若否，是否需要改为支持 Function Calling 的模型或兼容层？

6. **ABP 一词**  
   - 您提到的「ABP 功能」是否即指上述「应用能力（日程 + 思维白板）」的暴露为工具，还是另有特指（如某第三方 ABP 框架）？若为前者，本文档按「应用能力 = 工具」理解。

---

## 五、小结

- **功能 1**：通过工具 **create_schedule**，在对话中根据用户需求创建日程，与现有日程与同步兼容。
- **功能 2**：通过 **get_mind_canvas** 获取指定（或当前）项目的白板方块与连线，模型据此做工作量与规划分析；再通过 **set_block_reminder** 在需要处理的方块上添加提醒，与现有「方块—日程」同步一致。
- **实现路径**：采用 **后端 Tool Use / Function Calling**：后端解析 token、读写 user_data 中的 mind/schedule，执行三样工具并写回；前端仅需传可选 `current_mind_node_id` 并在工具执行后触发 sync pull 即可，**不需要在项目中自嵌浏览器内核**。

请您确认或补充上述「需要确认的点」，确认后可按此文档在后端实现 tools 与 `/api/chat` 改造，前端做传参与拉取刷新即可。
