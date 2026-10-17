# 坑汇总（按类别）

出问题时先在这里搜。每条都是实际踩过的。

## A. 环境与版本

| 症状 | 原因 / 处理 |
|---|---|
| 构建报 `demo-backend not satisfiable` | `pyproject.requires-python` 与官方镜像 Python 版本不一致（默认 3.11）→ `langgraph.json` 写 `"python_version": "3.12"` 并重新生成 Dockerfile |
| 装不上 `deepagents>=1.15` | **npm 与 Python 包版本号不同步**：Python 侧当前是 `0.7.x`，写 `deepagents>=0.7.25` |
| `Multiple top-level modules discovered in a flat-layout` | 平铺布局有 `agent.py`+`api.py` → pyproject 显式 `[tool.setuptools] py-modules = ["agent","api"]` |
| 启动报 `libpq library not found` / `No module named 'psycopg_binary'` | slim 镜像没 libpq → 依赖写 `psycopg[binary]` |
| 启动即崩 `requires the colorama package` | Windows venv 没装 `colorama`（langgraph dev 彩色日志依赖；全局 conda 自带，venv 不自带） |
| `UnicodeDecodeError: 'gbk' codec` | 中文 Windows 未开 UTF-8 模式 → 启动前 `PYTHONUTF8=1` |
| 装新包后启动崩 `cannot import name '_ExtendedAttributes'` | uv 连带升级 opentelemetry 家族破坏 langgraph-api → 钉配套版本：api/sdk/otlp-http `==1.37.0` + prometheus `==0.58b0` |
| 上传文件接口报 `Blocking call to os.getcwd` | langgraph dev 的阻塞调用守卫 → 端点写成**同步 `def`**（FastAPI 丢线程池），不要 `async def` + 阻塞 IO |

## B. langgraph dev / CLI

| 症状 | 原因 / 处理 |
|---|---|
| 改了 `agent.py` / `api.py` / `langgraph.json` 但行为没变 | **Windows 上热重载不可靠** → 改完**重启服务**；确认进程真的换了（看 StartTime，别只看脚本退出码） |
| 杀了 `langgraph.exe` 但 :2024 仍被占 | multiprocessing spawn worker 继承了监听 socket 成"幽灵"（netstat 显示的 PID 已不存在）→ 按 `CommandLine LIKE '%multiprocessing.spawn%'` 找子进程全杀 |
| 用 `os.utime` 碰文件想让 watchfiles 重载 | 无效 → 别走热重载这条路，运行时行为都放**中间件**里读配置 |
| 前端 404 assistant | `assistantId` ≠ `langgraph.json` graphs 键名 |
| `Failed to import app module './api.py'` | traceback 根部通常是 `No module named 'fastapi'` → 显式安装 |
| 自定义路由冲突 | 自定义路由放自有前缀（`/demo`）；`/threads` `/runs` `/assistants` `/store` `/mcp` `/metrics` `/ok` `/docs` 都是平台保留 |

## C. 后端行为

| 症状 | 原因 / 处理 |
|---|---|
| `'coroutine' object has no attribute 'result'` | `awrap_model_call` 里调了同步 handler → 必须 `return await handler(...)`；同步/异步共用 `_apply` |
| 未配置 Key 时前端只看到 401 | `before_agent` + `@hook_config(can_jump_to=["end"])` 返回 `{"jump_to":"end","messages":[AIMessage(提示)]}` |
| `DeprecationWarning: Direct attribute assignment to ModelRequest.system_message` | 改用 `request.override(system_message=...)` |
| 改 system prompt 却弄丢 harness 指令 | 不要替换：`override(system_message=内置 + 自定义)` **追加**，否则规划/文件系统/工具规范全没了 |
| Tasks 面板永远为空 | deepagents 0.7 默认不挂规划中间件 → `middleware=[TodoListMiddleware()]`；`todos` 是 `OmitFromInput`，外部注入无效 |
| `execute` 报 `Execution not available` | `supports_execution()` **只看 Composite 的 default** → default 用 `LocalShellBackend(root_dir=…)`；生产换 E2B/Daytona |
| 换真后端后 `files` 消失、Tasks/Files 面板空 | 中间件用 `_uses_state_backend()` **递归**判断 → Composite 里加一条 `"/notes/": StateBackend()` 就有 `files` 通道 |
| 模型"失忆"、state 空、检查点为 0 | `POST /runs/wait` 的 `thread_id` 放 **body** 会被忽略 → 用 `POST /threads/{thread_id}/runs/wait` |
| 容器重建后配置被重置 | 配置落在容器 FS → `AGENT_CONSOLE_CONFIG_DIR=/app/config` + `cfgdata:/app/config` |
| 技能上传成功但模型看不到 | 线程的 `skills_metadata` 缓存没刷新（submit 带 `{"skills_metadata": null}`）；或 `skills=["/skills/"]` 与路由前缀不一致（要带结尾斜杠） |

## D. 上下文传参（"按请求/按会话传配置"）

| 通道 | 结果 |
|---|---|
| `submit(..., {config:{configurable:{x}}})` | ❌ 中间件读不到（`request.runtime` 没有 `config`） |
| HTTP `context` | ✅ 服务端支持、`runtime.context` 能读，但 **JS SDK 的 `StreamSubmitOptions` 没有 `context`** |
| `input` 带字段 + 中间件声明 `state_schema` | ✅ 中间件能读、**随 checkpoint 持久化**、SDK 原生支持 —— 需要按会话传配置时用这条 |

## E. 前端

| 症状 | 原因 / 处理 |
|---|---|
| 思考面板不显示 | reasoning 有 **两处**：content blocks（`{type:"reasoning"}`）与 `additional_kwargs.reasoning_content` → 两边都要读 |
| 文件弹窗显示 `[object Object]` | `files` 值是 `{content,encoding,…}` 结构体 → 归一化取 `content`；写回保留原结构 |
| 点卡片开关却弹出详情 | 卡片整块可点 → 开关要 `stopPropagation()`；弹窗加 Esc 与遮罩关闭 |
| 工具页只显示两三个工具 | 从编译图内省 `all_tools()`，把内置工具一起列出并标 `origin` |
| 工具页卡片被超长说明撑爆 | 卡片只留首行；完整说明放弹窗，且**参数定义排在完整说明之前** |
| 白名单迁移成黑名单后工具全被停 | 演示环境直接 `disabled_tools: []`（默认全开） |
| 主题按钮要按好几次才变 | 别把"跟随系统"做成循环态 → 两态直接翻转 + `index.html` 内联脚本防闪 |
| 切配置维度后页面不刷新 | `useEffect` 依赖要包含那个维度，切换时先清空再加载 |
| 删除点了就直接删了 | 破坏性操作必须过 `ConfirmDialog`；批量先"预检 → 确认 → 执行" |

## F. 技能库 / 平台 API / 监控

| 症状 | 原因 / 处理 |
|---|---|
| 技能 id 含中文导致异常 | id slug 化（只留 ASCII 字母数字与连字符）+ 文件名白名单过滤 |
| 技能里的脚本跑不起来 | 脚本用绝对路径；`/skills/` 是真实目录，而 `execute` 的工作目录在 default 后端（沙箱目录），不是同一个根 |
| 想加"图拓扑/会话历史/复制会话"接口 | **先用平台 API**；自建过的 `GET /demo/agent-graph` 已被平台端点取代 |
| `client.assistants.search` 类型报错 | SDK 两个重载：`includePagination: true` → `{assistants,next}`，否则 `Assistant[]`；别用 `as any` 强转 |
| 列表里点进去是空的“空壳会话” | dev 模式 checkpoint 在内存 → 用 `threads.getState` 筛出无消息的再 `threads.prune` |
| 模型构造器 / `bind(callbacks=...)` 不出 span | langchain 1.4.5 只有 invoke config 接受 callbacks → 模板的 `langfuse_model_cls` 在 bind_tools 产物上 `with_config` |
| `async_client.with_raw_response.create` AttributeError | langfuse.openai 包装与 openai>=3 不兼容 → 别用客户端包装，用 model_cls |
| Langfuse API 查 traces 报 events_only | v4 移除了老端点 → 用 UI / v4 Query API |
| Langfuse 容器里连不上 `localhost:3000` | 容器里的 localhost 是自己 → `LANGFUSE_HOST=http://host.docker.internal:3000` + compose 加 `extra_hosts: ["host.docker.internal:host-gateway"]` |
| langfuse SDK v5 设置不了 session | v5 无 `session_id` 构造参数 → 走 config `metadata` 魔法键：`langfuse_session_id` / `langfuse_user_id` / `langfuse_tags`（实测有效） |
| langfuse 装不进 demo venv | uv 管理无 pip → `uv pip install --python .venv/Scripts/python.exe "langfuse>=5"` 或改 pyproject 后 `uv sync` |
| 配了 key 但 UI 没 trace | 6 容器是否全 Healthy；`LANGFUSE_ENABLED` 是否被置 0；langgraph dev 是否读到了 `.env`；裸脚本是否忘了 `get_client().flush()` |

## G. 工程习惯（踩坑换来的）

- **每次 bash 调用 cwd 会重置** → 长命令必须显式 `cd`
- **Git Bash 里 curl 内联中文 JSON 会被 GBK 转码** → 请求体写 UTF-8 文件用 `--data-binary @file`，或用 python `urllib`
- **脚本编码**：`.sh` 必须 **LF**、`.ps1` 必须 **UTF-8 with BOM**
- **PowerShell 字符串里避免反引号与框线字符**（`═`）；`\r` 用 `[char]92` 拼
- **Python 写文件要 `newline=""`**，否则 Windows 下被转成 CRLF（`.sh` 就废了）
- **批量 `cp` / 多文件写入偶尔静默丢失** → 写完立即 `ls` 校验，别只信"成功"回执
- **UI 自检**：Playwright（`launch(executable_path=…)` 指定已装版本）+ 真实发消息，断言 `.tool-call-name` / `.meta-row` / `.thinking-body` / `data-theme`，并截图复核