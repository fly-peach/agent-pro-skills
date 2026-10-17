# 参考实现代码（可直接复制）

本目录是 `agent-init` skill 的**可运行代码模板**，从参考实现里抽出，可直接复制。
复制到新项目后按注释里的占位改路径/密钥即可。

## 后端（Python）

| 文件 | 说明 |
|---|---|
| `agent.py` | 图定义 + 运行时配置中间件 + 工具注册表 + 技能库 + 组合后端。**核心文件** |
| `api.py` | `/demo/*` 管理路由：模型配置、Agent 配置、工具注册表、技能库（含 zip 上传） |
| `langgraph.json` | 部署描述：双图 + `http.app` + `python_version` + 自定义 checkpointer |
| `checkpointer.py` | 自定义 checkpointer（`POSTGRES_URI` → `AsyncPostgresSaver`，否则 SQLite） |
| `pyproject.toml` | 依赖声明（含 `deepagents` / `langchain-deepseek` / checkpoint-postgres / `psycopg[binary]` / `python-multipart`） |
| `langfuse.py` | Langfuse trace 接入（env 开关）：`langfuse_model_cls()` 包模型类，未配置零侵入 |
| `Dockerfile.oss` | OSS 服务端镜像（`langgraph dev` + 自定义 PG checkpointer，无需 license） |
| `model_config.example.json` | 模型配置示例（复制成 `model_config.json` 填 key） |

## 部署

| 文件 | 说明 |
|---|---|
| `docker-compose.yml` | PG(`pgvector/pgvector:pg16`) + Redis + api + frontend(nginx)，四个卷：`pgdata`/`appdata`/`cfgdata`/`datadata` |

## 前端（React + TS）

| 文件 | 说明 |
|---|---|
| `frontend-chat.tsx` | `ChatProvider` + `useChat` + `useThreads` + `useAssistants`（对应源码 `src/lib/chat.tsx`） |
| `frontend-api.ts` | `/demo/*` 封装（模型/工具/技能/配置）（对应 `src/lib/api.ts`） |
| `frontend-theme.tsx` | 亮暗两态主题（首次跟随系统，写 `<html data-theme>`）（对应 `src/lib/theme.tsx`） |
| `frontend-tools.tsx` | 工具注册页：两个 tab（工具 / 技能）+ 两层 expander + 卡片/详情弹窗 + 技能上传（对应 `src/pages/Tools.tsx`） |
| `frontend-notdeveloped.tsx` | 未开发占位组件（对应 `src/components/NotDeveloped.tsx`） |

> 未放进模板的（按讲解自行实现即可）：`ChatInterface.tsx`、`ChatMessage.tsx`、`ToolCallBox.tsx`、
> `TasksFilesPanel.tsx`、`ThinkingPanel.tsx`、`AppHeader.tsx`、`Settings.tsx`、`theme.css`
> —— 这些的结构与要点见 `../frontend.md`；形态与效果见 `../../../init_demo/`。