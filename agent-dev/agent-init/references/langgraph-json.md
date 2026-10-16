# `langgraph.json`：部署描述文件

它被 `langgraph dev` / `langgraph up` / `langgraph dockerfile` 读取；`http` 等配置会被序列化成环境变量
（如 `LANGGRAPH_HTTP='{...}'`）传给 server 进程，server 再据此挂载自定义 FastAPI。

## 本项目用的字段

```json
{
  "dependencies": ["."],
  "python_version": "3.12",
  "graphs": {
    "agent": "./agent.py:agent",
    "agent-thinking": "./agent.py:agent_thinking"
  },
  "env": ".env",
  "http": { "app": "./api.py:app" },
  "checkpointer": { "backend": "custom", "path": "./checkpointer.py:make_checkpointer" }
}
```

| 字段 | 作用 |
|---|---|
| `dependencies` | `["."]` = 用当前目录的项目依赖构建运行环境 |
| `python_version` | **决定官方 Dockerfile 的基础镜像**（默认 3.11！）；与 `pyproject.requires-python` 不一致会导致镜像构建 `not satisfiable` |
| `graphs` | 图名 → `文件:变量`。**键名就是前端 `assistantId`** |
| `env` | 注入 `.env` 到服务端环境 |
| `http.app` | 自定义 FastAPI（`api.py:app`）→ `/demo/*` |
| `checkpointer` | `backend: "custom"` + `path` 指向自定义 checkpointer 工厂（见 `docker-deploy.md`） |

## CLI 支持的完整字段（`langgraph_cli/config.py` 实测）

```
dependencies  graphs  env  http  python_version  node_version  base_image  dockerfile_lines
pip_config_file  pip_installer  package  project_root  api_version  image_distro  keep_pkg_tools
app  source  store  auth  checkpointer  webhooks  ui  ui_config  encryption
```

值得知道的几个：`checkpointer`（持久化）、`store`（跨会话长期记忆）、`auth`（鉴权）、
`ui`/`ui_config`（平台自带调试 UI）、`dockerfile_lines`（往官方 Dockerfile 追加指令）。

## 常用命令

```bash
langgraph dev --no-browser --port 2024        # 本地开发（内存态）
langgraph dockerfile Dockerfile              # 生成官方镜像 Dockerfile（需 license 的那个）
langgraph build -t my-agent                  # 构建镜像（需 Docker 可达）
langgraph validate                           # 校验配置
```

## 坑

| 症状 | 原因 |
|---|---|
| 改了 `langgraph.json` 但图没变 | `langgraph dev` 的热重载在 Windows 上不可靠 → 重启服务（并确认进程真的换了，看 StartTime） |
| Dockerfile 基础镜像是 Python 3.11 而我们要求 3.12 | 没写 `python_version` → 加上后重新生成 Dockerfile |
| 前端 404 assistant | `assistantId` ≠ `graphs` 的键名 |
| `Failed to import app module './api.py'` | 根部错误通常是 `No module named 'fastapi'` → 显式安装 |