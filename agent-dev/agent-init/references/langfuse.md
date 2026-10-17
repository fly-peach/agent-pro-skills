# Langfuse trace 监控（可选接入）

给 Agent Console 加 LLM 可观测：每次模型调用的 **输入 / 输出 / token / 耗时 / 工具集** 都落在本地 Langfuse UI（`/project/<id>/traces`）。
设计原则：**env 开关，未配置 = 零侵入**（不装 SDK、不配 key 时代码路径完全不变）。

本地 Langfuse = **自托管**（GitHub 克隆官方仓，web 镜像 4.63.0；本机在 `E:/langfuse`）。
**已实测打通**：UI 能看到 trace（含 session / user / tags / tokens / latency / 工具参数与结果），且 **Docker 容器里的后端也能上报**（经 host.docker.internal）。

## 一、部署本地 Langfuse（6 个容器）

**从 GitHub 克隆官方仓库**（自托管编排随仓库走，不要自己从零写 compose）：

```bash
git clone https://github.com/langfuse/langfuse.git
cd langfuse
git checkout v4.63.0   # 可选：固定版本；不 checkout 则跟最新
```

然后在仓库根建 `.env`（compose 插值用；不要复制 `.env.prod.example`，那个 DATABASE_URL 指向不存在的 `db:`）：
NEXTAUTH_SECRET=<hex>            # openssl rand -hex 32
SALT=<hex>
ENCRYPTION_KEY=<64 位 hex>
LANGFUSE_INIT_ORG_ID=org-agent-console        # ⚠️ 必填，否则其他 INIT_* 全被忽略
LANGFUSE_INIT_PROJECT_ID=proj-agent-console   # ⚠️ 必填，否则 API key 不会创建
LANGFUSE_INIT_ORG_NAME=agent-console
LANGFUSE_INIT_PROJECT_NAME=agent-console
LANGFUSE_INIT_PROJECT_PUBLIC_KEY=pk-lf-...    # 自己生成的随机串
LANGFUSE_INIT_PROJECT_SECRET_KEY=sk-lf-...
LANGFUSE_INIT_USER_EMAIL=dev@agent-console.local
LANGFUSE_INIT_USER_PASSWORD=...
docker compose up -d
```

- 6 容器全 Healthy 后 `http://localhost:3000`（健康检查 `GET /api/public/health`）
- **`LANGFUSE_INIT_*` 只在首次初始化读取**；改了 `.env` 后要 `docker compose up -d --force-recreate langfuse-web`
  （`restart` 不会重读环境变量）
- key 自己生成（`pk-lf-`/`sk-lf-` + 随机 hex），init 只负责登记给项目
- 验证 key：`curl -u pk:sk http://localhost:3000/api/public/projects`
- 不用时 `docker compose down`（`-v` 连数据清）

## 二、后端接入（v4.63 + langchain 1.4.5 实测有效的方式）

1. **依赖**：`pyproject.toml` 加 `"langfuse>=5"`（SDK 5.x 配 server 4.x）；uv 环境：
   `uv pip install --python .venv/Scripts/python.exe "langfuse>=5"`
2. **`.env`**（gitignore）：`LANGFUSE_PUBLIC_KEY` / `LANGFUSE_SECRET_KEY` / `LANGFUSE_HOST=http://localhost:3000`
3. **代码**：复制 `templates/langfuse.py`，`build_model()` 里把 `ChatDeepSeek(...)` 换成
   `langfuse_model_cls(ChatDeepSeek)(...)`（一行改动，见模板 docstring）

### 为什么是"模型子类 + bind_tools 后 with_config"（重要，别照旧文档写）

LangChain 1.4.5 实测矩阵：

| 注入方式 | 结果 |
|---|---|
| 模型构造器 `callbacks=[handler]` | ❌ 字段存在但 runtime 不采纳（无 span） |
| `model.bind(callbacks=...)` | ❌ `generate_prompt() got multiple values for keyword argument 'callbacks'` |
| invoke 的 `config={"callbacks":[...]}` | ✅ 唯一有效路径 |
| `with_config(callbacks=...)` | ✅ config 合并，不撞 kwargs |
| LangGraph 平台服务整图注入 | ❌ `Runtime` 不暴露 RunnableConfig，服务端没有口子 |

框架每次调模型前都会 `request.model.bind_tools(...)`（`langchain/agents/factory.py`），
所以模板的子类重写 `bind_tools()`，在**绑定产物**上 `with_config(callbacks=[handler])` ——
正好落在唯一有效的注入点上，且 `RuntimeConfigMiddleware` 每请求重建模型 → 每请求一个 handler，改 `.env` 即时生效。

> 另一条路 `langfuse.openai` 客户端包装（`root_client`/`async_client`）：同步可用，但
> openai>=3 下 async 走 `with_raw_response.create` 直接 `AttributeError` —— **别用**。

## 三、session / user / tags 关联（已实测）

SDK v5 的 `CallbackHandler()` 没有 session_id 构造参数（v2 时代有），走 **config metadata 魔法键**
（SDK 源码 `_convert_run_metadata` 认三个键），且 metadata 会随 RunnableConfig 传播到模型调用：

```python
# 直接调图（脚本/测试）：
agent.ainvoke(input, {"configurable": {"thread_id": tid},
                      "metadata": {"langfuse_session_id": tid,
                                   "langfuse_user_id": "dev",
                                   "langfuse_tags": ["e2e-demo"]}})
# 前端 useStream.submit 同理把 metadata 放进 config
```

UI 详情页头部会出现 `session ↗ · user: dev ↗ · tag`（Sessions / Users 页可按会话聚合）。

## 四、验证

1. `curl http://localhost:3000/api/public/health` → `{"status":"OK","version":"4.x"}`
2. 发一轮对话 → 打开 `http://localhost:3000/project/proj-agent-console/traces`
3. 详情页看：System / User / Assistant 全文、Tools 列表、tokens、latency（约 1s 量级）
4. ⚠️ **v4 是 events_only 模式**：老的 `GET /api/public/traces` 端点已移除（返回
   "endpoint is not available ... events_only mode"），查数据用 UI 或 v4 Query API
5. 裸脚本测试要显式 `get_client().flush()`（SDK 后台批量导出，进程退出会丢）；服务常驻不用
6. 排障开关：`.env` 加 `LANGFUSE_ENABLED=0` → 完全回到无 trace 状态

## 五、已知边界（v1 接入粒度）

| 项 | 说明 |
|---|---|
| trace 粒度 | **每次模型调用一条**（bind_tools 后的模型调用）。工具执行节点（ToolNode）不单独成 span；要从 trace 里看工具决策（assistant 消息里的 tool_calls） |
| session 关联 | 靠调用方在 config.metadata 里带 `langfuse_session_id`；不传则每条 trace 独立 |
| 要全图 trace | 需自建 agent 服务（FastAPI 里 `graph.astream(input, config={"callbacks": ...})`），平台 API 形态注入不了 |
| 容器内 HOST | api 容器访问宿主机 Langfuse：`LANGFUSE_HOST=http://host.docker.internal:3000`，compose 加 `extra_hosts: ["host.docker.internal:host-gateway"]` |
| 与项目一起部署 | 推荐两栈分开、网络互通：demo compose 的 api 服务加三个 `LANGFUSE_*` 环境变量 + `extra_hosts`（模板已内置，默认留空=关闭）；`pyproject.toml` 加 `langfuse>=5`；**`docker compose build langgraph-api` 重建**（SDK 要进镜像；新后端模块记得加进 `Dockerfile.oss` 的 COPY 列表）。已实测容器内上报成功 |

## 六、坑速查

| 症状 | 原因 |
|---|---|
| `LANGFUSE_INIT_*` 全被忽略 | 没设 `LANGFUSE_INIT_ORG_ID`；API key 没建 → 还差 `LANGFUSE_INIT_PROJECT_ID` |
| 改了 init 配置不生效 | `docker compose restart` 不重读环境变量 → `up -d --force-recreate langfuse-web` |
| API 查 traces 报 "events_only mode" | v4 移除了老端点 → 用 UI / v4 Query API |
| UI 没 trace 但 DEBUG 有 "Processing span" | 等几秒（批量导出+ingestion）；裸脚本要 `get_client().flush()` |
| `async_client.with_raw_response.create` AttributeError | langfuse.openai 包装与 openai>=3 不兼容 → 用模板的 model_cls 方案 |
| 容器里连不上 `localhost:3000` | 容器里的 localhost 是自己 → `host.docker.internal` + `extra_hosts` |
| `No module named langfuse` | uv venv 没同步 → `uv pip install --python .venv/...` 或 `uv sync` |
| 配了 key 但没 trace | `LANGFUSE_ENABLED=0` 被显式关了？langgraph dev 没读到 `.env`？key 为空时静默关闭是特性 |
