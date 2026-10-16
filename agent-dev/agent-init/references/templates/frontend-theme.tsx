/** 亮暗主题：**两态直接切换**，一次点击即翻转，持久化到 localStorage。
 *
 * 关于首次访问：没有存储偏好时跟随系统（并实时响应系统变化），
 * 一旦用户手动切换就固定下来 —— 不设"跟随系统"这个需要多点一次的中间态。
 */
import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from "react";

export type ThemeMode = "light" | "dark";

const STORAGE_KEY = "agent-console-theme";

interface ThemeContextValue {
  mode: ThemeMode;
  /** 亮 ⇄ 暗，一次点击 */
  toggle: () => void;
}

const ThemeContext = createContext<ThemeContextValue>({ mode: "dark", toggle: () => {} });

const systemPrefersDark = () =>
  typeof window !== "undefined" && window.matchMedia("(prefers-color-scheme: dark)").matches;

function readStored(): ThemeMode | null {
  try {
    const saved = localStorage.getItem(STORAGE_KEY);
    return saved === "light" || saved === "dark" ? saved : null;
  } catch {
    return null;
  }
}

/** 落地到 <html data-theme>（index.html 里的内联脚本会在首屏前先跑一次，避免闪白）。 */
export function applyTheme(mode: ThemeMode) {
  document.documentElement.setAttribute("data-theme", mode);
}

export function ThemeProvider({ children }: { children: ReactNode }) {
  const [mode, setMode] = useState<ThemeMode>(
    () => readStored() ?? (systemPrefersDark() ? "dark" : "light")
  );

  useEffect(() => {
    applyTheme(mode);
  }, [mode]);

  // 用户还没手动选过 → 跟随系统切换
  useEffect(() => {
    if (readStored()) return;
    const mq = window.matchMedia("(prefers-color-scheme: dark)");
    const onChange = () => setMode(mq.matches ? "dark" : "light");
    mq.addEventListener("change", onChange);
    return () => mq.removeEventListener("change", onChange);
  }, [mode]);

  const toggle = useCallback(() => {
    setMode((prev) => {
      const next: ThemeMode = prev === "dark" ? "light" : "dark";
      try {
        localStorage.setItem(STORAGE_KEY, next);
      } catch {
        /* 隐私模式下忽略 */
      }
      return next;
    });
  }, []);

  const value = useMemo(() => ({ mode, toggle }), [mode, toggle]);
  return <ThemeContext.Provider value={value}>{children}</ThemeContext.Provider>;
}

export const useTheme = () => useContext(ThemeContext);
