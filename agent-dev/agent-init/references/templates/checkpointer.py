"""自定义 checkpointer（对接 langgraph.json 的 checkpointer.backend=custom）。

服务端要求这里导出的是一个**异步上下文管理器**，yield 一个 BaseCheckpointSaver，
连接的生命周期由服务端托管（官方文档：custom-checkpointer）。

- 有 POSTGRES_URI / POSTGRES_URI_CUSTOM / DATABASE_URL → 存到 PostgreSQL（Docker 部署走这条）
- 都没有 → 退回本地 SQLite 文件，方便无数据库时验证链路
"""

import contextlib
import os
from pathlib import Path

SQLITE_PATH = Path(__file__).resolve().parent / ".checkpoints.sqlite"


def _postgres_uri() -> str | None:
    return (
        os.environ.get("POSTGRES_URI")
        or os.environ.get("POSTGRES_URI_CUSTOM")
        or os.environ.get("DATABASE_URL")
        or None
    )


@contextlib.asynccontextmanager
async def make_checkpointer():
    uri = _postgres_uri()
    if uri:
        from langgraph.checkpoint.postgres.aio import AsyncPostgresSaver

        async with AsyncPostgresSaver.from_conn_string(uri) as saver:
            await saver.setup()  # 建表 + 索引（幂等）
            yield saver
    else:
        from langgraph.checkpoint.sqlite.aio import AsyncSqliteSaver

        async with AsyncSqliteSaver.from_conn_string(str(SQLITE_PATH)) as saver:
            await saver.setup()
            yield saver
