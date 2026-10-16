param(
    [string]$ProjectPath = "",
    [string]$Distro = "",
    [switch]$Json
)
# Environment preflight - Windows host side (read-only) + delegates to preflight.sh inside WSL
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\preflight.ps1
#   powershell -ExecutionPolicy Bypass -File .\preflight.ps1 -ProjectPath E:\agent-skills\demo
#   powershell -ExecutionPolicy Bypass -File .\preflight.ps1 -Distro Ubuntu -ProjectPath E:\path\to\proj
#
# Exit code: 0 = no blocking failure; 1 = at least one FAIL

$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$script:pass = 0; $script:warn = 0; $script:fail = 0
function Ok([string]$m)   { $script:pass++; if (-not $Json) { Write-Host "  [OK]   $m" -ForegroundColor DarkGreen } }
function Warn([string]$m) { $script:warn++; if (-not $Json) { Write-Host "  [WARN] $m" -ForegroundColor Yellow } }
function Fail([string]$m) { $script:fail++; if (-not $Json) { Write-Host "  [FAIL] $m" -ForegroundColor Red } }
function Sect([string]$m) { if (-not $Json) { Write-Host ""; Write-Host ("---- " + $m + " ----") -ForegroundColor Cyan } }

function Get-WslPath([string]$winPath) {
    if ([string]::IsNullOrEmpty($winPath)) { return "" }
    $bs = [char]92
    $p = $winPath.Replace($bs, "/")
    if ($p -match "^([A-Za-z]):(.*)$") { return "/mnt/" + $matches[1].ToLower() + $matches[2] }
    return $p
}

if (-not $Json) { Write-Host "==== Environment preflight (Windows + WSL) ====" -ForegroundColor White }

# ---- 1. WSL itself ----
Sect "WSL"
$wslExe = Get-Command wsl.exe -ErrorAction SilentlyContinue
if (-not $wslExe) {
    Fail "wsl.exe not found: enable WSL2 first (wsl --install)"
} else {
    # 发行版列表走注册表（wsl.exe -l -v 输出是 UTF-16，解析易出错）
    $lxss = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss"
    $distros = @()
    try {
        $defaultGuid = (Get-ItemProperty -Path $lxss -ErrorAction Stop).DefaultDistribution
        foreach ($k in Get-ChildItem -Path $lxss -ErrorAction Stop) {
            $props = Get-ItemProperty -Path $k.PSPath
            if ($props.DistributionName) {
                $distros += [pscustomobject]@{
                    Name    = $props.DistributionName
                    Ver     = [string]$props.Version
                    Default = ($k.PSChildName -eq $defaultGuid)
                    Guid    = $k.PSChildName
                }
            }
        }
    } catch {
        Warn "cannot read WSL distro list from registry: $($_.Exception.Message)"
    }

    if ($distros.Count -eq 0) {
        Fail "no WSL distro found (install one: wsl --install -d Ubuntu)"
    } else {
        foreach ($d in $distros) {
            $tag = ""
            if ($d.Default) { $tag = " (default)" }
            if ($d.Ver -eq "2") { Ok ("distro " + $d.Name + $tag + " = WSL2") }
            else { Warn ("distro " + $d.Name + $tag + " = WSL" + $d.Ver + ": Docker needs WSL2") }
        }
        if (-not $Distro) {
            $def = $distros | Where-Object { $_.Default } | Select-Object -First 1
            if ($def) { $Distro = $def.Name } else { $Distro = $distros[0].Name }
        }
        if (-not ($distros | Where-Object { $_.Name -eq $Distro })) {
            Fail ("distro not found: " + $Distro + " (available: " + (($distros | ForEach-Object { $_.Name }) -join ", ") + ")")
        } else {
            & wsl.exe -d $Distro -e true 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) { Ok ("using distro: " + $Distro + " (bootable)") }
            else { Fail ("distro " + $Distro + " cannot run commands: wsl -d " + $Distro + " -e true") }
        }
    }
}

# ---- 2. .wslconfig ----
Sect ".wslconfig"
$cfgPath = Join-Path $env:USERPROFILE ".wslconfig"
if (Test-Path $cfgPath) {
    $cfg = Get-Content $cfgPath -Raw
    $mem = ([regex]::Match($cfg, "(?im)^\s*memory\s*=\s*(\S+)")).Groups[1].Value
    if ($mem) { Ok (".wslconfig memory limit = " + $mem) }
    else { Warn ".wslconfig has no memory limit: WSL may take up to half of host RAM" }
    if ($cfg -match "(?im)vmIdleTimeout") {
        Warn ".wslconfig sets vmIdleTimeout - it is WSL1-only and will NOT keep WSL2 alive"
    }
} else {
    Warn "no %USERPROFILE%\.wslconfig: consider adding [wsl2] memory=8GB to cap build usage"
}

# ---- 3. host ports (shared localhost with WSL) ----
Sect "ports (planned: 2024=api 5173=frontend 5433=pg 6379=redis)"
foreach ($p in 2024, 5173, 5433, 6379) {
    $conns = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue
    if ($conns) {
        $procId = ($conns | Select-Object -First 1).OwningProcess
        $procName = (Get-Process -Id $procId -ErrorAction SilentlyContinue).ProcessName
        if ($procName -match "wslrelay|docker|com.docker") {
            Warn ("port " + $p + " is held by " + $procName + " - looks like YOUR containers are already up (run 'docker compose ps' to confirm; use docker-down before re-deploying)")
        } else {
            Warn ("Windows port " + $p + " already in use (PID " + $procId + " " + $procName + "): container cannot bind, or you are hitting a leftover process")
        }
    } else {
        Ok ("Windows port " + $p + " free")
    }
}

# ---- 4. host toolchain (reference only) ----
Sect "host toolchain (reference; builds run inside WSL)"
foreach ($t in "node", "bun", "uv", "git", "python") {
    $c = Get-Command $t -ErrorAction SilentlyContinue
    if ($c) {
        $v = ""
        try { $v = (& $t --version 2>&1 | Select-Object -First 1) } catch { }
        Ok ($t + " " + $v)
    } else {
        Warn ("host has no " + $t + " (fine if present inside WSL or handled by Docker)")
    }
}

# ---- 5. project path ----
Sect "project path"
if ([string]::IsNullOrEmpty($ProjectPath)) {
    Warn "no -ProjectPath given: skipping project-level checks and version matrix"
} elseif (-not (Test-Path $ProjectPath)) {
    Fail ("project path not found: " + $ProjectPath)
} else {
    $full = (Resolve-Path $ProjectPath).Path
    if ($full -match "^\\\\") { Warn "project on a network share: docker build context will be slow" }
    else { Ok ("project path " + $full + "  (WSL: " + (Get-WslPath $full) + ")") }

    $gitCfg = (& git -C $full config --get core.autocrlf 2>$null)
    if ($gitCfg -and $gitCfg -ne "input" -and $gitCfg -ne "false") {
        Warn ("git core.autocrlf=" + $gitCfg + ": shell scripts may become CRLF and fail in WSL with 'command not found'")
    }

    $envFile = Join-Path $full ".env"
    $envExample = Join-Path $full ".env.example"
    if (Test-Path $envFile) {
        $hasKey = Select-String -Path $envFile -Pattern "^(DEEPSEEK_API_KEY|OPENAI_API_KEY|DASHSCOPE_API_KEY)=.+" -Quiet
        if ($hasKey) { Ok ".env found with a model API key" }
        else { Warn ".env exists but no model API key (chat will report not-configured)" }
    } elseif (Test-Path $envExample) {
        Warn "no .env (copy .env.example and fill the key for Docker deployment)"
    }
}

# ---- 6. delegate to Linux side ----
Sect "Linux / WSL side"
if ($Distro) {
    $shWin = Join-Path $PSScriptRoot "preflight.sh"
    if (-not (Test-Path $shWin)) {
        Fail "preflight.sh not found next to this script"
    } else {
        $shWsl = Get-WslPath $shWin
        $projWsl = Get-WslPath $ProjectPath
        # 在项目目录（或脚本目录）落一份 UTF-8 报告，再从 Windows 读，避免控制台编码问题
        $outDir = $PSScriptRoot
        if (-not [string]::IsNullOrEmpty($ProjectPath) -and (Test-Path $ProjectPath)) { $outDir = (Resolve-Path $ProjectPath).Path }
        $outWin = Join-Path $outDir ".preflight-report.txt"
        $outWsl = Get-WslPath $outWin
        $mode = "--json"   # 始终走 JSON 协议，由本脚本统一渲染（人读/机器读两种）
        $bs = [char]92
        $cmd = "tr -d '" + $bs + "r' < '" + $shWsl + "' > /tmp/pf.sh && bash /tmp/pf.sh '" + $projWsl + "' '" + $mode + "' > '" + $outWsl + "' 2>&1"
        & wsl.exe -d $Distro -e bash -lc $cmd | Out-Null

        if (-not (Test-Path $outWin)) {
            Fail "Linux-side check produced no report (wsl exec failed?)"
        } else {
            $lines = Get-Content -LiteralPath $outWin -Encoding UTF8
            Remove-Item -LiteralPath $outWin -Force -ErrorAction SilentlyContinue
            foreach ($line in $lines) {
                $s2 = ([string]$line).TrimEnd()
                if ($s2 -match "^(OK|WARN|FAIL)\|") {
                    $parts = $s2.Split("|", 2)
                    switch ($parts[0]) {
                        "OK"   { Ok $parts[1] }
                        "WARN" { Warn $parts[1] }
                        "FAIL" { Fail $parts[1] }
                    }
                } elseif ($s2 -match "^SUMMARY\|") {
                    # Linux 侧的小计，已并入本脚本统计，忽略
                } elseif ($s2 -match "^META\|") {
                    if (-not $Json) { Write-Host ""; Write-Host $s2.Substring(5) -ForegroundColor Cyan }
                } else {
                    if (-not $Json) { Write-Host $s2 }
                }
            }
        }
    }
}

# ---- 7. summary ----
if (-not $Json) {
    Write-Host ""
    Write-Host "==== summary ====" -ForegroundColor White
    Write-Host ("  OK={0}  WARN={1}  FAIL={2}" -f $script:pass, $script:warn, $script:fail)
    if ($script:fail -gt 0) {
        Write-Host "  Blocking failures found: fix the FAIL items above before starting." -ForegroundColor Red
    } elseif ($script:warn -gt 0) {
        Write-Host "  Usable, with advisories (versions / resources / mirrors)." -ForegroundColor Yellow
    } else {
        Write-Host "  Environment ready." -ForegroundColor Green
    }
    Write-Host ""
    Write-Host "  Next: use the agent-init skill to scaffold the project."
} else {
    ("{0}|{1}|{2}" -f $script:pass, $script:warn, $script:fail)
}

if ($script:fail -gt 0) { exit 1 } else { exit 0 }
