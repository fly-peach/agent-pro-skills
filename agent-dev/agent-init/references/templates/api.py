"""Demo 自定义 API 路由（/demo/*），挂在 langgraph dev 服务上。

支持：模型配置读写（模型配置页）、工具注册表（工具注册页）、agent 配置（编排页）。
注意：图拓扑直接用平台自带的 GET /assistants/{id}/graph，本文件不再重复实现。
配置写回后即时生效：agent 内部的 RuntimeConfigMiddleware 每次模型调用都会重新读取配置文件。
"""

import json
from typing import Any

from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

from agent import (
    AGENT_CONFIG_PATH,
    MODEL_CONFIG_PATH,
    all_tools,
    delete_skill,
    list_skills,
    load_agent_config,
    load_model_config,
    save_skill_from_text,
    save_skill_from_zip,
    tool_meta,
)

app = FastAPI(title="agent-console admin api")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


def _mask(key: str) -> str:
    return ("*" * max(len(key) - 4, 0)) + key[-4:] if key else ""


# ── 模型配置 ──────────────────────────────────────────────────────


class ModelConfigIn(BaseModel):
    provider: str | None = None
    base_url: str | None = None
    api_key: str | None = None
    model: str | None = None
    thinking_model: str | None = None
    temperature: float | None = None
    extra_body: dict[str, Any] | None = None


# ── 模型配置 ──────────────────────────────────────────────────────


@app.get("/demo/model-config")
def get_model_config():
    cfg = load_model_config()
    return {**cfg, "api_key": _mask(cfg.get("api_key", "")), "has_key": bool(cfg.get("api_key"))}


@app.put("/demo/model-config")
def put_model_config(body: ModelConfigIn):
    cfg = load_model_config()
    updates = body.model_dump(exclude_none=True)
    # api_key 传掩码或空串 = 不修改
    if "api_key" in updates and (not updates["api_key"] or "*" in updates["api_key"]):
        updates.pop("api_key")
    cfg.update(updates)
    MODEL_CONFIG_PATH.write_text(json.dumps(cfg, ensure_ascii=False, indent=2), encoding="utf-8")
    return {"ok": True, "note": "配置已写入，下一次运行即刻生效"}


@app.post("/demo/model-config/test")
def test_model_config():
    """用当前配置发一条最小请求，验证连通性（供模型配置页「测试连接」按钮）。"""
    from agent import _has_api_key, build_model

    cfg = load_model_config()
    if not _has_api_key(cfg):
        return {"ok": False, "error": "尚未配置 API Key，请先填入并保存"}
    try:
        msg = build_model(cfg).invoke("回复ok两个字")
        text = msg.content if isinstance(msg.content, str) else str(msg.content)
        return {"ok": True, "reply": text[:50]}
    except Exception as e:  # noqa: BLE001
        return {"ok": False, "error": str(e)[:300]}


# ── 工具注册表 ────────────────────────────────────────────────────


@app.get("/demo/tools")
def list_tools():
    """模型实际可见的全部工具（内置 + 自建），含分组、来源与可用性。"""
    disabled = set(load_agent_config().get("disabled_tools") or [])
    tools = all_tools()
    items = []
    for name, t in tools.items():
        meta = tool_meta(name)
        description = (getattr(t, "description", "") or "").strip()
        args_schema = getattr(t, "args_schema", None)
        items.append(
            {
                "name": name,
                "description": description,
                "summary": description.splitlines()[0] if description else "",
                "args": args_schema.model_json_schema() if args_schema else {},
                **meta,
                "enabled": meta["available"] and name not in disabled,
            }
        )
    order = {g: i for i, g in enumerate(["filesystem", "execution", "delegation", "planning", "custom"])}
    items.sort(key=lambda x: (order.get(x["group"], 99), x["name"]))
    return items


# ── 技能库（Skills）──────────────────────────────────────────────
# 技能 = 一个含 SKILL.md 的目录，放到 SKILLS_DIR；deepagents 的 skills 中间件扫描
# /skills/ 后把「技能名 + 描述 + 路径」注入系统提示词，模型需要时用 read_file 渐进式加载。


class SkillTextIn(BaseModel):
    name: str | None = None
    content: str


@app.get("/demo/skills")
def get_skills():
    return list_skills()


@app.post("/demo/skills/upload")
def upload_skill_zip(file: UploadFile = File(...)):
    """上传技能 zip：同步端点（FastAPI 丢线程池）；解压/复制是阻塞 IO，
    async 端点会触发 langgraph dev 的阻塞调用守卫（Blocking call to os.getcwd）。"""
    data = file.file.read()
    try:
        saved = save_skill_from_zip(data)
    except Exception as e:  # noqa: BLE001
        return {"ok": False, "error": str(e)[:300]}
    return {"ok": True, "saved": saved, "skills": list_skills()}


@app.post("/demo/skills/text")
def create_skill_from_text(body: SkillTextIn):
    """直接用 SKILL.md 文本创建/覆盖技能。"""
    try:
        sid = save_skill_from_text(body.name or "", body.content)
    except Exception as e:  # noqa: BLE001
        return {"ok": False, "error": str(e)[:300]}
    return {"ok": True, "saved": [sid], "skills": list_skills()}


@app.delete("/demo/skills/{skill_id}")
def remove_skill(skill_id: str):
    if not delete_skill(skill_id):
        raise HTTPException(status_code=404, detail=f"技能不存在: {skill_id}")
    return {"ok": True, "skills": list_skills()}


# ── agent 配置 + 图拓扑 ───────────────────────────────────────────


class AgentConfigIn(BaseModel):
    disabled_tools: list[str] | None = None
    recursion_limit: int | None = None
    system_prompt: str | None = None       # 自定义指令（空串 = 清空，只用内置）


@app.get("/demo/agent-config")
def get_agent_config():
    from agent import SYSTEM_PROMPT

    return {**load_agent_config(), "builtin_system_prompt": SYSTEM_PROMPT}


@app.put("/demo/agent-config")
def put_agent_config(body: AgentConfigIn):
    cfg = load_agent_config()
    updates = body.model_dump(exclude_none=True)
    if "disabled_tools" in updates:
        known = set(all_tools())
        unknown = [n for n in updates["disabled_tools"] if n not in known]
        if unknown:
            return {"ok": False, "error": f"未知工具: {unknown}"}
    cfg.update(updates)
    AGENT_CONFIG_PATH.write_text(json.dumps(cfg, ensure_ascii=False, indent=2), encoding="utf-8")
    return {"ok": True, "note": "配置已写入，下一次运行即刻生效"}


