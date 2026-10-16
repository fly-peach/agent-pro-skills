# 后端 `api.py`：管理接口

完整版：`templates/api.py`。挂在 `langgraph.json` 的 `http.app` 上，与图**同进程同端口**（:2024）。

## 原则：能用平台 API 就不自建

`langgraph dev` 自带 50+ 路由（`/docs` 可查）：会话、运行、检查点、图拓扑、store、metrics…
**自建范围只限于"平台不认识的概念"**——模型 key、工具启停、system prompt、技能库。

| 需求 | 用什么 |
|---|---|
| 会话列表/计数/复制/删除/清理 | `client.threads.search / count / copy / prune` |
| 检查点历史 / 时间旅行 | `client.threads.getHistory` + `submit(null,{forkFrom})` |
| 状态改写（如编辑文件） | `client.threads.updateState(id,{values})` |
| 图拓扑 / 子图 | `client.assistants.getGraph(id,{xray})` |
| 可用图列表 | `client.assistants.search()` |
| **模型配置 / Agent 配置 / 工具启停 / 技能库** | **自建 `/demo/*`** |

## 路由表

```
GET    /demo/model-config            模型配置（api_key 回显掩码 + has_key）
PUT    /demo/model-config            写 model_config.json，下一次运行生效
POST   /demo/model-config/test       用当前配置发一条最小请求验证连通性

GET    /demo/agent-config            disabled_tools + recursion_limit + system_prompt + builtin_system_prompt
PUT    /demo/agent-config            写 agent_config.json（system_prompt 空串 = 清空）

GET    /demo/tools                   模型实际可见的全部工具（name/summary/args/group/origin/available/enabled）

GET    /demo/skills                  技能列表（id/name/description/虚拟路径/文件数）
POST   /demo/skills/upload           上传技能 zip（单技能或多技能包）
POST   /demo/skills/text             粘贴 SKILL.md 文本创建
DELETE /demo/skills/{skill_id}       删除技能
```

## 实现要点

**① 掩码与"不改动"语义**：`GET` 返回掩码（`****abcd`）；`PUT` 收到空串或含 `*` 的值 = 不修改该字段

```python
if "api_key" in updates and (not updates["api_key"] or "*" in updates["api_key"]):
    updates.pop("api_key")
```

**② 必须自己加 CORS**（平台自带的 CORS 不覆盖自定义路由）：

```python
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])
```

**③ 文件上传端点要写成同步 `def`**（否则 langgraph dev 的阻塞调用守卫直接报错）：

```python
@app.post("/demo/skills/upload")
def upload_skill_zip(file: UploadFile = File(...)):     # 同步 def → FastAPI 丢线程池
    data = file.file.read()                             # 不要 await file.read()
```

**④ 工具清单从编译图内省**（不是手写清单）：

```python
def all_tools() -> dict[str, Any]:
    return dict(agent.nodes["tools"].bound.tools_by_name)
```

**⑤ 技能 zip 的安全解压**（zip-slip 防护）：

```python
def _safe_zip_members(zf: zipfile.ZipFile, dest: Path) -> None:
    dest = dest.resolve()
    for info in zf.infolist():
        if not str((dest / info.filename).resolve()).startswith(str(dest)):
            raise ValueError(f"非法压缩包条目: {info.filename}")
```

**⑥ 依赖**：`fastapi`（平台不自带）、`python-multipart`（`UploadFile` 必需）、`pyyaml`（解析 SKILL.md frontmatter，随 langchain 已装）