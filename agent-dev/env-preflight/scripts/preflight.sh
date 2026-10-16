#!/usr/bin/env bash
# 环境预检 —— Linux / WSL 侧（只读检查，不改系统）
# 用法：bash preflight.sh [项目路径] [--json]
#   项目路径：可选，给了就额外做"版本一致性"检查（langgraph.json / pyproject / package.json / venv）
#   --json  ：输出机器可读的 KEY=VALUE 行（供 Windows 侧脚本汇总）
set -uo pipefail

PROJECT="${1:-}"
MODE="${2:-}"
JSON=0
[ "$MODE" = "--json" ] && JSON=1

pass=0; warn=0; fail=0
say()   { [ "$JSON" = "1" ] || printf '%s\n' "$*"; }
sec()   { if [ "$JSON" = "1" ]; then echo "META|$1"; else printf '
%s
' "$1"; fi; }
ok()    { pass=$((pass+1)); say "  [OK]   $1"; [ "$JSON" = "1" ] && echo "OK|$1"; }
warnf() { warn=$((warn+1)); say "  [WARN] $1"; [ "$JSON" = "1" ] && echo "WARN|$1"; }
failf() { fail=$((fail+1)); say "  [FAIL] $1"; [ "$JSON" = "1" ] && echo "FAIL|$1"; }

have() { command -v "$1" >/dev/null 2>&1; }
ver()  { "$@" 2>/dev/null | head -1; }

sec "──────── Linux / WSL 侧检查 ────────"

# 1. 发行版 / 内核 / 架构
if [ -r /etc/os-release ]; then
  . /etc/os-release
  say "发行版: ${PRETTY_NAME:-unknown}  内核: $(uname -r)  架构: $(uname -m)"
  case "${VERSION_ID:-}" in
    20.04|22.04|24.04|26.04|9.*|12|13) ok "发行版版本 ${VERSION_ID} 可用" ;;
    *) warnf "发行版 ${VERSION_ID:-未知}：Docker/语言工具链版本可能偏旧，建议 22.04+ 或 Debian 12+" ;;
  esac
else
  failf "读不到 /etc/os-release，可能不是标准 Linux 环境"
fi

# 2. systemd（Docker 服务托管、开机自启都靠它）
init_pid=$(ps -p 1 -o comm= 2>/dev/null | tr -d ' ')
if [ "$init_pid" = "systemd" ]; then
  ok "systemd 已启用（PID 1 = systemd）"
else
  warnf "PID 1 = ${init_pid:-unknown}，不是 systemd：docker 需手动启动（sudo service docker start）"
fi

# 3. 语言工具链
for t in python3 uv node bun git curl; do
  if have "$t"; then
    case "$t" in
      python3) v=$(ver python3 -V); pyv=$(python3 -c 'import sys;print("%d.%d"%sys.version_info[:2])')
               if have uv; then ok "$t $v（uv 会自行拉取 langgraph.json 指定的版本，系统版本不影响）"
               elif [[ "$pyv" == 3.11 || "$pyv" == 3.12 || "$pyv" == 3.13 ]]; then ok "$t $v"
               else warnf "$t $v：没有 uv 时需系统自带 3.12 才能建 venv → 建议装 uv" ; fi ;;
      node)    v=$(ver node -v); maj=$(echo "$v" | tr -d 'v' | cut -d. -f1); [ "${maj:-0}" -ge 20 ] && ok "$t $v" || warnf "$t $v：前端工具链建议 Node 20+（bun 无此限制）" ;;
      *)       ok "$t $(ver $t --version || ver $t -V || echo present)" ;;
    esac
  else
    case "$t" in
      python3) failf "缺少 python3" ;;
      uv)      warnf "缺少 uv（推荐：curl -LsSf https://astral.sh/uv/install.sh | sh）" ;;
      bun)     warnf "缺少 bun（仅在 WSL 里直接构建前端时需要；Docker 镜像自带 bun，可忽略）" ;;
      node)    warnf "缺少 node（Docker 构建不需要；本地 vite 才需要，可用 bun 代替）" ;;
      *)       warnf "缺少 $t" ;;
    esac
  fi
done

# 4. Docker：CLI 版本 + 守护进程存活 + compose v2
if have docker; then
  ok "docker CLI $(docker --version 2>/dev/null | sed 's/Docker version //;s/,.*//')"
  if docker info >/dev/null 2>&1; then
    ok "docker 守护进程存活（ServerVersion $(docker info --format '{{.ServerVersion}}' 2>/dev/null)）"
  else
    failf "docker 守护进程未运行 → 容器/构建全都会失败。处理：sudo service docker start 或 sudo systemctl start docker"
  fi
  if docker compose version >/dev/null 2>&1; then
    ok "docker compose $(docker compose version --short 2>/dev/null)"
  else
    failf "缺少 docker compose v2 插件（compose 命令不可用）"
  fi
else
  failf "WSL 里没有 docker（Windows 上的 Docker Desktop 未开启 WSL 集成时也会这样）"
fi

# 4.5 运行形态侦测（WSL 还是原生 Linux）+ 平台专属检查
PLATFORM="${PF_FORCE_PLATFORM:-auto}"
if [ "$PLATFORM" = "auto" ]; then
  if grep -qi microsoft /proc/version 2>/dev/null || [ -n "${WSL_DISTRO_NAME:-}" ]; then PLATFORM="WSL"; else PLATFORM="Linux"; fi
elif [ "$PLATFORM" != "WSL" ] && [ "$PLATFORM" != "Linux" ]; then
  warnf "PF_FORCE_PLATFORM 取值无效（应为 WSL 或 Linux），已按自动侦测处理"; PLATFORM="Linux"
fi
if [ "$PLATFORM" = "WSL" ]; then
  ok "运行形态：WSL（与 Windows 共享 localhost；注意 WSL 被系统收起会停掉容器）"
else
  ok "运行形态：原生 Linux（注意防火墙/安全组放行、docker 开机自启）"
fi

if [ "$PLATFORM" = "Linux" ]; then
  # 权限：docker 是否需要 sudo
  if [ "$(id -u)" = "0" ]; then
    ok "以 root 运行（docker 无需 sudo）"
  elif id -nG 2>/dev/null | tr ' ' '
' | grep -qx docker; then
    ok "当前用户在 docker 组（docker 无需 sudo）"
  else
    warnf "当前用户不在 docker 组：docker 命令都要 sudo → sudo usermod -aG docker $USER && newgrp docker（重新登录生效）"
  fi

  # docker 开机自启（服务器重启后容器要自己回来）
  if command -v systemctl >/dev/null 2>&1; then
    en=$(systemctl is-enabled docker 2>/dev/null)
    if [ "$en" = "enabled" ]; then ok "docker 已设置开机自启（systemctl is-enabled = enabled）"
    else warnf "docker 未设开机自启 → sudo systemctl enable docker（否则重启后容器不会回来）"; fi
  fi

  # 防火墙 / 安全组：容器发布了端口，但被防火墙挡住一样访问不了
  if command -v ufw >/dev/null 2>&1; then
    ufw_st=$(ufw status 2>/dev/null | head -1)
    case "$ufw_st" in
      *inactive*) ok "ufw 未启用（无防火墙阻塞）" ;;
      *active*)   for p in 2024 5173 5433; do
                    if ufw status 2>/dev/null | grep -qE "(^|[^0-9])$p(/tcp)?([^0-9]|$)"; then ok "ufw 已放行端口 $p"
                    else warnf "ufw 已启用但未见放行 $p → 外部/局域网访问不了：sudo ufw allow $p/tcp"; fi
                  done ;;
      *)          warnf "ufw 状态未知（可能需要 root 才能读）：sudo ufw status" ;;
    esac
  elif command -v firewall-cmd >/dev/null 2>&1; then
    if firewall-cmd --state >/dev/null 2>&1; then
      for p in 2024 5173 5433; do
        if firewall-cmd --list-ports 2>/dev/null | grep -q "$p/tcp"; then ok "firewalld 已放行端口 $p"
        else warnf "firewalld 运行中但未放行 $p → sudo firewall-cmd --permanent --add-port=$p/tcp && sudo firewall-cmd --reload"; fi
      done
    else
      ok "firewalld 未运行"
    fi
  else
    ok "未检测到 ufw/firewalld（云主机请确认安全组放行 2024/5173/5433）"
  fi

  # 时间同步（checkpoint 时间戳 / TLS / 令牌都依赖）
  if command -v timedatectl >/dev/null 2>&1; then
    if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -qi yes; then ok "系统时间已同步（NTP）"
    else warnf "系统时间未同步 → sudo timedatectl set-ntp true"; fi
  fi

  # swap：构建峰值兜底
  sw=$(free -m 2>/dev/null | awk '/Swap:/{print $2}')
  if [ -n "${sw:-}" ] && [ "$sw" -gt 0 ]; then ok "swap ${sw}Mi（构建峰值有兜底）"
  else warnf "无 swap：Docker 构建（尤其前端/镜像层）峰值可能触发 OOM kill → 加 2-4G swapfile"; fi

  # 本机 IP 提示（方便告知从哪访问）
  ips=$(hostname -I 2>/dev/null | tr ' ' '
' | grep -v '^$' | head -3 | tr '
' ' ')
  [ -n "$ips" ] && ok "本机地址：$ips（确认从外部访问用的是哪个）"
fi


# 5. 端口占用（宿主 Windows 与 WSL 共享 localhost，两个方向都算冲突）
for p in 2024 5173 5433 6379; do
  if have ss; then
    if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$p$"; then
      warnf "端口 $p 在 WSL 内已被占用（约定规划：2024=api / 5173=frontend / 5433=pg / 6379=redis）"
    else
      ok "端口 $p 空闲"
    fi
  fi
done

# 5.5 项目所在文件系统（影响 Docker 构建速度）
if [ -n "$PROJECT" ] && [ -d "$PROJECT" ]; then
  fstype=$(df -PT "$PROJECT" 2>/dev/null | awk 'NR==2{print $2}')
  case "${fstype:-}" in
    9p|drvfs)  warnf "项目在 ${fstype}（Windows 盘挂载到 WSL）：Docker 构建上下文读取慢，构建耗时长属正常；追求速度可把项目放 WSL 内部盘（~/proj）" ;;
    nfs*|cifs|smb*) warnf "项目在网络文件系统 ${fstype}：构建上下文与热重载都会变慢" ;;
    fuseblk|fuse*) warnf "项目在 ${fstype} 虚拟文件系统上：文件监听可能失效" ;;
    "")        : ;;
    *)         ok "项目文件系统 ${fstype}" ;;
  esac
fi


# 6. 资源
say "资源: CPU $(nproc 2>/dev/null || echo ?) 核 | 内存 $(free -m 2>/dev/null | awk '/Mem:/{printf "%dMi (可用 %dMi)", $2, $7}')"
mem_mb=$(free -m 2>/dev/null | awk '/Mem:/{print $2}')
if [ -n "${mem_mb:-}" ] && [ "$mem_mb" -lt 7000 ]; then
  warnf "WSL 内存 ${mem_mb}Mi < 7G：Docker 构建 + 4 个容器容易吃紧（可在 .wslconfig 里调 memory=8GB）"
else
  ok "内存充足（≥7G）"
fi
disk_avail=$(df -Pm / 2>/dev/null | awk 'NR==2{print $4}')
if [ -n "${disk_avail:-}" ] && [ "$disk_avail" -lt 8000 ]; then
  warnf "根分区可用 ${disk_avail}Mi < 8G：拉镜像 + 构建层可能不够"
else
  ok "根分区可用 $(( ${disk_avail:-0} / 1024 ))Gi"
fi

# 7. 网络可达性（拉依赖/镜像都要）
check_net() {
  local name="$1" url="$2" t
  t=$(curl -s -o /dev/null -w '%{http_code} %{time_total}' --max-time 8 "$url" 2>/dev/null)
  local code=${t%% *} sec=${t##* }
  if [ "$code" = "200" ] || [ "$code" = "301" ] || [ "$code" = "302" ] || [ "$code" = "401" ] || [ "$code" = "403" ]; then
    ok "网络: ${name} 可达（${sec}s）"
  else
    warnf "网络: ${name} 不可达/超时（code=${code:-none}）：考虑配镜像源"
  fi
}
check_net "PyPI" "https://pypi.org/simple/"
check_net "npm registry" "https://registry.npmjs.org/"
if getent hosts registry-1.docker.io >/dev/null 2>&1; then
  ok "网络: Docker Hub DNS 可解析（拉镜像应该没问题）"
else
  warnf "网络: Docker Hub 域名解析失败 → 配镜像源（/etc/docker/daemon.json registry-mirrors）或检查代理"
fi

# 8. 编码 / locale
if [ "${PYTHONUTF8:-}" = "1" ] || [[ "${LC_ALL:-}${LANG:-}" == *UTF-8* ]]; then
  ok "UTF-8 环境就绪（LANG=${LANG:-} PYTHONUTF8=${PYTHONUTF8:-}）"
else
  warnf "locale 非 UTF-8（LANG=${LANG:-unset}）：Python 读写中文文件可能报 UnicodeDecodeError → 启动命令前加 PYTHONUTF8=1"
fi

# 9. 项目级：版本一致性矩阵（最关键，跨 4 处对齐）
if [ -n "$PROJECT" ] && [ -d "$PROJECT" ]; then
  sec "──────── 版本一致性（$PROJECT）────────"
  lgj="$PROJECT/backend/langgraph.json"
  pyproj="$PROJECT/backend/pyproject.toml"
  pkg="$PROJECT/frontend/package.json"

  lg_py=""
  if [ -f "$lgj" ]; then
    lg_py=$(python3 - "$lgj" <<'PY' 2>/dev/null
import json,sys
try:
    cfg=json.load(open(sys.argv[1],encoding="utf-8"))
    print(cfg.get("python_version",""))
except Exception:
    print("")
PY
)
  else
    warnf "缺 backend/langgraph.json"
  fi

  req_py=""
  if [ -f "$pyproj" ]; then
    req_py=$(python3 - "$pyproj" <<'PY' 2>/dev/null
import sys
try:
    import tomllib
    with open(sys.argv[1], "rb") as f:
        print(tomllib.load(f).get("project", {}).get("requires-python", ""))
except Exception:
    print("")
PY
)
  fi
  venv_py=""; venv_note=""
  if [ -x "$PROJECT/backend/.venv/bin/python" ]; then
    venv_py=$("$PROJECT/backend/.venv/bin/python" -c 'import sys;print("%d.%d.%d"%sys.version_info[:3])' 2>/dev/null)
  elif [ -f "$PROJECT/backend/.venv/Scripts/python.exe" ]; then
    venv_note="（Windows 风格 venv，仅宿主可用；WSL/Docker 里用不到）"
  fi

  say "  python 对齐: langgraph.json='${lg_py:-未设}' | requires-python='${req_py:-未设}' | venv='${venv_py:-无}${venv_note}'"
  if [ -n "$lg_py" ] && [ -n "$venv_py" ]; then
    case "$venv_py" in "$lg_py"*) ok "venv 与 langgraph.json 的 python_version 一致（$lg_py）" ;;
      *) failf "venv($venv_py) ≠ langgraph.json python_version($lg_py)：Docker 基础镜像会按 ${lg_py} 走，本地 venv 会不一致 → uv venv --python $lg_py" ;;
    esac
  elif [ -n "$venv_note" ]; then
    ok "backend/.venv 是 Windows 风格（宿主用）；WSL/Docker 不需要它"
  elif [ -n "$lg_py" ]; then
    warnf "没有 backend/.venv（Docker 部署可忽略；本地联调需要 uv venv --python ${lg_py}）"
  fi
  if [ -n "$lg_py" ] && [ -n "$req_py" ]; then
    case "$req_py" in *"$lg_py"*) ok "requires-python($req_py) 与 python_version($lg_py) 相容" ;;
      *) warnf "requires-python='$req_py' 与 python_version='$lg_py' 可能冲突 → 官方 Dockerfile 构建会报 not satisfiable" ;;
    esac
  fi

  if [ -f "$pkg" ]; then
    engines=$(python3 - "$pkg" <<'PY' 2>/dev/null
import json,sys
try:
    d=json.load(open(sys.argv[1],encoding="utf-8"))
    print((d.get("engines") or {}).get("node",""))
except Exception:
    print("")
PY
)
    node_v=$(node -v 2>/dev/null | tr -d 'v')
    say "  node 对齐: engines='${engines:-未声明}' | 实际='${node_v:-未安装}'"
    if [ -n "$engines" ] && [ -n "$node_v" ]; then
      need=$(echo "$engines" | tr -dc '0-9' | head -c2)
      got=$(echo "$node_v" | cut -d. -f1)
      if [ -n "$need" ] && [ "${got:-0}" -ge "${need:-0}" ]; then ok "node ${node_v} 满足 engines ${engines}"; else warnf "node ${node_v} 不满足 engines ${engines}"; fi
    fi
  else
    warnf "缺 frontend/package.json"
  fi

  if [ -f "$PROJECT/backend/pyproject.toml" ] && [ -x "$PROJECT/backend/.venv/bin/python" ]; then
    if (cd "$PROJECT/backend" && uv pip check >/dev/null 2>&1); then
      ok "uv pip check 通过（已装依赖互相不冲突）"
    else
      warnf "uv pip check 有冲突：cd backend && uv pip check（常见于 deepagents 与 langchain 版本混装）"
    fi
  fi

  if [ -f "$PROJECT/docker-compose.yml" ]; then
    ok "docker-compose.yml 存在"
  else
    warnf "缺 docker-compose.yml（若只做本地 dev 可忽略）"
  fi
fi

say ""
say "Linux 侧小结：OK=$pass WARN=$warn FAIL=$fail"
[ "$JSON" = "1" ] && echo "SUMMARY|$pass|$warn|$fail"
[ "$fail" -gt 0 ] && exit 1 || exit 0
