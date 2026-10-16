# init_demo —— 初始化交付形态

这是 `agent-init` 初始化出来的项目长什么样：**截图 + 交付说明**。代码不随仓库分发（`demo/` 不入库），实现用 `../references/templates/` 的 14 个模板起项目。

## 交付要点

- 项目：Agent Console —— 四个页面：对话 / 配置（Agent·模型 双 tab）/ 工具注册（工具·技能 双 tab）/ 未开发界面
- 后端：运行时配置中间件（模型·工具启停·system prompt 改配置即生效）+ 组合后端（`execute` 可用、技能库落真实目录、`/notes/` 走线程状态）+ 双图（标准/思考模型）
- 技能库：SKILL.md 目录，zip 上传 / 粘贴创建 / 删除，模型按需渐进式加载
- 部署：Docker + Postgres，四个持久化卷（会话 / 线程元数据 / 配置 / 技能与沙箱），重建容器不丢数据

## 截图

| 图 | 说明 |
|---|---|
| `shots/01-chat.png` | 对话页（暗色）：会话列表 + 消息流 + composer + 右侧运行详情栏 |
| `shots/02-config-agent.png` | 配置页 · Agent tab：system prompt + 递归上限 |
| `shots/03-config-models.png` | 配置页 · 模型 tab：服务商 / key / 模型参数 |
| `shots/04-tools.png` | 工具注册 · 工具 tab：两层 expander + 卡片与开关 |
| `shots/05-skills.png` | 工具注册 · 技能 tab：技能列表 + 上传 zip / 粘贴 SKILL.md |
| `shots/06-undeveloped.png` | 未开发界面（占位） |
| `shots/07-chat-light.png` | 对话页（亮色）：亮暗两套 token |

## 复现路径

1. `agent-dev/env-preflight`：install-deps（装依赖）+ preflight（体检）
2. 复制 `references/templates/` 的代码起后端 → `langgraph dev --port 2024`
3. 起前端（Vite + React + @langchain/react）→ Docker：`docker compose up -d --build`
