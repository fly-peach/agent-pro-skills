#!/usr/bin/env bash
# 环境依赖安装 —— Linux / WSL（Docker / Python / uv / Node / bun / git / swap）
#
# 安全约定：**默认 dry-run**（只打印将执行的命令），加 --yes 才真正安装；已装的自动跳过。
#
# 用法：
#   bash install-deps.sh                        # 看看会装什么（不改系统）
#   bash install-deps.sh --yes                  # 真正安装（Docker+Python+uv+git）
#   bash install-deps.sh --yes --with-bun       # 额外装 bun（前端本地构建用）
#   bash install-deps.sh --yes --with-node      # 额外装 Node 22
#   bash install-deps.sh --yes --swap 2048      # 额外加 2G swap
#
# 装完请再跑一次 preflight.sh 验证。
set -uo pipefail

APPLY=0; WITH_NODE=0; WITH_BUN=0; SWAP_MB=0
while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y)   APPLY=1 ;;
    --dry-run)  APPLY=0 ;;
    --with-node) WITH_NODE=1 ;;
    --with-bun)  WITH_BUN=1 ;;
    --swap)      SWAP_MB="${2:-2048}"; shift ;;
    --help|-h)   sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "未知参数: $1（--help 看用法）"; exit 2 ;;
  esac
  shift
done

MODE="dry-run"
[ "$APPLY" = "1" ] && MODE="安装"
pass=0; skip=0; todo=0
have() { command -v "$1" >/dev/null 2>&1; }
say()  { printf '%s\n' "$*"; }
step() { printf '\n=== %s ===\n' "$*"; }
done_() { pass=$((pass+1)); printf '  [已有] %s\n' "$1"; }
skip_() { skip=$((skip+1)); printf '  [跳过] %s\n' "$1"; }
plan()  { todo=$((todo+1)); printf '  [将执行] %s\n' "$1"; }

run() {  # run "<说明>" <命令...>
  local desc="$1"; shift
  if [ "$APPLY" = "1" ]; then
    printf '  $ %s\n' "$*"
    if "$@"; then printf '  -> ok\n'; else printf '  -> 失败（请手动执行上面命令）\n'; fi
  else
    plan "$desc ： $*"
  fi
}

# 需要 sudo 吗
SUDO=""
if [ "$(id -u)" != "0" ]; then SUDO="sudo"; fi
can_sudo() {
  [ -z "$SUDO" ] && return 0
  sudo -n true 2>/dev/null
}

say "环境依赖安装（$MODE 模式）$( [ "$APPLY" = "1" ] || echo '：加 --yes 才会真正安装' )"

# ── 0. 发行版与包管理器 ──────────────────────────────────────────
step "0. 发行版与包管理器"
if [ -r /etc/os-release ]; then . /etc/os-release; say "  发行版: ${PRETTY_NAME:-unknown}"; fi
PM=""; PM_INSTALL=""
if   have apt-get; then PM="apt"; PM_INSTALL="apt-get install -y"
elif have dnf;     then PM="dnf"; PM_INSTALL="dnf install -y"
elif have yum;     then PM="yum"; PM_INSTALL="yum install -y"
elif have pacman;  then PM="pacman"; PM_INSTALL="pacman -S --noconfirm --needed"
elif have apk;     then PM="apk"; PM_INSTALL="apk add --no-cache"
else
  say "  [FAIL] 未识别的包管理器（支持 apt/dnf/yum/pacman/apk）→ 只能手动装 Docker/Python"; exit 1
fi
say "  包管理器: $PM"
if [ -n "$SUDO" ] && ! can_sudo; then
  say "  [!] 当前用户需要密码才能 sudo：下面的命令会提示输密码；想免交互请先手动 sudo -v"
fi

# ── 1. 基础工具 ─────────────────────────────────────────────────
step "1. 基础工具（curl / ca-certificates / git / unzip）"
need_base=""
for t in curl git; do have "$t" || need_base="$need_base $t"; done
if [ -n "$need_base" ]; then
  case "$PM" in
    apt) pkgs="curl ca-certificates git unzip" ;;
    *)   pkgs="curl ca-certificates git unzip" ;;
  esac
  run "装基础工具$need_base" $SUDO $PM_INSTALL $pkgs
else
  done_ "curl / git 已安装（$(git --version 2>/dev/null | head -1)）"
fi

# ── 2. Python + venv + pip ──────────────────────────────────────
step "2. Python 3（含 venv / pip）"
if have python3 && python3 -c 'import venv' 2>/dev/null; then
  done_ "python3 $(python3 -V 2>&1 | sed 's/Python //')（venv 可用）"
else
  case "$PM" in
    apt) run "装 Python3 + venv + pip" $SUDO $PM_INSTALL python3 python3-venv python3-pip ;;
    dnf|yum) run "装 Python3 + pip" $SUDO $PM_INSTALL python3 python3-pip ;;
    pacman)  run "装 Python + pip" $SUDO $PM_INSTALL python python-pip ;;
    apk)     run "装 Python3 + pip" $SUDO $PM_INSTALL python3 py3-pip ;;
  esac
fi

# ── 3. uv（Python 版本与依赖管理） ───────────────────────────────
step "3. uv"
if have uv; then
  done_ "uv $(uv --version 2>/dev/null)"
else
  run "用官方脚本装 uv（装到 ~/.local/bin）" bash -c 'curl -LsSf https://astral.sh/uv/install.sh | sh'
  say "  提醒：装完确保 PATH 含 ~/.local/bin（脚本会提示，或 source ~/.bashrc）"
fi

# ── 4. Docker + compose v2 ──────────────────────────────────────
step "4. Docker Engine + compose v2"
if have docker && docker compose version >/dev/null 2>&1; then
  done_ "docker $(docker --version 2>/dev/null | sed 's/Docker version //;s/,.*//') + compose $(docker compose version --short 2>/dev/null)"
else
  case "$PM" in
    apt)     run "装 Docker + compose 插件（发行版包）" $SUDO $PM_INSTALL docker.io docker-compose-v2 ;;
    dnf|yum) run "装 Docker + compose 插件" $SUDO $PM_INSTALL docker docker-compose-plugin ;;
    pacman)  run "装 Docker + compose" $SUDO $PM_INSTALL docker docker-compose ;;
    apk)     run "装 Docker + compose" $SUDO $PM_INSTALL docker docker-cli-compose ;;
  esac
  say "  若发行版仓库版本过旧，可改用官方脚本：curl -fsSL https://get.docker.com | sh"
fi
# 启动 + 开机自启
if have systemctl; then
  if systemctl is-active docker >/dev/null 2>&1; then
    done_ "docker 服务运行中"
  else
    run "启动 docker 服务" $SUDO systemctl start docker
  fi
  if [ "$(systemctl is-enabled docker 2>/dev/null)" = "enabled" ]; then
    done_ "docker 已设开机自启"
  else
    run "设 docker 开机自启" $SUDO systemctl enable docker
  fi
fi
# docker 组（免 sudo）
if [ "$(id -u)" != "0" ]; then
  if id -nG 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
    done_ "当前用户已在 docker 组"
  else
    run "把 $USER 加入 docker 组（需重新登录/newgrp 生效）" $SUDO usermod -aG docker "$USER"
  fi
fi

# ── 5. bun（前端本地构建；Docker 构建不需要） ────────────────────
step "5. bun${WITH_BUN:+（--with-bun）}"
if have bun; then
  done_ "bun $(bun --version 2>/dev/null)"
elif [ "$WITH_BUN" = "1" ]; then
  run "用官方脚本装 bun（装到 ~/.bun/bin）" bash -c 'curl -fsSL https://bun.sh/install | bash'
  say "  提醒：确保 PATH 含 ~/.bun/bin"
else
  skip_ "未指定 --with-bun（Docker 构建自带 bun，可跳过）"
fi

# ── 6. Node（可选） ─────────────────────────────────────────────
step "6. Node${WITH_NODE:+（--with-node）}"
if have node; then
  done_ "node $(node -v 2>/dev/null)"
elif [ "$WITH_NODE" = "1" ]; then
  case "$PM" in
    apt)
      run "装 Node 22（NodeSource 源）" bash -c 'curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - && sudo apt-get install -y nodejs' ;;
    *) run "装 Node（发行版包）" $SUDO $PM_INSTALL nodejs npm ;;
  esac
else
  skip_ "未指定 --with-node（用 bun 或 Docker 构建时可跳过）"
fi

# ── 7. swap（可选，构建峰值兜底） ───────────────────────────────
step "7. swap${SWAP_MB:+（--swap ${SWAP_MB}M）}"
sw_now=$(free -m 2>/dev/null | awk '/Swap:/{print $2}')
if [ "${sw_now:-0}" -gt 0 ]; then
  done_ "已有 swap ${sw_now}Mi"
elif [ "$SWAP_MB" -gt 0 ]; then
  run "创建 ${SWAP_MB}Mi swapfile" bash -c "sudo fallocate -l ${SWAP_MB}M /swapfile || sudo dd if=/dev/zero of=/swapfile bs=1M count=${SWAP_MB}"
  run "mkswap + swapon" bash -c "sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile"
  run "写入 /etc/fstab（重启后自动挂）" bash -c "grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab"
else
  skip_ "未指定 --swap（构建内存紧张时建议加 2G）"
fi

# ── 小结 ────────────────────────────────────────────────────────
step "小结"
say "  已满足: $pass 项 | 本次待执行: $todo 项 | 跳过: $skip 项"
if [ "$APPLY" = "0" ] && [ "$todo" -gt 0 ]; then
  say ""
  say "  这是 dry-run。确认无误后执行： bash $0 --yes$( [ "$WITH_BUN" = "1" ] && echo ' --with-bun' )$( [ "$WITH_NODE" = "1" ] && echo ' --with-node' )$( [ "$SWAP_MB" -gt 0 ] && echo " --swap $SWAP_MB" )"
else
  say "  下一步：bash preflight.sh <项目路径> 验证环境；然后 docker compose up -d --build"
fi
