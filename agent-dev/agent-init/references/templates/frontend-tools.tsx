/** 工具注册页：两个 tab（工具 / 技能）。
 *
 * - 工具 tab：**两层 expander** —— 第一层「LangChain 已集成 / 自开发」，第二层按官方分组
 *   （文件系统 / 执行 / 委派 / 规划 / 自建）；卡片点开看参数与完整说明，可逐个启停。
 * - 技能 tab：技能库（SKILL.md 目录）列表 + 上传 zip（支持多技能包）+ 粘贴 SKILL.md 创建 + 删除。
 *   技能由 deepagents 的 skills 中间件注入系统提示词，模型按需 read_file 渐进式加载。
 */
import { useCallback, useEffect, useMemo, useState } from "react";
import { useSearchParams } from "react-router-dom";
import { AlertTriangle, ChevronRight, FileArchive, Plus, RefreshCcw, Trash2, X } from "lucide-react";
import { api, type SkillInfo, type ToolInfo } from "../lib/api";
import { ConfirmDialog } from "../components/ConfirmDialog";

const GROUP_ORDER = ["filesystem", "execution", "delegation", "planning", "custom"];
const GROUP_HINT: Record<string, string> = {
  filesystem: "虚拟文件系统读写与检索",
  execution: "本地沙箱 shell 执行（LocalShellBackend）",
  delegation: "派子智能体处理独立子任务",
  planning: "任务清单，Tasks 面板的数据源",
  custom: "本项目自建工具（agent.py → TOOL_REGISTRY）",
};

type TabKey = "tools" | "skills";

export default function Tools() {
  const [params, setParams] = useSearchParams();
  const raw = params.get("tab");
  const active: TabKey = raw === "skills" ? "skills" : "tools";

  const switchTab = (key: TabKey) => {
    const next = new URLSearchParams(params);
    next.set("tab", key);
    setParams(next, { replace: true });
  };

  return (
    <div className="page">
      <div className="page-inner">
        <h1>工具注册</h1>
        <div className="tabs" role="tablist">
          <button role="tab" aria-selected={active === "tools"} className={`tab ${active === "tools" ? "active" : ""}`} onClick={() => switchTab("tools")}>
            工具
          </button>
          <button role="tab" aria-selected={active === "skills"} className={`tab ${active === "skills" ? "active" : ""}`} onClick={() => switchTab("skills")}>
            技能
          </button>
        </div>
        {active === "tools" ? <ToolsTab /> : <SkillsTab />}
      </div>
    </div>
  );
}

/** 两级折叠块 */
function Expander({
  title,
  count,
  hint,
  level = 1,
  defaultOpen = false,
  children,
}: {
  title: string;
  count?: number;
  hint?: string;
  level?: 1 | 2;
  defaultOpen?: boolean;
  children: React.ReactNode;
}) {
  const [open, setOpen] = useState(defaultOpen);
  return (
    <div className={`expander level-${level} ${open ? "open" : ""}`}>
      <button className="expander-head" onClick={() => setOpen((v) => !v)} aria-expanded={open}>
        <ChevronRight size={15} className={`expander-chev ${open ? "open" : ""}`} />
        <span className="expander-title">{title}</span>
        {count !== undefined && <span className="badge">{count}</span>}
        {hint && <span className="expander-hint">{hint}</span>}
      </button>
      {open && <div className="expander-body">{children}</div>}
    </div>
  );
}

function ToolsTab() {
  const [tools, setTools] = useState<ToolInfo[] | null>(null);
  const [saving, setSaving] = useState<string | null>(null);
  const [detail, setDetail] = useState<string | null>(null);

  const load = useCallback(() => api.listTools().then(setTools), []);
  useEffect(() => void load(), [load]);

  const stats = useMemo(() => {
    const list = tools ?? [];
    return {
      builtin: list.filter((t) => t.origin === "builtin").length,
      custom: list.filter((t) => t.origin === "custom").length,
      off: list.filter((t) => t.available && !t.enabled).length,
      unavailable: list.filter((t) => !t.available).length,
    };
  }, [tools]);

  const setDisabled = async (next: string[]) => {
    const r = await api.putAgentConfig({ disabled_tools: next });
    if (r.ok) await load();
  };

  const toggle = async (t: ToolInfo) => {
    if (!tools) return;
    setSaving(t.name);
    const disabled = tools.filter((x) => x.available && !x.enabled).map((x) => x.name);
    await setDisabled(t.enabled ? [...disabled, t.name] : disabled.filter((n) => n !== t.name));
    setSaving(null);
  };

  if (!tools) return <div className="dim">加载中…</div>;
  const current = tools.find((t) => t.name === detail) ?? null;
  const renderCards = (items: ToolInfo[]) => (
    <div className="tool-grid">
      {items.map((t) => (
        <ToolCard key={t.name} tool={t} saving={saving === t.name} onOpen={() => setDetail(t.name)} onToggle={() => void toggle(t)} />
      ))}
    </div>
  );

  return (
    <>
      <div className="tool-summary">
        <span>共 <b>{tools.length}</b> 个</span>
        <span className="dim">已集成 {stats.builtin}</span>
        <span className="dim">自开发 {stats.custom}</span>
        {stats.off > 0 && <span className="badge warn">已停用 {stats.off}</span>}
        {stats.unavailable > 0 && <span className="badge">不可用 {stats.unavailable}</span>}
        <span className="tool-summary-actions">
          <button className="btn ghost sm" onClick={() => setDisabled([])}>
            <RefreshCcw size={13} /> 全部启用
          </button>
          <button className="btn ghost sm" onClick={() => setDisabled(tools.filter((t) => t.available).map((t) => t.name))}>
            全部停用
          </button>
        </span>
      </div>

      {(["builtin", "custom"] as const).map((origin) => {
        const items = tools.filter((t) => t.origin === origin);
        if (!items.length) return null;
        return (
          <Expander
            key={origin}
            title={origin === "builtin" ? "LangChain 已集成" : "自开发（未集成）"}
            count={items.length}
            hint={origin === "builtin" ? "deepagents / langchain 内置 harness 工具" : "agent.py 里自己写的工具"}
            defaultOpen={origin === "builtin"}
          >
            {origin === "builtin"
              ? GROUP_ORDER.filter((g) => g !== "custom").map((group) => {
                  const list = items.filter((t) => t.group === group);
                  if (!list.length) return null;
                  return (
                    <Expander key={group} level={2} title={list[0].group_label} count={list.length} hint={GROUP_HINT[group]} defaultOpen>
                      {renderCards(list)}
                    </Expander>
                  );
                })
              : renderCards(items)}
          </Expander>
        );
      })}

      {current && (
        <ToolDetailDialog
          tool={current}
          saving={saving === current.name}
          onClose={() => setDetail(null)}
          onToggle={() => void toggle(current)}
        />
      )}
    </>
  );
}

function ToolCard({
  tool,
  saving,
  onOpen,
  onToggle,
}: {
  tool: ToolInfo;
  saving: boolean;
  onOpen: () => void;
  onToggle: () => void;
}) {
  return (
    <div className={`tool-card ${tool.enabled ? "" : "off"}`} onClick={onOpen} role="button" tabIndex={0} onKeyDown={(e) => e.key === "Enter" && onOpen()}>
      <div className="tool-card-head">
        <code className="tool-card-name">{tool.name}</code>
        <button
          className={`switch ${tool.enabled ? "on" : ""}`}
          onClick={(e) => {
            e.stopPropagation();
            onToggle();
          }}
          disabled={!tool.available || saving}
          title={tool.available ? (tool.enabled ? "点击停用" : "点击启用") : "当前后端不支持"}
          aria-label={`${tool.enabled ? "停用" : "启用"} ${tool.name}`}
        >
          <span className="knob" />
        </button>
      </div>
      <div className="tool-card-badges">
        <span className={`badge ${tool.origin === "builtin" ? "info" : "brand"}`}>{tool.origin === "builtin" ? "内置" : "自建"}</span>
        {!tool.available && (
          <span className="badge warn">
            <AlertTriangle size={10} /> 不可用
          </span>
        )}
        {tool.available && !tool.enabled && <span className="badge warn">已停用</span>}
      </div>
      <p className="tool-card-summary">{tool.summary || "（无说明）"}</p>
      <div className="tool-card-foot">
        {tool.args?.properties && Object.keys(tool.args.properties).length > 0 ? (
          <span className="dim">参数：{Object.keys(tool.args.properties).join(", ")}</span>
        ) : (
          <span className="dim">无参数</span>
        )}
        <span className="tool-card-more">详情 →</span>
      </div>
    </div>
  );
}

function ToolDetailDialog({
  tool,
  saving,
  onClose,
  onToggle,
}: {
  tool: ToolInfo;
  saving: boolean;
  onClose: () => void;
  onToggle: () => void;
}) {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);
  const params = Object.entries(tool.args?.properties ?? {});

  return (
    <div className="dialog-backdrop" onClick={onClose}>
      <div className="dialog dialog-lg" onClick={(e) => e.stopPropagation()}>
        <div className="dialog-head">
          <div className="dialog-title-wrap">
            <h3>
              <code>{tool.name}</code>
            </h3>
            <div className="dialog-sub">
              <span className="badge">{tool.group_label}</span>
              <span className={`badge ${tool.origin === "builtin" ? "info" : "brand"}`}>{tool.origin === "builtin" ? "内置工具" : "自建工具"}</span>
              {!tool.available && (
                <span className="badge warn">
                  <AlertTriangle size={10} /> 不可用
                </span>
              )}
            </div>
          </div>
          <button className="btn ghost icon-btn sm" onClick={onClose} aria-label="关闭">
            <X size={15} />
          </button>
        </div>
        <div className="dialog-content scroll-pretty">
          {!tool.available && tool.unavailable_reason && <div className="tool-unavailable">{tool.unavailable_reason}</div>}
          <section className="detail-section">
            <h4 className="kv-label">参数定义</h4>
            {params.length === 0 ? (
              <p className="dim small">该工具不需要参数</p>
            ) : (
              <div className="param-list">
                {params.map(([key, v]: [string, any]) => (
                  <div key={key} className="param-item">
                    <div className="param-head">
                      <code className="mono">{key}</code>
                      <span className="param-type">{typeof v.type === "string" ? v.type : (v.anyOf ?? []).map((a: any) => a.type).join(" | ") || "any"}</span>
                      {(tool.args.required ?? []).includes(key) ? <span className="badge warn">必填</span> : <span className="badge">可选</span>}
                    </div>
                    {(v.description || v.title) && <div className="param-desc">{v.description ?? v.title}</div>}
                    {v.default !== undefined && <div className="param-default dim">默认值：{JSON.stringify(v.default)}</div>}
                  </div>
                ))}
              </div>
            )}
          </section>
          <section className="detail-section">
            <h4 className="kv-label">完整说明</h4>
            <pre className="tool-full-desc">{tool.description || "（该工具没有提供说明）"}</pre>
          </section>
        </div>
        <div className="dialog-foot">
          <span className="dim">{tool.available ? (tool.enabled ? "当前状态：已启用" : "当前状态：已停用") : "当前状态：不可用"}</span>
          <div className="actions">
            <button className="btn ghost" onClick={onClose}>
              关闭
            </button>
            <button className="btn primary" disabled={!tool.available || saving} onClick={onToggle}>
              {saving ? "保存中…" : tool.enabled ? "停用该工具" : "启用该工具"}
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}

function SkillsTab() {
  const [skills, setSkills] = useState<SkillInfo[] | null>(null);
  const [msg, setMsg] = useState<{ kind: "ok" | "err" | "info"; text: string } | null>(null);
  const [busy, setBusy] = useState(false);
  const [creating, setCreating] = useState(false);
  const [name, setName] = useState("");
  const [content, setContent] = useState("");
  const [pendingDelete, setPendingDelete] = useState<SkillInfo | null>(null);

  const load = useCallback(() => api.listSkills().then(setSkills).catch(() => setSkills([])), []);
  useEffect(() => void load(), [load]);

  const onPickZip = async (file: File | undefined) => {
    if (!file) return;
    setBusy(true);
    setMsg({ kind: "info", text: "上传中…" });
    try {
      const r = await api.uploadSkillZip(file);
      if (r.ok) {
        setMsg({ kind: "ok", text: `已导入技能：${(r.saved ?? []).join(", ")}` });
        await load();
      } else {
        setMsg({ kind: "err", text: r.error ?? "上传失败" });
      }
    } catch (e) {
      setMsg({ kind: "err", text: String(e) });
    } finally {
      setBusy(false);
    }
  };

  const createSkill = async () => {
    setBusy(true);
    try {
      const r = await api.createSkillText(name.trim(), content);
      if (r.ok) {
        setMsg({ kind: "ok", text: `已保存技能：${(r.saved ?? []).join(", ")}` });
        setCreating(false);
        setName("");
        setContent("");
        await load();
      } else {
        setMsg({ kind: "err", text: r.error ?? "保存失败" });
      }
    } finally {
      setBusy(false);
    }
  };

  return (
    <>
      <div className="tool-summary">
        <span>技能 <b>{skills?.length ?? 0}</b> 个</span>
        <span className="dim">技能 = 含 SKILL.md 的目录；模型按需 read_file 渐进式加载</span>
        <span className="tool-summary-actions">
          <label className="btn ghost sm" style={{ cursor: busy ? "wait" : "pointer" }}>
            <FileArchive size={13} /> 上传技能 zip
            <input type="file" accept=".zip" hidden onChange={(e) => void onPickZip(e.target.files?.[0])} disabled={busy} />
          </label>
          <button className="btn ghost sm" onClick={() => setCreating(true)}>
            <Plus size={13} /> 粘贴 SKILL.md
          </button>
        </span>
      </div>
      {msg && <div className={`msg-tip ${msg.kind}`} style={{ marginBottom: 12 }}>{msg.text}</div>}

      {skills === null ? (
        <div className="dim">加载中…</div>
      ) : skills.length === 0 ? (
        <div className="empty-box dim">还没有技能。上传一个 zip，或粘贴 SKILL.md 创建。</div>
      ) : (
        <div className="skill-list">
          {skills.map((s) => (
            <div key={s.id} className="skill-item">
              <div className="skill-main">
                <div className="skill-name">
                  <code>{s.id}</code>
                  {s.name !== s.id && <span className="badge">{s.name}</span>}
                  <span className="badge">{s.file_count} 文件</span>
                </div>
                <div className="skill-desc">{s.description || "（无 description，建议在 frontmatter 里补上）"}</div>
                <div className="skill-path mono dim">{s.path}</div>
              </div>
              <button className="btn ghost icon-btn sm" title="删除技能" onClick={() => setPendingDelete(s)}>
                <Trash2 size={14} />
              </button>
            </div>
          ))}
        </div>
      )}

      {creating && (
        <div className="dialog-backdrop" onClick={() => !busy && setCreating(false)}>
          <div className="dialog dialog-lg" onClick={(e) => e.stopPropagation()}>
            <div className="dialog-head">
              <div className="dialog-title-wrap">
                <h3>粘贴 SKILL.md 创建技能</h3>
                <div className="dialog-sub">
                  <span className="dim">首行 frontmatter 的 name 决定技能 id；description 会进模型提示词</span>
                </div>
              </div>
              <button className="btn ghost icon-btn sm" onClick={() => setCreating(false)} aria-label="关闭">
                <X size={15} />
              </button>
            </div>
            <div className="dialog-content">
              <div className="field-row">
                <label>技能名（没有 frontmatter name 时使用）</label>
                <input value={name} onChange={(e) => setName(e.target.value)} placeholder="例如：退款政策 / weekly-report" />
              </div>
              <div className="field-row">
                <label>SKILL.md 内容</label>
                <textarea
                  className="mono prompt-editor"
                  value={content}
                  onChange={(e) => setContent(e.target.value)}
                  placeholder={"---\\nname: refund-policy\\ndescription: 处理退款咨询时使用：先读 /notes/refund.md 再给结论\\n---\\n\\n# 退款处理\\n\\n1. 读取 /notes/refund.md\\n2. 给出结论与依据\\n"}
                />
              </div>
            </div>
            <div className="dialog-foot">
              <span className="dim">保存后新会话即刻可见（已有会话会重置技能缓存）</span>
              <div className="actions">
                <button className="btn ghost" onClick={() => setCreating(false)} disabled={busy}>
                  取消
                </button>
                <button className="btn primary" onClick={createSkill} disabled={busy || !content.trim()}>
                  {busy ? "保存中…" : "保存技能"}
                </button>
              </div>
            </div>
          </div>
        </div>
      )}

      {pendingDelete && (
        <ConfirmDialog
          title={`删除技能「${pendingDelete.id}」？`}
          description={<p className="dim small mono">{pendingDelete.path}</p>}
          confirmLabel="删除技能"
          onCancel={() => setPendingDelete(null)}
          onConfirm={async () => {
            await api.deleteSkill(pendingDelete.id);
            setPendingDelete(null);
            await load();
          }}
        />
      )}
    </>
  );
}