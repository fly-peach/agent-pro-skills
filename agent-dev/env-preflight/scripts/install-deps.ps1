param(
    [switch]$Apply,
    [switch]$WithNode,
    [switch]$SkipWinget
)
# 环境依赖安装 —— Windows 宿主侧（git / uv / bun / node）
#
# 安全约定：**默认 dry-run**（只打印将执行的命令），加 -Apply 才真正安装；已装的自动跳过。
# 说明：真正跑构建的是 WSL/Linux 侧 —— 宿主这些工具主要给「本地 vite dev」「本地 venv」「生成 Dockerfile」用。
#       若你只想用 Docker 部署，宿主只需要 git + bun（可选）。
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File .\install-deps.ps1              # 看看会装什么
#   powershell -ExecutionPolicy Bypass -File .\install-deps.ps1 -Apply      # 真正安装
#   powershell -ExecutionPolicy Bypass -File .\install-deps.ps1 -Apply -WithNode
#
# 装完请再跑 preflight.ps1 验证。

$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$script:have = 0; $script:todo = 0; $script:skip = 0
function Have([string]$m) { $script:have++; Write-Host "  [已有] $m" -ForegroundColor DarkGreen }
function Skip([string]$m) { $script:skip++; Write-Host "  [跳过] $m" -ForegroundColor DarkGray }
function Plan([string]$m) { $script:todo++; Write-Host "  [将执行] $m" -ForegroundColor Yellow }
function Step([string]$m) { Write-Host ""; Write-Host ("=== " + $m + " ===") -ForegroundColor Cyan }

function Invoke-Or-Plan([string]$desc, [scriptblock]$action) {
    if ($Apply) {
        Write-Host "  -> $desc"
        try { & $action } catch { Write-Host ("  -> 失败：" + $_.Exception.Message) -ForegroundColor Red }
    } else {
        Plan $desc
    }
}

$mode = "dry-run"
if ($Apply) { $mode = "安装" }
Write-Host ("环境依赖安装（" + $mode + " 模式）") -ForegroundColor White
if (-not $Apply) { Write-Host "  加 -Apply 才会真正安装" }

$hasWinget = [bool](Get-Command winget -ErrorAction SilentlyContinue)
if (-not $SkipWinget) {
    if ($hasWinget) { Write-Host ("  winget 可用：" + (& winget --version 2>$null)) }
    else { Write-Host "  [i] 没有 winget（老系统）：下面改用官方安装脚本" -ForegroundColor DarkYellow }
}

# === 1. git ===
Step "1. git"
if (Get-Command git -ErrorAction SilentlyContinue) {
    Have ("git " + (& git --version))
} else {
    Invoke-Or-Plan "装 git" {
        if ($hasWinget) { & winget install --id Git.Git -e --accept-source-agreements --accept-package-agreements }
        else { Write-Host "    请手动下载：https://git-scm.com/download/win" }
    }
}

# === 2. uv（Python 版本/依赖管理，本地 venv 与生成 Dockerfile 都要） ===
Step "2. uv"
if (Get-Command uv -ErrorAction SilentlyContinue) {
    Have ("uv " + (& uv --version))
} else {
    Invoke-Or-Plan "用官方脚本装 uv" {
        & powershell -NoProfile -c "irm https://astral.sh/uv/install.ps1 | iex"
    }
}

# === 3. bun（本地 vite dev / 前端构建） ===
Step "3. bun"
if (Get-Command bun -ErrorAction SilentlyContinue) {
    Have ("bun " + (& bun --version))
} else {
    Invoke-Or-Plan "用官方脚本装 bun" {
        & powershell -NoProfile -c "irm bun.sh/install.ps1 | iex"
    }
}

# === 4. Node（可选；用 bun 或 Docker 构建时可跳过） ===
Step "4. Node"
if (Get-Command node -ErrorAction SilentlyContinue) {
    Have ("node " + (& node --version))
} elseif ($WithNode) {
    Invoke-Or-Plan "装 Node LTS（winget OpenJS.NodeJS.LTS）" {
        if ($hasWinget) {
            & winget install --id OpenJS.NodeJS.LTS -e --accept-source-agreements --accept-package-agreements
        } else {
            Write-Host "    请手动下载：https://nodejs.org/（LTS）"
        }
    }
} else {
    Skip "未指定 -WithNode（用 bun 或 Docker 构建时可跳过）"
}

# === 5. Python（本地 venv 用；Docker 构建不需要） ===
Step "5. Python（本地 venv）"
$py = Get-Command python -ErrorAction SilentlyContinue
if ($py) {
    Have ("python " + (& python --version 2>&1))
    $pyv = (& python -c "import sys;print('%d.%d'%sys.version_info[:2])" 2>$null)
    if ($pyv -ne "3.12") { Write-Host ("  [i] 当前 Python " + $pyv + "；项目约定 3.12（uv venv --python 3.12 会自动下载，无需卸载现有版本）") -ForegroundColor DarkYellow }
} else {
    Invoke-Or-Plan "装 Python（winget Python.Python.3.12）" {
        if ($hasWinget) {
            & winget install --id Python.Python.3.12 -e --accept-source-agreements --accept-package-agreements
        } else {
            Write-Host "    请手动下载：https://www.python.org/downloads/"
        }
    }
}

# === 6. WSL 侧一键安装（提醒） ===
Step "6. WSL / Linux 侧依赖"
Write-Host "  宿主装完后，WSL 里还要有 docker/python3/uv："
Write-Host "    wsl -d Ubuntu -e bash -lc `"bash /mnt/<你的路径>/scripts/install-deps.sh --yes`""
Write-Host "  或者直接跑本 skill 的 preflight.ps1 看缺什么。"

Step "小结"
Write-Host ("  已满足: {0} 项 | 本次待执行: {1} 项 | 跳过: {2} 项" -f $script:have, $script:todo, $script:skip)
if (-not $Apply -and $script:todo -gt 0) {
    Write-Host ""
    Write-Host "  这是 dry-run。确认后执行："
    Write-Host ("    powershell -ExecutionPolicy Bypass -File .\install-deps.ps1 -Apply" + $(if ($WithNode) { " -WithNode" } else { "" }))
} else {
    Write-Host "  下一步：powershell -ExecutionPolicy Bypass -File .\preflight.ps1 -ProjectPath <项目路径>"
}
