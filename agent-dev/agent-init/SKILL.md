---
name: agent-init
description: 初始化一个 Agent Console 全栈项目的标准形态：DeepAgents 后端（运行时配置中间件 + 组合后端 + 技能库）、官方 deep-agents-ui 风格前端（对话 / 配置双 tab / 工具注册双 tab / 未开发占位）、Docker + Postgres 持久化部署。当要新建 agent 项目脚手架、给 deepagents 配前端、接 useStream/useThreads、做模型/Agent 配置页、工具注册与技能库、Docker 部署到 Postgres 时使用。触发词：初始化agent项目、agent脚手架、deepagents前端、官方UI、deep-agents-ui、useStream、langgraph dev、agent聊天界面、agent配置页、system prompt 配置、工具注册、技能库、skills 上传、docker 部署 agent、postgres 持久化、checkpointer。
---

# Agent Console 初始化（DeepAgents 全栈 · 完整形态）

> **开工前先跑 `agent-dev/env-preflight`**（装 docker/python/uv/bun + 环境体检 + 版本一致性）。
>
> 详细资料在 `references/`：**可复制代码** `references/templates/`，逐块讲解
> `references/backend-agent.md` / `backend-api.md` / `langgraph-json.md` / `docker-deploy.md` / `frontend.md` / `langfuse.md`，
> 全部坑 `references/pitfalls.md`。本文件只讲**形态、决策、流程**。

## 一、完整形态（这就是"初始化一个 agent"的全貌）

```
┌─ 前端（Vite + React + @langchain/react）──────────────────────────────┐
│ 顶栏：品牌名 · 导航【对话 / 配置 / 工具注册 / 未开发界面】· 主题切换     │
│                                                                      │
│ 对话页     左：会话列表（搜索/复制/删除/清理空壳/可折叠）              │
│            中：消息流（工具卡 / 子智能体 / 思考流 / Tasks-Files 面板）  │
│            composer：思考开关 · 历史（检查点时间旅行）· 发送            │
│            右：运行详情栏（**未开发占位**）                            │
│ 配置页     tab1 Agent 配置：system prompt（自定义指令）+ 递归上限       │
│            tab2 模型配置：服务商 / key / 标准与思考模型 / temperature   │
│ 工具注册   tab1 工具：两层 expander（已集成 / 自开发 → 官方分组）      │
│            tab2 技能：SKILL.md 技能库（zip 上传 / 粘贴创建 / 删除）    │
│ 未开发界面 占位页（只写「未开发」）                                    │
└──────────────────────────────────────────────────────────────────────┘
                              ↕ HTTP/SSE
┌─ 后端（Python + deepagents + langgraph）─────────────────────────────┐
│ agent.py   双图注册（agent / agent-thinking）                         │
│            RuntimeConfigMiddleware：按配置动态换模型 / 过滤工具        │
│                                    / 追加 system prompt              │
│            CompositeBackend：default=LocalShellBackend（execute 可用）│
│                            routes: /skills/ 真实目录、/notes/ 状态    │
│            TOOL_REGISTRY（自建工具）+ skills=["/skills/"]             │
│            TodoListMiddleware（规划，必须显式挂）                      │
│ api.py     /demo/* 管理路由：模型配置 / Agent 配置 / 工具注册表 / 技能库│
│ 配置       model_config.json、agent_config.json（可挂卷）              │
│ 数据       skills/（技能库）、sandbox/（execute 工作目录）             │
└──────────────────────────────────────────────────────────────────────┘
                              ↕
┌─ 部署（Docker）──────────────────────────────────────────────────────┐
│ postgres(pgvector:pg16) + redis + langgraph-api + frontend(nginx)    │
│ 卷：pgdata(会话) / appdata(线程元数据) / cfgdata(配置) / datadata(技能)│
│ OSS 路线：python:3.12-slim + langgraph-cli[inmem] + 自定义 PG checkpointer│
└──────────────────────────────────────────────────────────────────────┘
```

## 二、八条关键决策（踩过坑后固化）

1. **运行时配置中间件**：`RuntimeConfigMiddleware` 每次模型调用前读配置（模型 / 工具启停 / system prompt 追加），改配置=写文件、下次运行生效。**不要**靠热重载、也不要重建图（Windows 上 `langgraph dev` 热重载不可靠）。→ `references/backend-agent.md`
2. **思考模式 = 多图注册 + 前端切 assistantId**：`agent`（标准模型）与 `agent-thinking`（deepseek-reasoner）各一图，前端"思考"开关切 `assistantId` 并用 `key` remount。**线程状态跨图共享**，所以会话列表**不要按图过滤**，切换时把当前 threadId 继续作为 seed。
3. **管理后台走 `langgraph.json` 的 `http.app`**（`/demo/*`），与图同进程同端口；`langgraph-cli[inmem]` **不自带 fastapi**，要显式装（文件上传还需 `python-multipart`）。
4. **能用平台 API 就不自建后端端点**：会话、运行、检查点、图拓扑、store、metrics 全由平台提供（`/docs` 可查）。自建范围只限"平台不认识的概念"：模型 key、工具启停、system prompt、技能库。
5. **前端照搬官方 deep-agents-ui 结构**（会话列表 / 聊天区 / 工具卡 / Tasks-Files 面板），Next.js+shadcn 换成 Vite+原生 CSS，配色取官方 `globals.css` 两套 token。
6. **破坏性操作一律先确认**（`ConfirmDialog`），批量操作"预检 → 确认 → 执行"。
7. **未开发的功能先占位**：`NotDeveloped` 组件只写「未开发」，导航项直接叫「未开发界面」；不要写长规划清单。
8. **监控走 Langfuse（可选，env 开关零侵入）**：`langfuse_model_cls()` 包模型类（重写 bind_tools，在绑定产物上 `with_config` 注入 callbacks）→ 每次模型调用一条 trace（输入/输出/token/latency/session）。不配 key 时代码路径完全不变。langchain 1.4.5 只有 invoke config 接受 callbacks —— 实测矩阵与坑见 `references/langfuse.md`

## 三、后端要点（细节见 references/backend-agent.md、backend-api.md）

```python
# 组合后端：default 决定 execute 是否可用；路由决定文件落哪
BACKEND = CompositeBackend(
    default=LocalShellBackend(root_dir=SANDBOX_DIR, virtual_mode=True),      # → execute 可用
    routes={
        "/skills/": FilesystemBackend(root_dir=SKILLS_DIR, virtual_mode=True),  # 技能库（真实目录）
        "/notes/": StateBackend(),                                             # 线程内文件（Tasks/Files 面板）
    },
)
agent = create_deep_agent(
    model=build_model(key="model"),          # 占位实例，真正模型由中间件注入
    tools=list(TOOL_REGISTRY.values()),
    system_prompt=SYSTEM_PROMPT,
    backend=BACKEND,
    skills=["/skills/"],                     # SKILL.md 目录 → 注入技能清单（渐进式加载）
    middleware=[RuntimeConfigMiddleware("model"), TodoListMiddleware()],   # 规划必须显式挂
)
agent_thinking = ...  # 同结构，model_key="thinking_model"
```

| 内置能力 | 提供者 | 备注 |
|---|---|---|
| `ls/read_file/write_file/edit_file/delete/glob/grep` | FilesystemMiddleware | 走 backend 路由 |
| `execute` | **需要 SandboxBackendProtocol** | `supports_execution()` 只看 Composite 的 `default` |
| `task` | SubAgentMiddleware | deepagents 自带 general-purpose 子智能体 |
| `write_todos` | **TodoListMiddleware（必须显式挂）** | 前端 Tasks 面板的数据源 |
| 技能库 | SkillsMiddleware（`skills=[...]`） | 每线程缓存一次（`skills_metadata`），可 `pinned_skills` 强制加载 |

管理接口（`api.py`）：`/demo/model-config`、`/demo/agent-config`（含 `system_prompt` + `builtin_system_prompt`）、
`/demo/tools`（全部可见工具 + 分组/来源/可用性）、`/demo/skills`（列表 / zip 上传 / 文本创建 / 删除）。

可选监控：`templates/langfuse.py`（env 开关）→ `langfuse_model_cls()` 包模型类 → Langfuse trace（`/project/<id>/traces`）；粒度与坑见 `references/langfuse.md`。

## 四、前端要点（细节见 references/frontend.md）

- `useStream({ apiUrl, assistantId, threadId, onThreadId })`；乐观更新内置，加载态 `isLoading`，历史 hydrate 看 `isThreadLoading`
- 切 assistantId / 切会话用 `key` remount；submit 带 `config: { recursion_limit }`
- 思考流**两条来源都要读**：content blocks（`{type:"reasoning"}`）+ `additional_kwargs.reasoning_content`
- 多 tab 页：tab 同步 URL（`?tab=`）+ 旧路由 `Navigate replace`；每个 tab 独立组件
- 主题两态直接翻转 + `index.html` 内联脚本防闪
- 会话能力全走平台 API：`threads.search/count/copy/prune/getHistory/updateState`、`assistants.search/getGraph`

## 五、部署要点（细节见 references/docker-deploy.md）

- 两条路线：① 官方 `langchain/langgraph-api` 镜像（**需 LANGSMITH_API_KEY/license**）；② **OSS 服务端 + 自定义 checkpointer（默认，无需 license）**
- 数据落点：会话 → PG（`pgdata`）；线程元数据 → `appdata`；配置（含 system prompt）→ `cfgdata`；技能库/沙箱 → `datadata`
- 配置目录与数据目录用环境变量指到卷：`AGENT_CONSOLE_CONFIG_DIR=/app/config`、`AGENT_CONSOLE_DATA_DIR=/app/data`
- Windows+WSL：**WSL 会在最后一条 `wsl.exe` 命令结束后被收起**（`.wslconfig` 的 `vmIdleTimeout` 对 WSL2 无效）→ 服务加 `restart: unless-stopped` + 保活会话（`docker-up.ps1` 已内置）；原生 Linux 服务器则注意防火墙/安全组与 `systemctl enable docker`
- 验证持久化前**先确认容器真在跑**（`docker compose ps` 里有 `langgraph-api`），否则可能在打宿主机遗留的 dev 服务

## 六、初始化流程

```
0) agent-dev/env-preflight        → install-deps（装依赖）+ preflight（体检）
1) 后端：agent.py → api.py → langgraph.json → pyproject.toml → .env
   （从 references/templates/ 复制后按注释改）
2) 起后端：langgraph dev --port 2024；curl /ok、/demo/tools 验证
3) 前端：vite + @langchain/react + react-router；lib/chat.tsx → lib/api.ts → theme → 组件 → 页面
4) 联调：发一条消息（工具调用 + 回复）；切思考模式验证 reasoning 流
4.5) 可选：接 Langfuse trace —— 复制 `templates/langfuse.py` + `.env` 配 key（本地自托管见 `references/langfuse.md`）→ 跑一轮看 `:3000/traces`
5) Docker：docker-compose.yml + Dockerfile.oss + checkpointer.py + 启停脚本 → 验证“重建容器后会话/配置/技能都在”
6) 文档：把本项目的形态与新增坑回写到本 skill 的 references/
```

## 七、坑（完整表见 references/pitfalls.md）

高频十条：

| 症状 | 一句话原因 |
|---|---|
| 改了代码行为没变 | Windows 上 `langgraph dev` 热重载不可靠 → 重启服务并确认进程真的换了 |
| `execute` 不可用 | `supports_execution()` 只看 Composite 的 `default` → default 用 `LocalShellBackend` |
| Tasks/Files 面板空 | 换真后端后没有 `files` 通道 → Composite 里加一条 `StateBackend` 路由（`/notes/`） |
| `model` 报 `'coroutine' object has no attribute 'result'` | `awrap_model_call` 没 `await handler(...)` |
| 未配置 Key 只看到 401 | `before_agent` + `@hook_config(can_jump_to=["end"])` 短路一句人话 |
| 上传接口报 `Blocking call to os.getcwd` | 端点写成 `async def` → 改同步 `def` |
| 构建报 `not satisfiable` | `requires-python` 与镜像 Python 不一致 → `python_version` |
| 容器十几秒后 `Exited (0)` | WSL 被收起 → `restart: unless-stopped` + 保活 |
| 模型"失忆"、检查点为 0 | `thread_id` 放 body 被忽略 → 用 `POST /threads/{id}/runs/wait` |
| 思考面板/文件弹窗异常 | reasoning 要读两条来源；`files` 是 `{content,…}` 结构体 |

## 八、变体与路线

**v1 刻意不做**：编排页 / 拓扑可视化（普通 agent 用 ReAct/DeepAgent 默认循环已够；需要时用 `getGraph(xray)` + `threads.getHistory` + `forkFrom` + `subagents=`）；人审中断（`interrupt_on` + `stream.respond`，Provider 已预留）；长期记忆（`/store/*` + memory 中间件）；多环境 dev/prod 分层。

**其他方向**：官方原版前端（`E:/deep-agents-ui`，旧版 SDK 写法）；上线到 LangGraph Platform（官方镜像需 license，但 threads/runs/assistants 也一并落 PG）；把 `execute` 换成真隔离沙箱（E2B / Daytona）。