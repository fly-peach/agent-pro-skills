# Langfuse trace 监控（可选接入）

给 Agent Console 加 LLM 可观测：每次模型调用的 **输入 / 输出 / token / 耗时 / 工具调用决策** 都落在本地 Langfuse UI（`:3000/traces`）。
设计原则：**env 开关，未配置 = 零侵入**（不装 SDK、不配 key 时代码路径完全不变）。

本地已有自托管 Langfuse（v4.59.0 源码仓 + compose，位于 `E:/langfuse`）。

## 一、部署本地 Langfuse（6 个容器）

```bash
cd /e/langfuse
cp .env.prod.example .env        # 改 NEXTAUTH_SECRET / SALT（本地随便换串字符串即可）
docker compose up -d             # langfuse-web :3000 + worker + clickhouse + minio + redis + postgres
```

- 首次拉镜像约 2GB+（`docker.langfuse.com/langfuse/langfuse:4`）；栈较重，本机内存建议 ≥ 6GB
- 打开 `http://localhost:3000` 注册（首个用户自动建 org），建一个 Project，到
  **Settings → API Keys** 生成 `pk-lf-...`（public）/ `sk-lf-...`（secret）
- **免手点**（推荐）：compose 已暴露 `LANGFUSE_INIT_*`，在 `.env` 里填好再首次启动：

```bash
LANGFUSE_INIT_ORG_NAME=acme
LANGFUSE_INIT_PROJECT_NAME=agent-console
LANGFUSE_INIT_PROJECT_PUBLIC_KEY=pk-lf-...
LANGFUSE_INIT_PROJECT_SECRET_KEY=sk-lf-...
LANGFUSE_INIT_USER_EMAIL=dev@acme.local
LANGFUSE_INIT_USER_PASSWORD=changeme-1234
```

> 注意 key 是**自己生成**（格式 `pk-lf-` / `sk-lf-` + 随机串），init 只是把它们登记给项目。
> 不用时 `docker compose down`（加 `-v` 连数据一起清）。

## 二、后端接入（三步）

1. **依赖**：`pyproject.toml` 加 `"langfuse>=5"`（SDK 5.x 配 server 4.x）；uv 环境装包：
   `uv pip install --python .venv/Scripts/python.exe "langfuse>=5"`（或改 pyproject 后 `uv sync`）
2. **`.env`**（gitignore，勿入库）：

```bash
LANGFUSE_PUBLIC_KEY=pk-lf-...
LANGFUSE_SECRET_KEY=sk-lf-...
LANGFUSE_HOST=http://localhost:3000      # langgraph dev 在宿主机跑
```

3. **代码**：复制 `templates/langfuse.py` 到后端，`build_model()` 里挂上：

```python
from langfuse_setup import langfuse_model_kwargs
model = ChatOpenAI(model=cfg["model"], api_key=cfg["api_key"], ..., **langfuse_model_kwargs())
```

因为 `RuntimeConfigMiddleware` 每次请求都重建模型实例，所以天然做到 **每请求一个 handler**，改 `.env` 即时生效（不用重启）。

### 会话关联（可选）

SDK v5 的 `CallbackHandler()` **没有** session_id/user_id 构造参数，走 config metadata 魔法键
（源码 `langfuse/langchain/CallbackHandler.py` 里 `_convert_run_metadata` 认这三个键）：

```python
# 前端 useStream.submit 时带上（metadata 会随 RunnableConfig 传播到每次模型调用）：
submit({ messages }, { config: { metadata: { langfuse_session_id: threadId } } })
# UI 上 trace 的 Session 列即 threadId，可按会话聚合查看
```

## 三、验证

1. `curl -s http://localhost:3000/api/public/health` → `{"success":true,...}`（服务活着）
2. 发一轮对话 → `http://localhost:3000/traces` 出现新 trace：模型输入输出、token、latency
3. 排障开关：`.env` 里 `LANGFUSE_ENABLED=0` → 完全回到无 trace 状态

## 四、已知边界（v1 接入粒度）

| 项 | 说明 |
|---|---|
| trace 粒度 | **每次模型调用一条**（模型级 callbacks）。LangGraph 平台服务里没有给整图注入 callbacks 的口子（`Runtime` 不暴露 RunnableConfig），所以工具执行节点（ToolNode）不在 trace 内 |
| 要全图 trace | 需自建 agent 服务（FastAPI 里 `graph.astream(input, config={"callbacks": [handler], "metadata": {...}})`），整图一棵树含工具节点。平台 API 形态暂不支持 |
| 容器内 HOST | api 容器访问宿主机 Langfuse：`LANGFUSE_HOST=http://host.docker.internal:3000`，且 compose 里 api 服务加 `extra_hosts: ["host.docker.internal:host-gateway"]` |
| SDK 版本 | server v4 ↔ SDK v5；v3 SDK 也可（import 路径同为 `langfuse.langchain`）。v5 删除了 `session_id` 构造参数（v2 时代有），别照旧文档写 |

## 五、坑速查

| 症状 | 原因 |
|---|---|
| trace 里 Session 全空 | 没传 `metadata.langfuse_session_id`（v5 无构造参数，只能走 metadata 魔法键） |
| 容器里连不上 `localhost:3000` | 容器里的 localhost 是自己 → `host.docker.internal` + `extra_hosts` |
| `No module named langfuse` 但 pyproject 有 | uv venv 没同步 → `uv sync` 或按上面对 `.venv` 直接装 |
| UI 打不开 / 502 | 6 个容器要全 Healthy（clickhouse / minio 没起来会 502），`docker compose ps` 看状态 |
| 装了 SDK 但没 trace | `.env` 没被 langgraph dev 读到（检查启动方式是否带 `--env-file`）或 key 为空（`langfuse_enabled()` 返回 False，静默关闭是特性） |
