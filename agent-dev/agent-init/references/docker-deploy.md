# Docker 部署（Postgres 持久化 / Windows + WSL / 原生 Linux）

完整文件：`templates/docker-compose.yml`、`templates/Dockerfile.oss`、`templates/checkpointer.py`。

## 两条路线

| 路线 | 基础镜像 | 要求 | 数据落点 |
|---|---|---|---|
| ① 官方平台镜像 | `langchain/langgraph-api:<py>`（`langgraph dockerfile` 生成） | **必须** `LANGSMITH_API_KEY`（有 LangGraph Cloud 权限）或 `LANGGRAPH_CLOUD_LICENSE_KEY`，否则启动即 `License verification failed` 退出 | checkpoints + threads/runs/assistants 全在 PG |
| ② **OSS 服务端 + 自定义 checkpointer（本项目默认）** | `python:3.12-slim` + `langgraph-cli[inmem]` | 无需 license | **checkpoints（消息/todos/文件）在 PG**；线程/运行元数据在容器内 `.langgraph_api`（挂卷） |

## 架构与卷

```
docker compose (name: agent-console)
├── postgres  pgvector/pgvector:pg16   卷 pgdata     → 会话内容（checkpoints）
├── redis     redis:6
├── langgraph-api  Dockerfile.oss → :2024
│   ├── 卷 appdata  /app/backend/.langgraph_api  → 线程/运行元数据（OSS 路线特性）
│   ├── 卷 cfgdata  /app/config                 → model_config.json / agent_config.json（含 system prompt）
│   └── 卷 datadata /app/data                   → skills/（技能库） + sandbox/（execute 的工作目录）
└── frontend  nginx → :5173
```

环境变量（关键三项）：`POSTGRES_URI` / `REDIS_URI`（官方 compose 同款）、`DEEPSEEK_API_KEY`（模型密钥）、
`AGENT_CONSOLE_CONFIG_DIR=/app/config`、`AGENT_CONSOLE_DATA_DIR=/app/data`。

## 自定义 checkpointer（官方要求的形态）

```python
@contextlib.asynccontextmanager
async def make_checkpointer():
    uri = os.environ.get("POSTGRES_URI") or os.environ.get("POSTGRES_URI_CUSTOM")
    if uri:
        from langgraph.checkpoint.postgres.aio import AsyncPostgresSaver
        async with AsyncPostgresSaver.from_conn_string(uri) as saver:
            await saver.setup()          # 建表 + 索引（幂等）
            yield saver
    else:
        from langgraph.checkpoint.sqlite.aio import AsyncSqliteSaver
        async with AsyncSqliteSaver.from_conn_string("./.checkpoints.sqlite") as saver:
            await saver.setup()
            yield saver
```

> 官方文档：自定义 checkpointer 必须是**异步上下文管理器**，yield 一个 `BaseCheckpointSaver`，连接生命周期由服务端托管。

## 启停（Windows + WSL）

```powershell
powershell -ExecutionPolicy Bypass -File .\docker-up.ps1          # 启动（-Build 重建镜像）
powershell -ExecutionPolicy Bypass -File .\docker-down.ps1        # 停止（-Purge 连数据卷删除）
```

脚本内置：**WSL 保活会话** + `docker compose up -d` + 健康等待 + 打印地址。
命令行等价物：`wsl -d Ubuntu -e bash -lc "cd /mnt/e/<项目> && docker compose up -d --build"`。

## 持久化验证清单（必做）

```bash
# 1) 先确认容器真在跑（否则你可能在打宿主机遗留的 dev 服务，会得出"PG 表 0 行却像持久化"的假结论）
docker compose ps          # 必须能看到 langgraph-api

# 2) 造一轮对话（thread_id 必须走 path，放 body 会被忽略 → 变成无状态运行）
curl -X POST localhost:2024/threads -H 'Content-Type: application/json' -d '{"metadata":{}}'
curl -X POST localhost:2024/threads/<tid>/runs/wait -H 'Content-Type: application/json' \
     -d '{"assistant_id":"agent","input":{"messages":[{"role":"user","content":"记住 123"}]}}'

# 3) 数据真在 PG（注意：消息在 checkpoint_writes，不在 checkpoint_blobs）
docker compose exec -T postgres psql -U postgres -c \
  "select 'writes',count(*) from checkpoint_writes union all select 'checkpoints',count(*) from checkpoints;"

# 4) 重建容器后历史仍在、能接着聊、配置与技能也在
docker compose up -d --force-recreate langgraph-api
curl localhost:2024/threads/<tid>/state      # 历史还在
curl localhost:2024/demo/agent-config        # system prompt 还在
curl localhost:2024/demo/skills              # 技能还在
```

## Windows + WSL 特有的坑

| 现象 | 原因 / 处理 |
|---|---|
| 容器起来十几秒全变 `Exited (0)`，:2024 时通时不通 | **WSL 在最后一条 `wsl.exe` 命令结束后被系统收起**，dockerd 随之停止。`.wslconfig` 的 `vmIdleTimeout` 对 WSL2 **无效**。解法：① 所有服务加 `restart: unless-stopped`；② 用保活会话 `wsl -d Ubuntu -e sleep 100000`（`docker-up.ps1` 已内置） |
| 明明改了后端代码/删了接口，行为却没变 | 先确认容器真在跑：`docker compose ps` 里要有 `langgraph-api`；**否则你打的是宿主机遗留的 `langgraph dev`** |
| 构建报 `license verification failed` | 用了官方 `langchain/langgraph-api` 镜像但没配 key/license → 换 `Dockerfile.oss` |
| 构建报 `demo-backend not satisfiable` | `requires-python` 与基础镜像 Python 版本不一致 → `langgraph.json` 加 `"python_version": "3.12"` 重新生成 |
| 构建报 `Multiple top-level modules discovered in a flat-layout` | 平铺布局有 `agent.py`+`api.py` 两个顶层模块 → pyproject 显式 `[tool.setuptools] py-modules = ["agent","api"]` |
| 启动报 `libpq library not found` | slim 镜像没 libpq → 依赖写 `psycopg[binary]` |
| 依赖装不上 `deepagents>=1.15` | npm 与 Python 包版本号不同步 → Python 侧当前是 `deepagents>=0.7.25` |
| 改了 compose 的 `name:` 后数据"没了" | 项目名决定卷名（`<project>_pgdata`）→ 迁移：`docker volume create` 新卷 + 用临时容器 `cp -a /from/. /to/` |

## 原生 Linux 服务器

- 不需要 WSL，项目放上去直接 `docker compose up -d --build`
- 防火墙/安全组放行 **2024 / 5173**；`sudo systemctl enable docker`（重启后自动起）；用户在 `docker` 组免 sudo
- 这些都由 `agent-dev/env-preflight` 的 `preflight.sh` 自动检查