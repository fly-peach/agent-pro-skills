# 前端：接线、组件与约定

模板：`templates/frontend-chat.tsx`（`lib/chat.tsx`）、`frontend-api.ts`、`frontend-theme.tsx`、`frontend-tools.tsx`、`frontend-notdeveloped.tsx`。

## 1. useStream 接线（全项目唯一数据入口）

```tsx
export function useAgentStream(assistantId = "agent") {
  return useStream<AgentState>({
    apiUrl: import.meta.env.VITE_API_URL ?? "http://127.0.0.1:2024",
    assistantId,                       // = langgraph.json graphs 键名（agent / agent-thinking）
    threadId: seedThreadId,            // 打开历史会话时传入；null = 新会话
    onThreadId: (id) => { … },          // 首次 submit 后服务端分配线程号
  });
}
```

v1 SDK 要点：
- **乐观更新内置**（`optimistic` 默认 true）：submit 的消息带 id 立即上屏，按服务端回声对账 → 不要手写 `optimisticValues`
- 加载态是 `stream.isLoading`；历史会话 hydrate 用 `stream.isThreadLoading`
- 返回值还有：`values`（superstep 快照）、`messages`（token 级投影）、`interrupt`/`interrupts`、`submit`/`stop`/`respond`
- 这个版本**没有** `fetchStateHistory` / `reconnectOnMount`（旧版 SDK 才有）
- **切 assistantId / 切会话用 `key` 强制 remount**（比依赖 hook 内部重置稳）

## 2. 提交消息的标准姿势

```tsx
stream.submit(
  { messages: [{ id: crypto.randomUUID(), type: "human", content: text }] },
  { config: { recursion_limit: 50 } }     // 每轮携带运行控制
);
```

想让"技能列表/配置"每次都最新：input 里带上 `{"skills_metadata": null}`（重置技能缓存）。

## 3. 组件分层（每个组件只消费 stream 的一段）

| 组件 | 消费 | 职责 |
|---|---|---|
| `ChatInterface` | `submit` / `isLoading` | 消息区 + composer 卡片（内含 Tasks/Files 面板、思考/历史开关） |
| `ChatMessage` | `messages` | 用户右气泡 / AI 左正文 + 工具卡 + 子智能体 + 思考面板 |
| `ToolCallBox` | 消息内 tool_calls | 状态图标 + 工具名，展开 Arguments / Result |
| `SubAgentIndicator` | `task` 工具调用 | Input/Output 折叠卡 |
| `ThinkingPanel` | `additional_kwargs.reasoning_content` / content blocks | reasoning 打字机（见下） |
| `TasksFilesPanel` | `values.todos` / `values.files` | 任务清单 + 文件（可编辑写回） |
| `ThreadList` | `threads.search/count/copy/prune` | 会话列表（搜索/复制/删除/清理空壳/**可折叠**） |
| `CheckpointDialog` | `threads.getHistory` + `submit({forkFrom})` | 检查点历史 / 时间旅行 |
| `ConfirmDialog` | — | 破坏性操作统一确认 |
| `NotDeveloped` | — | 未开发占位（只写「未开发」） |

## 4. 思考流（reasoning）——两条来源都要读

```ts
// ① LangChain v1 标准 content block（dev 模式实测走这条）
content = [{ type: "reasoning", reasoning: "…" }, { type: "text", text: "…" }]
// ② additional_kwargs.reasoning_content（Docker / OSS 服务端实测走这条）
message.additional_kwargs?.reasoning_content
```

- 渲染：AI 气泡顶部嵌可折叠「思考过程」，流式期间逐 chunk 增长，`isLoading && 是最后一条` 时保持展开
- 只读 `additional_kwargs` → 某些环境下面是空；只读 blocks → 另一些环境是空。**必须两边都读**
- reasoning 会随消息进 checkpoint → 重开历史会话也能回放

## 5. 多 tab / expander / 未开发占位（本项目 UI 约定）

- **多 tab 页**：tab 状态同步到 URL 查询参数（`/settings?tab=models`、`/tools?tab=skills`），刷新/分享可回到同一 tab；每个 tab 独立成组件（各自导出 `ConfigPanel`），旧路由用 `<Navigate replace>` 重定向
- **两层 expander**（工具页）：L1 按来源分组（`LangChain 已集成` / `自开发（未集成）`）→ L2 按官方分组（文件系统 / 执行 / 委派 / 规划 / 自建）→ 卡片
- **未开发占位**：统一用 `NotDeveloped` 组件，只写「未开发」；导航项直接叫「未开发界面」，不要写长规划清单

## 6. 主题（亮暗两态）

- **两态直接翻转**（点击一次就换），`localStorage` 持久化；**不设"跟随系统"这种需要多点一次的中间态**
- 首次访客（无存储）跟随系统，并监听 `prefers-color-scheme`；一旦手动切换就固定
- **首屏防闪**：`index.html` 内联脚本在 React 挂载前写 `<html data-theme>`
- 配色取自官方 deep-agents-ui 的 `globals.css`（亮 `#f9f9f9` / 暗 `#202020`，亮暗各一套 CSS 变量）

## 7. 平台 API 优先（前端也别重复造轮子）

| 需求 | 用平台 API |
|---|---|
| 会话列表/计数/复制/批量删 | `client.threads.search / count / copy / prune` |
| 检查点 & 时间旅行 | `client.threads.getHistory` + `stream.submit(null,{forkFrom})` |
| 可用图（assistant）列表 | `client.assistants.search()`（前端不要硬编码图名） |
| 图拓扑（未开发界面/编排用） | `client.assistants.getGraph(id,{xray})` |
| 运行取消 / 重连 | `stream.stop()`；断线由 SDK 自动重连 |

坑：`client.assistants.search()` 有两个重载，传 `includePagination: true` 返回 `{assistants,next}`，否则返回 `Assistant[]`；**别用 `as any` 强转**（会选中分页那个重载导致类型报错）。

## 8. 会话管理现状（供参考）

- 会话列表**不按图拆分**（线程状态跨图共享）；标题取首条 human 消息前 60 字，`search` 未返回 `values` 时回退 `会话 <id8>`
- 删除/批量清理都要过 `ConfirmDialog`；批量操作先"预检 → 确认 → 执行"
- 清空壳：`threads.getState` 逐条筛出无消息的 → `threads.prune(ids,{strategy:"delete"})`
- 用 `POST /threads/{id}/state` 改状态需要线程已绑定图（`metadata.graph_id`），否则报 "has no assigned graph ID"