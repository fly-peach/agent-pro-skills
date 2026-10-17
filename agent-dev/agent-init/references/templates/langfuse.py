"""Langfuse trace 接入（可选）：env 开关，未配置 = 零侵入。

接入两行（在 build_model() 里）：
    from langfuse_setup import langfuse_model_kwargs
    model = ChatOpenAI(..., **langfuse_model_kwargs())

环境变量（.env）：
    LANGFUSE_PUBLIC_KEY=pk-lf-...
    LANGFUSE_SECRET_KEY=sk-lf-...
    LANGFUSE_HOST=http://localhost:3000        # 容器内用 http://host.docker.internal:3000
    LANGFUSE_ENABLED=0                          # 强制关闭（排障用）

效果：每次模型调用一条 trace（输入 / 输出 / token / 耗时 / 工具调用决策），
UI 在 http://localhost:3000/traces。粒度与限制见 ../langfuse.md。
"""
import os


def langfuse_enabled() -> bool:
    """未配 key 或显式 LANGFUSE_ENABLED=0 时返回 False。"""
    if os.getenv("LANGFUSE_ENABLED", "").strip().lower() in {"0", "false", "no"}:
        return False
    return bool(os.getenv("LANGFUSE_PUBLIC_KEY") and os.getenv("LANGFUSE_SECRET_KEY"))


def build_handler():
    """返回 Langfuse CallbackHandler（SDK >= 5：from langfuse.langchain import CallbackHandler）。

    每次构建模型时新建一个 handler；SDK 未安装或未配置时返回 None（调用方零判断）。
    """
    if not langfuse_enabled():
        return None
    try:
        from langfuse.langchain import CallbackHandler
    except ImportError:
        return None
    return CallbackHandler()


def langfuse_model_kwargs() -> dict:
    """给 ChatOpenAI(...) 的 kwargs：配置了就 {"callbacks": [handler]}，否则 {}。"""
    handler = build_handler()
    return {"callbacks": [handler]} if handler else {}
