# 后端 `agent.py` 逐块讲解

完整可运行版本：`templates/agent.py`。下面按块说明**为什么这么写**。

## 1. 配置读取（可挂卷）

```python
BACKEND_DIR = Path(__file__).resolve().parent
CONFIG_DIR = Path(os.environ.get("AGENT_CONSOLE_CONFIG_DIR") or BACKEND_DIR)  # 容器里指到挂载卷
MODEL_CONFIG_PATH = CONFIG_DIR / "model_config.json"
AGENT_CONFIG_PATH = CONFIG_DIR / "agent_config.json"
DATA_DIR = Path(os.environ.get("AGENT_CONSOLE_DATA_DIR") or BACKEND_DIR)      # 技能库/沙箱
SKILLS_DIR, SANDBOX_DIR = DATA_DIR / "skills", DATA_DIR / "sandbox"
```

- 配置写在容器 FS 里会随容器重建消失 → 用环境变量把目录指到卷（`AGENT_CONSOLE_CONFIG_DIR=/app/config`、`AGENT_CONSOLE_DATA_DIR=/app/data`）
- `load_model_config()` 在文件里没 key 时回退 `DEEPSEEK_API_KEY` 环境变量（Docker 部署靠它注入密钥）
- `load_agent_config()` 兼容旧版 `enabled_tools`（白名单）→ 迁移成 `disabled_tools`（黑名单）

## 2. 工具注册表

```python
@tool
def get_weather(city: str) -> str:
    """查询指定城市当前的天气情况。"""      # docstring = 给模型看的
TOOL_REGISTRY = {t.name: t for t in (get_weather, calc)}
```

- 注册表是**工具注册页 + 启停名单**的唯一事实源
- 内置工具（`ls/read_file/write_file/edit_file/delete/glob/grep/execute/task/write_todos`）由 deepagents 自带，**不要**在这里重复声明
- 工具页展示的清单来自**编译图内省**：`agent.nodes["tools"].bound.tools_by_name`（唯一事实源，避免手维护漂移）

## 3. 运行时配置中间件（本项目最核心的 20 行）

```python
class RuntimeConfigMiddleware(AgentMiddleware):
    def __init__(self, model_key: str = "model") -> None:
        self.model_key = model_key

    def _apply(self, request: ModelRequest) -> ModelRequest:
        cfg = load_agent_config()
        blocked = set(cfg.get("disabled_tools") or [])
        blocked |= {n for n in SANDBOX_ONLY_TOOLS if not supports_execution(BACKEND)}
        overrides = {
            "model": build_model(load_model_config(), key=self.model_key),
            "tools": [t for t in request.tools if getattr(t, "name", "") not in blocked],
        }
        custom = (cfg.get("system_prompt") or "").strip()
        if custom:                                   # 自定义指令：追加，不替换
            base = request.system_message
            base_text = base.content if (base and isinstance(base.content, str)) else ""
            nl = chr(10)
            merged = (base_text + nl + nl + "## 项目自定义指令" + nl + custom).strip() if base_text else custom
            overrides["system_message"] = SystemMessage(content=merged)
        return request.override(**overrides)          # 直接赋值 system_message 已废弃

    def wrap_model_call(self, request, handler):
        return handler(self._apply(request))

    async def awrap_model_call(self, request, handler):
        return await handler(self._apply(request))     # 必须 await（同步 handler 会返回 coroutine）

    @hook_config(can_jump_to=["end"])
    def before_agent(self, state, runtime):
        """未配置 API Key 时直接回话，不进模型（否则只报 401）。"""
        if not _has_api_key(load_model_config()):
            return {"jump_to": "end", "messages": [AIMessage(content=NOT_CONFIGURED_MESSAGE)]}
        return None

    @hook_config(can_jump_to=["end"])
    async def abefore_agent(self, state, runtime):
        return self.before_agent(state, runtime)
```

要点：
- **模型/工具/system prompt 全部运行时生效**：改配置=写文件，下一次模型调用即生效，**不需要重启、不要重建图**
- `config.configurable` 中间件读不到（`request.runtime` 没有 `config`）；HTTP 的 `context` 能读到但 JS SDK 不支持传 → 需要"按请求传配置"时用 **graph state**（见下）
- `before_agent` 里发现 `state` 的用法：`@hook_config(can_jump_to=["end"])` + `{"jump_to": "end", "messages": [...]}` = 短路一句话回复

> 如果想要"每个会话记住自己的配置"（多套配置/多环境）：把配置 id 放进 **graph state** ——
> 中间件声明 `state_schema`（`workspace: NotRequired[str]`），前端 `submit({messages, workspace})`，
> 中间件 `request.state.get("workspace")` 决定读哪份配置。**注意**：这条路是"配置分片"，本项目按需求取舍后没启用。

## 4. 组合后端（决定 `execute` 是否可用 + 文件落哪）

```python
BACKEND = CompositeBackend(
    # 默认后端决定 execute 是否可用（execution is not path-routable，只看 default）
    default=LocalShellBackend(root_dir=SANDBOX_DIR, virtual_mode=True),
    routes={
        "/skills/": FilesystemBackend(root_dir=SKILLS_DIR, virtual_mode=True),  # 技能库：真实目录
        "/notes/": StateBackend(),                                             # 线程内文件（Tasks/Files 面板）
    },
)
```

| 后端 | 作用 | 取舍 |
|---|---|---|
| `StateBackend()` | 文件存 **agent state**（随 checkpoint 持久化，前端 `.files` 可见） | 默认用它 → `execute` 不可用 |
| `FilesystemBackend(root_dir=…)` | 落真实磁盘 | 跨会话共享、可被外部读写 |
| `LocalShellBackend(root_dir=…)` | 同上 + **实现 `SandboxBackendProtocol`** → `execute` 可用 | 命令在**进程所在环境**执行（容器内 / 本机），生产要换 E2B/Daytona |
| `CompositeBackend(default, routes)` | 按路径前缀路由 | **execute 只走 default**；文件容量看路由 |

两个关键机制（都踩过）：
- `supports_execution(backend)`：对 Composite **只检查 `default`**；其他后端看 `isinstance(..., SandboxBackendProtocol)`
- `_uses_state_backend(backend)`：对 Composite **递归检查 default 与所有 route** —— 只要任意一处是 `StateBackend`，图里就有 `files` 通道（Tasks/Files 面板才有东西）

## 5. 技能库

```python
agent = create_deep_agent(
    model=build_model(key=model_key),   # 占位实例，真正模型由中间件注入
    tools=list(TOOL_REGISTRY.values()),
    system_prompt=SYSTEM_PROMPT,
    backend=BACKEND,
    skills=["/skills/"],                # SKILL.md 目录 → 中间件注入技能清单
    middleware=[RuntimeConfigMiddleware(model_key), TodoListMiddleware()],
)
```

- `TodoListMiddleware()` **必须显式挂**：deepagents 0.7 默认不带规划（`write_todos` 与 state 里的 `todos`）
- 技能库读写函数：`list_skills()` / `save_skill_from_zip()`（单/多技能包 + zip-slip 校验）/ `save_skill_from_text()` / `delete_skill()`

## 6. 双图注册

```python
agent = _build("model")                     # 标准模型
agent_thinking = _build("thinking_model")   # 思考模型（deepseek-reasoner 等）
```

- 思考模式用**独立图**（而非同图换模型）：稳定，且前端只需切 `assistantId`
- 线程状态**跨图共享**：同一条 thread 换图续跑，历史照常保留 → 会话列表**不要按图过滤**