/** 会话（对话）状态中心：官方 UI 的 ChatProvider 等价物。
 *
 * - useChat：包装 @langchain/react 的 useStream（threadId / onThreadId / optimistic）
 * - useThreads：用 SDK Client 直接管理线程列表（langgraph dev 自带 /threads 接口）
 */
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
  type ReactNode,
} from "react";
import { useStream } from "@langchain/react";
import { Client } from "@langchain/langgraph-sdk";
import type { ThreadState } from "@langchain/langgraph-sdk";
import { API_URL } from "./api";
import type { AgentState, ThreadSummary, TodoItem } from "./types";

export const client = new Client({ apiUrl: API_URL });

export interface ChatContextValue {
  stream: any;
  messages: any[];
  todos: TodoItem[];
  files: Record<string, any>;
  isLoading: boolean;
  isThreadLoading: boolean;
  interrupt: any;
  threadId: string | null;
  sendMessage: (text: string) => void;
  stopStream: () => void;
  resumeInterrupt: (value: unknown) => void;
  setFiles: (files: Record<string, any>) => Promise<void>;
}

const ChatContext = createContext<ChatContextValue | null>(null);

export function ChatProvider({
  assistantId,
  seedThreadId,
  recursionLimit,
  onThreadId,
  onHistoryRevalidate,
  children,
}: {
  assistantId: string;
  seedThreadId: string | null;
  recursionLimit: number;
  onThreadId?: (id: string) => void;
  onHistoryRevalidate?: () => void;
  children: ReactNode;
}) {
  const [boundThreadId, setBoundThreadId] = useState<string | null>(seedThreadId);

  const stream = useStream<AgentState>({
    apiUrl: API_URL,
    assistantId,
    threadId: seedThreadId,
    onThreadId: (id: string) => {
      setBoundThreadId(id);
      onThreadId?.(id);
    },
  });

  const sendMessage = useCallback(
    (text: string) => {
      const message = { id: crypto.randomUUID(), type: "human", content: text };
      stream.submit({ messages: [message] }, { config: { recursion_limit: recursionLimit } });
      onHistoryRevalidate?.();
    },
    [stream, recursionLimit, onHistoryRevalidate]
  );

  const stopStream = useCallback(() => void stream.stop(), [stream]);

  const resumeInterrupt = useCallback(
    (value: unknown) => {
      stream.respond(value);
      onHistoryRevalidate?.();
    },
    [stream, onHistoryRevalidate]
  );

  const setFiles = useCallback(
    async (files: Record<string, any>) => {
      const id = boundThreadId ?? stream.threadId;
      if (!id) return;
      await client.threads.updateState(id, { values: { files } } as any);
    },
    [boundThreadId, stream]
  );

  const value: ChatContextValue = useMemo(
    () => ({
      stream,
      messages: stream.messages ?? [],
      todos: stream.values?.todos ?? [],
      files: (stream.values?.files ?? {}) as Record<string, any>,
      isLoading: stream.isLoading,
      isThreadLoading: stream.isThreadLoading,
      interrupt: stream.interrupt,
      threadId: boundThreadId ?? stream.threadId ?? null,
      sendMessage,
      stopStream,
      resumeInterrupt,
      setFiles,
    }),
    [stream, boundThreadId, sendMessage, stopStream, resumeInterrupt, setFiles]
  );

  return <ChatContext.Provider value={value}>{children}</ChatContext.Provider>;
}

export function useChatContext(): ChatContextValue {
  const ctx = useContext(ChatContext);
  if (!ctx) throw new Error("useChatContext 必须在 ChatProvider 内使用");
  return ctx;
}

/** 线程列表：**不按图拆分** —— thinking / 非 thinking 共用同一份会话列表。
 *  平台里线程状态是共享的：同一条 thread 换 assistant 续跑，历史照常保留，
 *  所以"用哪个模型"只是每次运行的目标，不该成为会话的划分维度。 */
export function useThreads(version: number) {
  const [threads, setThreads] = useState<ThreadSummary[]>([]);
  const [count, setCount] = useState(0);
  const [loading, setLoading] = useState(true);

  const refresh = useCallback(async () => {
    try {
      const [list, total] = await Promise.all([
        client.threads.search({ limit: 50, sortBy: "updated_at", sortOrder: "desc" } as any),
        client.threads.count().catch(() => 0),
      ]);
      setCount(total as number);
      setThreads(
        (list as any[]).map((t) => ({
          id: t.thread_id,
          title: titleOf(t),
          updatedAt: t.updated_at ?? t.created_at,
          status: t.status,
          values: t.values,
        }))
      );
    } catch {
      setThreads([]);
    }
    setLoading(false);
  }, []);

  useEffect(() => {
    void refresh();
  }, [refresh, version]);

  const remove = useCallback(
    async (id: string) => {
      await client.threads.delete(id);
      await refresh();
    },
    [refresh]
  );

  /** 平台 API：复制会话（GET 不需要，POST /threads/{id}/copy） */
  const copy = useCallback(
    async (id: string) => {
      const copied = await client.threads.copy(id);
      await refresh();
      return copied?.thread_id as string | undefined;
    },
    [refresh]
  );

  /** 预检空壳会话：逐条查 state，返回"无消息"的线程 id（不删除，交给确认弹窗） */
  const findEmptyThreads = useCallback(async () => {
    const empties: string[] = [];
    for (const t of threads) {
      try {
        const st = await client.threads.getState(t.id);
        const messages = (st?.values as any)?.messages;
        if (!Array.isArray(messages) || messages.length === 0) empties.push(t.id);
      } catch {
        /* 查不到就跳过，避免误删 */
      }
    }
    return empties;
  }, [threads]);

  /** 执行删除：平台 POST /threads/prune（strategy: delete）批量删，返回删除条数 */
  const pruneThreads = useCallback(
    async (ids: string[]) => {
      if (!ids.length) return 0;
      const r = await client.threads.prune(ids, { strategy: "delete" });
      await refresh();
      return r?.pruned_count ?? ids.length;
    },
    [refresh]
  );

  return { threads, count, loading, refresh, remove, copy, findEmptyThreads, pruneThreads };
}

/** 平台 API：可用图（assistant）列表 —— 前端不再硬编码 agent / agent-thinking */
export function useAssistants() {
  const [graphIds, setGraphIds] = useState<string[]>([]);
  useEffect(() => {
    client.assistants
      .search({ limit: 50 })          // 不传 includePagination → 返回 Assistant[]
      .then((list) => setGraphIds([...new Set(list.map((a) => a.graph_id))].sort()))
      .catch(() => setGraphIds([]));
  }, []);
  return graphIds;
}

/** 平台 API：检查点历史 GET /threads/{id}/history（time-travel 用） */
export async function fetchCheckpoints(threadId: string, limit = 50): Promise<ThreadState<any>[]> {
  return (await client.threads.getHistory(threadId, { limit })) as ThreadState<any>[];
}

/** 标题取首条人类消息的前若干字（与官方 UI 一致）；values 缺失时回退到会话 id。 */
function titleOf(thread: any): string {
  const messages = thread?.values?.messages;
  if (Array.isArray(messages)) {
    const first = messages.find((m: any) => m.type === "human" || m.role === "user");
    const raw = first?.content ?? first?.content_blocks;
    const text = typeof raw === "string" ? raw : Array.isArray(raw) ? raw.map((b: any) => b?.text ?? "").join(" ") : "";
    if (text.trim()) return text.trim().slice(0, 60);
    if (messages.length) return "新会话";
  }
  return `会话 ${String(thread?.thread_id ?? "").slice(0, 8)}`;
}

export function relativeTime(iso: string): string {
  const then = new Date(iso).getTime();
  if (Number.isNaN(then)) return "";
  const diff = Date.now() - then;
  const min = Math.floor(diff / 60000);
  if (min < 1) return "刚刚";
  if (min < 60) return `${min} 分钟前`;
  const hour = Math.floor(min / 60);
  if (hour < 24) return `${hour} 小时前`;
  const day = Math.floor(hour / 24);
  if (day < 30) return `${day} 天前`;
  return new Date(iso).toLocaleDateString();
}
