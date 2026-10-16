# 参考索引（references/）

`agent-init` 的详细资料，按主题拆分；`SKILL.md` 只留决策与流程，代码/配置细节看这里。

| 文件 | 内容 | 什么时候看 |
|---|---|---|
| `templates/` | **可复制代码**（后端 7 个 + 部署 1 个 + 前端 5 个） | 起新项目时直接抄 |
| `../init_demo/` | **交付形态**：7 张运行截图 + 交付说明（代码不分发） | 想知道初始化出来长什么样 |
| `backend-agent.md` | `agent.py` 逐块讲解：运行时配置中间件、工具注册表、**组合后端**、技能库、未配置 Key 守卫 | 改后端行为 |
| `backend-api.md` | `/demo/*` 路由表与实现要点（含技能 zip 上传、掩码规则、阻塞调用守卫） | 加管理接口 |
| `langgraph-json.md` | 部署描述文件字段说明 + 双图 + `http.app` + `checkpointer` | 注册图/接坑 |
| `docker-deploy.md` | compose/Dockerfile/checkpointer/启停脚本 + 持久化验证清单 + Windows·WSL 坑 | 部署与排障 |
| `frontend.md` | useStream 接线、组件分层、tab/expander 约定、主题、思考流、Tasks/Files | 写前端 |
| `pitfalls.md` | **全部坑汇总**（环境/版本、WSL、Docker、后端、前端、平台 API） | 出问题时先搜这里 |

配套 skill：

- `agent-dev/env-preflight` —— 开工前环境准备（装 docker/python/uv/bun + 体检 + 版本一致性），**先跑它**
- 本 skill（`agent-init`）—— 项目骨架、代码约定、部署形态