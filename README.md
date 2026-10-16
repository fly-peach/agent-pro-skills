# agent-pro-skills

团队可复用的 **Agent 开发 skills**：从环境准备（env-preflight）到 Agent Console 初始化（agent-init）。

## 包含什么

| Skill | 作用 | 什么时候用 |
|---|---|---|
| [`env-preflight`](agent-dev/env-preflight/SKILL.md) | 环境准备 + 体检：装 docker / python+uv / node / bun / git，再逐项检查可用性。Windows+WSL 与原生 Linux 双形态 | 新机器开工、环境报错排查 |
| [`agent-init`](agent-dev/agent-init/SKILL.md) | 初始化 **Agent Console** 完整形态：对话（思考开关 / 检查点时间旅行）、配置（Agent + 模型双 tab）、工具注册（工具 + 技能双 tab）、Docker 部署（Postgres 持久化） | 要起一个 agent 开发/调试控制台 |

**可运行参考实现（demo）不随本仓库分发。** 想知道初始化出来长什么样：
截图与交付说明见 [`init_demo/`](init_demo/README.md)（7 张运行截图），
可直接复制的代码见 [`agent-init/references/templates/`](agent-dev/agent-init/references/templates/README.md)（14 个文件）。

## 快速开始

```bash
# 1) 环境准备（Windows 用同目录 .ps1）
bash agent-dev/env-preflight/scripts/install-deps.sh --yes   # 装依赖
bash agent-dev/env-preflight/scripts/preflight.sh            # 环境体检

# 2) 初始化项目
#    把 agent-dev/agent-init/ 交给你的 agent，或照 references/ 与 templates/ 手动搭
#    产出：后端（LangGraph + deepagents）+ 前端（React）+ Docker Compose
```

## 形态速览

| 页面 | 内容 |
|---|---|
| 对话 | 会话列表（搜索 / 复制 / 删除 / 清理空壳 / 折叠）· 消息流（工具卡 / 子智能体 / 思考流 / Tasks-Files 面板）· 思考开关（切思考模型并渲染 reasoning）· 历史（检查点时间旅行）· 右侧运行详情栏（未开发占位） |
| 配置 | tab1 Agent 配置（system prompt + 递归上限）· tab2 模型配置（服务商 / Base URL / key 掩码回显 / 标准与思考模型 / temperature / extra_body / 测试连接） |
| 工具注册 | tab1 工具（两层 expander：已集成 / 自开发 → 文件系统 / 执行 / 委派 / 规划，可逐个启停）· tab2 技能（SKILL.md 技能库，zip 上传 / 粘贴创建 / 删除） |
| 未开发界面 | 占位页 |

后端关键三点：**运行时配置中间件**（模型 / 工具启停 / system prompt 改配置即生效，不用重启、不用重建图）、
**组合后端**（内置 `execute` 可用 + 技能库落真实目录 + 线程状态通道）、**双图**（标准模型 / 思考模型，线程状态跨图共享）。

## 仓库结构

```
agent-dev/
├── env-preflight/          SKILL.md + scripts/（preflight / install-deps，各含 sh + ps1）
└── agent-init/
    ├── SKILL.md            形态 + 决策 + 流程 + 索引
    └── references/         7 篇详解（backend-agent / backend-api / frontend / docker-deploy / langgraph-json / pitfalls / README）
        └── templates/      14 个可复制文件（后端 7 + 部署 1 + 前端 5 + 说明）
init_demo/                  交付记录：README + 7 张运行截图
```

## 说明

- 密钥一律走环境变量 / `.env`（已 gitignore），仓库内不含任何 key
- 参考实现（demo）只在本地保留，仓库只放 skill 本身 + 可复制模板