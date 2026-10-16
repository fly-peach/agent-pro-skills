"""Demo DeepAgent —— agent-init skill 参考实现。

工具集按官方 harness 设计：内置 9 个（文件系统 / 执行 / 委派）+ 规划 1 个（TodoListMiddleware）
+ 自定义工具（TOOL_REGISTRY）。模型实际可见的工具以编译图为唯一事实源（all_tools()）。

配置全部运行时动态生效（无需重启服务）：
- model_config.json  模型配置（模型配置页写入）：每次模型调用前由中间件读取
- agent_config.json  工具启停（disabled_tools 黑名单）+ recursion_limit（工具注册页/编排页写入）
- 注册两个图：agent（标准模型） / agent-thinking（思考模型，如 deepseek-reasoner）
"""

import json
import os
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from deepagents import create_deep_agent
from deepagents.backends import CompositeBackend, FilesystemBackend, LocalShellBackend, StateBackend
from deepagents.middleware.filesystem import supports_execution
from langchain.agents.middleware import AgentMiddleware, ModelRequest, TodoListMiddleware, hook_config
from langchain_core.messages import AIMessage, SystemMessage
from langchain_core.tools import tool
from langchain_deepseek import ChatDeepSeek

BACKEND_DIR = Path(__file__).resolve().parent
# 配置目录可指向挂载卷（容器重建后配置不丢）；默认就在项目目录
CONFIG_DIR = Path(os.environ.get("AGENT_CONSOLE_CONFIG_DIR") or BACKEND_DIR)
MODEL_CONFIG_PATH = CONFIG_DIR / "model_config.json"
AGENT_CONFIG_PATH = CONFIG_DIR / "agent_config.json"

# 运行期数据目录（技能库 + 沙箱工作目录），容器里指向挂载卷
DATA_DIR = Path(os.environ.get("AGENT_CONSOLE_DATA_DIR") or BACKEND_DIR)
SKILLS_DIR = DATA_DIR / "skills"
SANDBOX_DIR = DATA_DIR / "sandbox"

DEFAULT_MODEL_CONFIG: dict[str, Any] = {
    "provider": "deepseek",
    "base_url": "https://api.deepseek.com/v1",
    "api_key": "",  # 模型配置页填写，或设 DEEPSEEK_API_KEY 环境变量
    "model": "deepseek-chat",
    "thinking_model": "deepseek-reasoner",
    "temperature": 0,
    "extra_body": {},
}

DEFAULT_AGENT_CONFIG: dict[str, Any] = {
    "disabled_tools": [],  # 黑名单：停用的工具名（默认全开，新内置工具自动生效）
    "recursion_limit": 50,
    "system_prompt": "",   # 自定义指令：追加在内置 harness 指令之后（空 = 只用内置）
}

# ── 官方内置工具的分组（对齐 docs: Tools → Built-in harness tools） ──────────
BUILTIN_TOOL_GROUPS: dict[str, tuple[str, str]] = {
    "ls": ("filesystem", "文件系统"),
    "read_file": ("filesystem", "文件系统"),
    "write_file": ("filesystem", "文件系统"),
    "edit_file": ("filesystem", "文件系统"),
    "delete": ("filesystem", "文件系统"),
    "glob": ("filesystem", "文件系统"),
    "grep": ("filesystem", "文件系统"),
    "execute": ("execution", "执行"),
    "task": ("delegation", "委派"),
    "write_todos": ("planning", "规划"),
}

# 需要沙箱后端（SandboxBackendProtocol）才能工作的内置工具
SANDBOX_ONLY_TOOLS = {"execute"}

GROUP_ORDER = ["filesystem", "execution", "delegation", "planning", "custom"]


def load_json(path: Path, default: dict) -> dict:
    if path.exists():
        try:
            return {**default, **json.loads(path.read_text(encoding="utf-8"))}
        except Exception:
            pass
    return dict(default)


def load_model_config() -> dict:
    """读全局模型配置；文件里没有 key 时回退环境变量（Docker 部署靠 DEEPSEEK_API_KEY 注入）。"""
    cfg = load_json(MODEL_CONFIG_PATH, DEFAULT_MODEL_CONFIG)
    if not cfg.get("api_key"):
        cfg["api_key"] = os.environ.get("DEEPSEEK_API_KEY", "")
    return cfg


def load_agent_config() -> dict:
    cfg = load_json(AGENT_CONFIG_PATH, DEFAULT_AGENT_CONFIG)
    # 兼容旧版 enabled_tools（白名单）→ 迁移成 disabled_tools（黑名单）
    legacy = cfg.pop("enabled_tools", None)
    if isinstance(legacy, list):
        known = set(all_tools())
        cfg["disabled_tools"] = sorted(known - set(legacy))
    cfg.setdefault("disabled_tools", [])
    return cfg


def build_model(cfg: dict | None = None, key: str = "model") -> ChatDeepSeek:
    """按 model_config.json 构建模型。ChatDeepSeek 是 OpenAI 兼容子类，
    因此同一入口支持 DeepSeek 官方 API 与任意自定义 OpenAI 兼容端点。"""
    cfg = cfg or load_model_config()
    api_key = cfg.get("api_key") or os.environ.get("DEEPSEEK_API_KEY", "")
    return ChatDeepSeek(
        model=cfg.get(key) or cfg["model"],
        api_key=api_key or "NOT-CONFIGURED",  # 未配置时也能启动，调用时返回 401 提示用户配置
        base_url=cfg.get("base_url", "https://api.deepseek.com/v1"),
        temperature=cfg.get("temperature", 0),
        extra_body=cfg.get("extra_body") or None,
    )


# ── 工具注册表（自定义工具）：工具页展示、启停的事实源之一 ─────────────────


@tool
def get_weather(city: str) -> str:
    """查询指定城市当前的天气情况。

    Args:
        city: 城市名称，例如 "杭州"。
    """
    fake_db = {"杭州": "晴，26°C，东风2级", "北京": "多云，19°C，南风3级"}
    return fake_db.get(city, f"{city}：暂无天气数据")


@tool
def calc(expression: str) -> str:
    """计算一个四则运算表达式的值。

    Args:
        expression: 合法的四则运算表达式，例如 "(3+5)*12/2"。
    """
    allowed = set("0123456789+-*/(). ")
    if not expression or not set(expression) <= allowed:
        return "非法表达式：只支持数字与 + - * / ( )"
    return str(eval(expression))  # noqa: S307 -- 输入已白名单过滤


TOOL_REGISTRY: dict[str, Any] = {t.name: t for t in (get_weather, calc)}

SYSTEM_PROMPT = (
    "你是演示助手。遇到需要事实数据或计算的问题，先规划步骤再调用工具；"
    "回答用中文，结论后注明来自哪个工具。"
    "需要留存的产物写到 /notes/ 下（会随会话持久化，可在界面「Tasks/Files」面板查看）；"
    "临时中间文件放 /tmp/；需要跑命令时用 execute。"
)

NOT_CONFIGURED_MESSAGE = (
    "⚠️ **尚未配置模型 API Key**\n\n"
    "我还没法调用模型。请打开左侧「模型配置」页面填入 API Key"
    "（DeepSeek 官方 `sk-...`，或其他 OpenAI 兼容端点的 Key），保存后直接再发一次消息即可。"
)

# 后端组合：
# - default = LocalShellBackend：实现 SandboxBackendProtocol → 内置 execute（shell 执行）可用；
#   文件工具落在 DATA_DIR/sandbox（真实目录、跨会话共享），而不是线程内的虚拟文件。
#   注意：commands 在**Agent Console 进程所在环境**执行（Docker 部署 = 容器内；本地 dev = 宿主机），
#   生产环境应换成真正的隔离沙箱（E2B / Daytona / 云沙箱）。
# - routes["/skills/"] = FilesystemBackend：技能库独立放真实目录，便于 CLI/上传接口读写。
for _d in (SKILLS_DIR, SANDBOX_DIR):
    _d.mkdir(parents=True, exist_ok=True)

BACKEND = CompositeBackend(
    # 默认后端决定 execute 是否可用：LocalShellBackend 实现 SandboxBackendProtocol
    default=LocalShellBackend(root_dir=SANDBOX_DIR, virtual_mode=True),
    routes={
        # 技能库：真实目录，便于上传接口/CLI 读写，跨会话共享
        "/skills/": FilesystemBackend(root_dir=SKILLS_DIR, virtual_mode=True),
        # 笔记/产物：走线程状态（随会话持久化，前端 Tasks/Files 面板可见）
        "/notes/": StateBackend(),
    },
)

# 交给 deepagents 的技能来源路径（相对虚拟文件系统；/skills/ 已路由到 SKILLS_DIR）
SKILLS_SOURCES = ["/skills/"]


def _has_api_key(cfg: dict) -> bool:
    return bool(cfg.get("api_key") or os.environ.get("DEEPSEEK_API_KEY", ""))


class RuntimeConfigMiddleware(AgentMiddleware):
    """每次模型调用前读取配置文件：动态换模型、按停用名单过滤工具。

    使模型配置页/工具注册页的改动在下一次运行即刻生效，不依赖服务重启。
    """

    def __init__(self, model_key: str = "model") -> None:
        self.model_key = model_key

    def _apply(self, request: ModelRequest) -> ModelRequest:
        cfg = load_agent_config()
        blocked = set(cfg.get("disabled_tools") or [])
        blocked |= {n for n in SANDBOX_ONLY_TOOLS if not supports_execution(BACKEND)}
        overrides: dict[str, Any] = {
            "model": build_model(load_model_config(), key=self.model_key),
            "tools": [t for t in request.tools if getattr(t, "name", "") not in blocked],
        }
        # 自定义指令：追加在内置 harness 指令之后（不替换，避免丢掉 deepagents 的规划/文件系统规范）
        custom = (cfg.get("system_prompt") or "").strip()
        if custom:
            base = request.system_message
            base_text = base.content if (base is not None and isinstance(base.content, str)) else ""
            nl = chr(10)  # 避免转义层破坏 \n，等价于换行
            merged = (
                (base_text + nl + nl + "## 项目自定义指令" + nl + custom).strip()
                if base_text
                else custom
            )
            overrides["system_message"] = SystemMessage(content=merged)
        return request.override(**overrides)

    def wrap_model_call(self, request: ModelRequest, handler):
        return handler(self._apply(request))

    async def awrap_model_call(self, request: ModelRequest, handler):
        return await handler(self._apply(request))

    @hook_config(can_jump_to=["end"])
    def before_agent(self, state, runtime):
        """未配置 API Key 时直接给一句人话提示，不进模型（否则只会报 401）。"""
        if not _has_api_key(load_model_config()):
            return {"jump_to": "end", "messages": [AIMessage(content=NOT_CONFIGURED_MESSAGE)]}
        return None

    @hook_config(can_jump_to=["end"])
    async def abefore_agent(self, state, runtime):
        return self.before_agent(state, runtime)


def _build(model_key: str) -> Any:
    return create_deep_agent(
        model=build_model(key=model_key),  # 占位实例；真正模型由中间件在调用时注入
        tools=list(TOOL_REGISTRY.values()),
        system_prompt=SYSTEM_PROMPT,
        backend=BACKEND,
        skills=SKILLS_SOURCES,          # 技能库：中间件扫描 SKILL.md，按需渐进式加载
        middleware=[
            RuntimeConfigMiddleware(model_key),
            # deepagents 0.7 默认中间件只剩 Filesystem + SubAgent，规划（write_todos）需显式挂载
            TodoListMiddleware(),
        ],
    )


# 图注册（langgraph.json）：键名 = 前端 assistantId
agent = _build("model")
agent_thinking = _build("thinking_model")


# ── 工具清单 / 元信息（工具注册页的数据源） ─────────────────────────────


def all_tools() -> dict[str, Any]:
    """模型实际可见的全部工具（内置 + 自建），以编译图为唯一事实源。"""
    try:
        return dict(agent.nodes["tools"].bound.tools_by_name)
    except Exception:  # pragma: no cover - 兜底：图结构变化时退回中间件声明
        merged: dict[str, Any] = dict(TOOL_REGISTRY)
        for mw in getattr(agent, "middleware", None) or []:
            for t in getattr(mw, "tools", None) or []:
                merged.setdefault(t.name, t)
        return merged


def tool_meta(name: str) -> dict[str, Any]:
    """单个工具的分组 / 来源 / 可用性。"""
    group, group_label = BUILTIN_TOOL_GROUPS.get(name, ("custom", "自建"))
    origin = "custom" if name in TOOL_REGISTRY else "builtin"
    available, reason = True, ""
    if name in SANDBOX_ONLY_TOOLS and not supports_execution(BACKEND):
        available = False
        reason = "需沙箱后端（SandboxBackendProtocol）；当前为内存后端，调用会直接报错。"
    return {
        "group": group,
        "group_label": group_label,
        "origin": origin,
        "available": available,
        "unavailable_reason": reason,
    }


# ── 技能库（Skills）：SKILL.md 目录，交给 deepagents skills 中间件渐进式加载 ──────


def _skill_frontmatter(path: Path) -> dict:
    """解析 SKILL.md 头部的 YAML frontmatter（name / description）。"""
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except Exception:
        return {}
    if not text.startswith("---"):
        return {}
    end = text.find("\n---", 3)
    if end == -1:
        return {}
    try:
        import yaml

        data = yaml.safe_load(text[3:end]) or {}
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def _skill_dirs() -> list[Path]:
    if not SKILLS_DIR.exists():
        return []
    return sorted(
        [d for d in SKILLS_DIR.iterdir() if d.is_dir() and (d / "SKILL.md").is_file()],
        key=lambda d: d.name,
    )


def list_skills() -> list[dict]:
    items = []
    for d in _skill_dirs():
        fm = _skill_frontmatter(d / "SKILL.md")
        files = sorted(str(p.relative_to(d)).replace("\\", "/") for p in d.rglob("*") if p.is_file())
        items.append(
            {
                "id": d.name,
                "name": fm.get("name") or d.name,
                "description": (fm.get("description") or "").strip(),
                "path": f"/skills/{d.name}/SKILL.md",
                "files": files,
                "file_count": len(files),
                "updated_at": datetime.fromtimestamp((d / "SKILL.md").stat().st_mtime, timezone.utc).isoformat(timespec="seconds"),
            }
        )
    return items


def _slug(text: str) -> str:
    keep = [c.lower() if (c.isascii() and c.isalnum()) else "-" for c in (text or "").strip()]
    slug = re.sub(r"-+", "-", "".join(keep)).strip("-")[:40]
    return slug or "skill"


def _safe_zip_members(zf: "zipfile.ZipFile", dest: Path) -> None:
    """解压前做 zip-slip 校验：拒绝绝对路径与 .. 越界。"""
    dest = dest.resolve()
    for info in zf.infolist():
        target = (dest / info.filename).resolve()
        if not str(target).startswith(str(dest)):
            raise ValueError(f"非法压缩包条目: {info.filename}")


def save_skill_from_zip(data: bytes) -> list[str]:
    """按 QwenPaw 的规则导入技能 zip：单技能（根目录有 SKILL.md）或多技能（各子目录含 SKILL.md）。"""
    import io
    import shutil
    import tempfile
    import zipfile

    if not zipfile.is_zipfile(io.BytesIO(data)):
        raise ValueError("上传的不是合法 zip 文件")
    tmp = Path(tempfile.mkdtemp(prefix="skill_upload_"))
    try:
        with zipfile.ZipFile(io.BytesIO(data)) as zf:
            _safe_zip_members(zf, tmp)
            zf.extractall(tmp)
        entries = [p for p in tmp.iterdir() if not p.name.startswith("__")]
        root = entries[0] if len(entries) == 1 and entries[0].is_dir() else tmp
        if (root / "SKILL.md").is_file():
            found = [(root, None)]
        else:
            found = [(d, None) for d in sorted(root.iterdir()) if d.is_dir() and (d / "SKILL.md").is_file()]
        if not found:
            raise ValueError("压缩包里没有找到技能（需要 SKILL.md）")

        saved = []
        for src, _ in found:
            fm = _skill_frontmatter(src / "SKILL.md")
            sid = _slug(str(fm.get("name") or src.name))
            dst = SKILLS_DIR / sid
            if dst.exists():
                shutil.rmtree(dst)
            shutil.copytree(src, dst)
            saved.append(sid)
        return saved
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def save_skill_from_text(name: str, content: str) -> str:
    """用一段 SKILL.md 文本创建/覆盖技能。"""
    if not content.strip():
        raise ValueError("SKILL.md 内容为空")
    fm = _skill_frontmatter_text(content)
    sid = _slug(str(fm.get("name") or name or "skill"))
    dst = SKILLS_DIR / sid
    dst.mkdir(parents=True, exist_ok=True)
    (dst / "SKILL.md").write_text(content, encoding="utf-8")
    return sid


def _skill_frontmatter_text(text: str) -> dict:
    if not text.startswith("---"):
        return {}
    end = text.find("\n---", 3)
    if end == -1:
        return {}
    try:
        import yaml

        data = yaml.safe_load(text[3:end]) or {}
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def delete_skill(skill_id: str) -> bool:
    import shutil

    safe = re.sub(r"[^A-Za-z0-9._-]", "", skill_id or "")
    dst = SKILLS_DIR / safe
    if not safe or not dst.is_dir():
        return False
    shutil.rmtree(dst)
    return True
