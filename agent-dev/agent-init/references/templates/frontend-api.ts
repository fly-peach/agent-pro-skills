/** /demo/* 管理 API 封装 —— 应用级配置（模型 / 工具注册表 / agent 配置）。
 *  图拓扑、会话、运行等一律走平台 API（见 lib/chat.tsx 的 client）。 */

export const API_URL = (import.meta.env.VITE_API_URL as string | undefined) ?? "http://127.0.0.1:2024";

export interface ModelConfig {
  provider: string;
  base_url: string;
  api_key: string; // GET 返回掩码；PUT 传空或掩码 = 不修改
  has_key: boolean;
  model: string;
  thinking_model: string;
  temperature: number;
  extra_body: Record<string, unknown>;
}

export interface ToolInfo {
  name: string;
  description: string;
  summary: string;
  args: { properties?: Record<string, any>; required?: string[] };
  /** filesystem / execution / delegation / planning / custom */
  group: string;
  group_label: string;
  origin: "builtin" | "custom";
  available: boolean;
  unavailable_reason: string;
  enabled: boolean;
}

export interface SkillInfo {
  id: string;
  name: string;
  description: string;
  /** 虚拟路径：模型需要时用 read_file 渐进式加载 */
  path: string;
  files: string[];
  file_count: number;
  updated_at: string;
}

export interface AgentConfig {
  disabled_tools: string[];
  recursion_limit: number;
  /** 自定义指令：追加在内置 harness 指令之后 */
  system_prompt: string;
  /** 内置指令（只读，来自后端 agent.py 的 SYSTEM_PROMPT） */
  builtin_system_prompt?: string;
}

async function request<T>(method: string, path: string, body?: unknown): Promise<T> {
  const res = await fetch(API_URL + path, {
    method,
    headers: { "Content-Type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`${method} ${path} → ${res.status}`);
  return res.json() as Promise<T>;
}

export const api = {
  getModelConfig: () => request<ModelConfig>("GET", "/demo/model-config"),
  putModelConfig: (patch: Partial<ModelConfig>) =>
    request<{ ok: boolean; note: string }>("PUT", "/demo/model-config", patch),
  testModelConfig: () =>
    request<{ ok: boolean; reply?: string; error?: string }>("POST", "/demo/model-config/test"),
  listTools: () => request<ToolInfo[]>("GET", "/demo/tools"),
  getAgentConfig: () => request<AgentConfig>("GET", "/demo/agent-config"),
  // ── 技能库（Skills）──
  listSkills: () => request<SkillInfo[]>("GET", "/demo/skills"),
  createSkillText: (name: string, content: string) =>
    request<{ ok: boolean; saved?: string[]; error?: string }>("POST", "/demo/skills/text", { name, content }),
  uploadSkillZip: async (file: File) => {
    const fd = new FormData();
    fd.append("file", file);
    const res = await fetch(API_URL + "/demo/skills/upload", { method: "POST", body: fd });
    return (await res.json()) as { ok: boolean; saved?: string[]; error?: string };
  },
  deleteSkill: (id: string) =>
    request<{ ok: boolean }>("DELETE", `/demo/skills/${encodeURIComponent(id)}`),

  putAgentConfig: (patch: Partial<AgentConfig>) =>
    request<{ ok: boolean; error?: string }>("PUT", "/demo/agent-config", patch),
};
