/** 未开发占位：就一句话。 */
import { Construction } from "lucide-react";

export function NotDeveloped({ compact = false }: { compact?: boolean }) {
  return (
    <div className={`nd ${compact ? "nd-compact" : ""}`}>
      <Construction size={compact ? 14 : 16} />
      <span>未开发</span>
    </div>
  );
}
