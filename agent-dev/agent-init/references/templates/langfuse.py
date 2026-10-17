"""Langfuse trace 接入（可选）：env 开关，未配置 = 零侵入。

接入（build_model() 里，一行改动）：
    from langfuse_setup import langfuse_model_cls
    return langfuse_model_cls(ChatDeepSeek)(
        model=..., api_key=..., base_url=..., temperature=..., extra_body=...,
    )

原理：返回模型类的 trace 子类 —— 重写 `bind_tools()`，把 Langfuse CallbackHandler 通过
`with_config(callbacks=...)` 挂到绑定后的 runnable 上（config 合并，不走 kwargs）。
每次模型调用一条 trace（输入 / 输出 / token / 耗时），UI 在 :3000/traces。

环境变量（.env）：
    LANGFUSE_PUBLIC_KEY=pk-lf-...
    LANGFUSE_SECRET_KEY=sk-lf-...
    LANGFUSE_HOST=http://localhost:3000        # 容器内用 http://host.docker.internal:3000
    LANGFUSE_ENABLED=0                          # 强制关闭（排障用）

为什么这么绕（langchain 1.4.5 实测，详见 ../langfuse.md）：
- 模型构造器 `callbacks=...` 与 `.bind(callbacks=...)` 都不生效（后者直接报
  "got multiple values for keyword argument 'callbacks'"）—— 只有 invoke 的 config 生效；
- LangGraph 平台服务没有给整图注入 invoke config 的口子（Runtime 不暴露 config）；
- 所以只能让"bind_tools 的产物"自带 config callbacks —— 正好框架每次调用模型前
  都会经过 bind_tools（middleware 里 override 的 model）。
- 另：langfuse.openai 客户端包装（root_client/async_client）同步路径可用，但
  openai>=3 的 async `with_raw_response.create` 会 AttributeError，别用。
"""
import os


def langfuse_enabled() -> bool:
    """未配 key 或显式 LANGFUSE_ENABLED=0 时返回 False。"""
    if os.getenv("LANGFUSE_ENABLED", "").strip().lower() in {"0", "false", "no"}:
        return False
    return bool(os.getenv("LANGFUSE_PUBLIC_KEY") and os.getenv("LANGFUSE_SECRET_KEY"))


def langfuse_model_cls(base_cls):
    """返回带 trace 的模型子类；未配置 key / SDK 缺失时原样返回 base_cls（零侵入）。

    每次构建模型时都会调用（RuntimeConfigMiddleware 每请求重建模型）→ 每请求一个
    handler，改 .env 即时生效，不用重启。
    """
    if not langfuse_enabled():
        return base_cls
    try:
        from langfuse.langchain import CallbackHandler
    except ImportError:
        return base_cls

    handler = CallbackHandler()
    trace_cfg = {"callbacks": [handler]}

    class _LangfuseTraced(base_cls):
        def bind_tools(self, tools, **kwargs):
            bound = super().bind_tools(tools, **kwargs)
            return bound.with_config(**trace_cfg)

    _LangfuseTraced.__name__ = f"Traced{base_cls.__name__}"
    return _LangfuseTraced
