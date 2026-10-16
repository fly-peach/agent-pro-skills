y

## 快速开始

```bash
# 1) 环境准备（Windows+WSL 或 Linux 均可）
bash agent-dev/env-preflight/scripts/install-deps.sh --yes       # 装 docker / python3 / uv / git
bash agent-dev/env-preflight/scripts/preflight.sh /path/to/demo  # 环境体检

# 2) 起 demo（Docker 部署，会话/配置/技能都持久化）
cd demo
cp .env.example .env         # 填 DEEPSEEK_API_KEY
wsl -d Ubuntu -e bash -lc "cd /mnt/e/.../demo && docker compose up -d --build"
# 前端 http://localhost:5173   后端 http://localhost:2024/docs
```

本地开发（不用 Docker）：`cd demo/backend && PYTHONUTF8=1 .venv/Scripts/langgraph dev --port 2024`，前端 `cd demo/frontend && bun run dev`。

## 形态速览

| 页面 | 内容 |
|---|---|
| 对话 | 会话列表（搜索/复制/删除/清理/折叠）· 消息流（工具卡/子智能体/思考流/Tasks-Files）· 思考开关 · 检查点时间旅行 · 右侧运行详情栏（未开发占位） |
| 配置 | tab1 Agent 配置（system prompt + 递归上限）· tab2 模型配置（服务商/key/模型参数） |
| 工具注册 | tab1 工具（两层 expander：已集成/自开发 → 文件系统/执行/委派/规划）· tab2 技能（SKILL.md 库，zip 上传） |
| 未开发界面 | 占位页 |

后端关键：**运行时配置中间件**（模型/工具/system prompt 改配置即生效）、**组合后端**（execute 可用 + 技能库落真实目录 + /notes/ 走线程状态）、**双图**（标准/思考模型）。

## 说明

- 密钥一律走环境变量 / .env（已被 gitignore），仓库内不含任何 key
- demo/backend/skills/ 里的示例技能（refund-policy / summarize / weekly-report）用于演示技能库
