---
name: env-preflight
description: 开工前的环境准备：**先装依赖再体检**。安装 Docker / Python / uv / Node / bun / git / swap（Windows 宿主 + WSL/Linux 两侧），随后做环境预检。覆盖两种宿主形态：Windows + WSL，以及原生 Linux 服务器/云主机（Ubuntu、ECS、虚拟机、容器宿主）。检查 Docker、语言工具链、端口、资源、网络、防火墙、开机自启与版本一致性矩阵。在新建 agent 项目、Docker 部署、上服务器、或遇到"环境不对/版本冲突/容器起不来/命令报错/外部访问不了"之前先跑它。触发词：装 docker、装 bun、装 uv、装 python、环境搭建、依赖安装、新机器准备、服务器初始化、环境检查、环境预检、preflight、开工前检查、部署前检查、WSL 环境、WSL 怎么配、linux 服务器部署、Ubuntu 服务器、云主机、ECS、docker 环境检查、容器起不来、版本不一致、版本冲突排查。
---

# 环境准备：依赖安装 + 预检（Windows+WSL / 原生 Linux + Docker）

`agent-init` 那套 skill 里，**一半以上的坑本质是环境问题**，不是代码问题。这个 skill 把它们收敛成一次开工前体检：

| 曾经的坑 | 根因 | 本 skill 的对应检查 |
|---|---|---|
| 官方镜像构建报 `demo-backend not satisfiable` | `pyproject.requires-python` 与 Docker 基础镜像 Python 不一致 | 版本一致性矩阵（4 方对齐） |
| 装不上 `deepagents>=1.15` | npm 与 Python 包版本号不同步（Python 侧 0.7.x） | 依赖声明 vs 实际安装（`uv pip check`） |
| 启动报 `libpq library not found` | slim 镜像没 libpq | 依赖写法提示（`psycopg[binary]`） |
| 容器起来十几秒后 `Exited (0)` | WSL 被系统收起 → dockerd 停 | WSL/systemd/保活 + `restart: unless-stopped` 认知 |
| "PG 持久化验证成功"其实是假的 | 宿主机遗留 `langgraph dev` 顶着 :2024 | 端口占用检查（识别 `wslrelay`/docker 与遗留进程） |
| shell 脚本在 WSL 报 `$'\r': command not found` | `core.autocrlf` 把 .sh 写成 CRLF | git autocrlf + 运行时 `tr -d '\r'` 兜底 |

## 两种宿主形态，同一套检查

| 形态 | 怎么跑 | 额外关注 |
|---|---|---|
| **Windows + WSL**（本机开发） | `preflight.ps1`（同时体检 Windows 与 WSL 两侧） | WSL2 版本、`.wslconfig`、**WSL 被系统收起会停掉容器**、Windows/WSL 共享 localhost 的端口占用、`/mnt/e` 是 9p 拖慢构建 |
| **原生 Linux**（服务器 / 云主机 / 虚拟机） | 直接把 `preflight.sh` 拷到机器上跑（脚本会自动识别形态） | docker 是否需要 sudo（docker 组）、`systemctl enable docker` 开机自启、**防火墙/安全组放行 2024/5173/5433**、NTP 时间同步、swap 兜底 |

脚本会**自动侦测形态**（`/proc/version` 含 microsoft 或存在 `WSL_DISTRO_NAME` → WSL），只在对应形态下跑专属检查；想预览另一种形态：`PF_FORCE_PLATFORM=Linux bash preflight.sh /path/to/project`。

## 何时用 / 不用

用：
- **新机器 / 新服务器 / 新 WSL 发行版首次准备**（先 `install-deps`，再 `preflight`）
- **新建任何 agent 项目之前**（`agent-init` 的"第 0 步"）
- **Docker 部署之前**（`docker-up.ps1` 之前）
- 环境类报错排查：容器起不来、WSL 命令诡异报错、版本冲突、端口被占、网络拉不动依赖

不用（边界说明）：
- `preflight.sh` / `preflight.ps1` **永远只读**：只体检、给修复命令，不替你改系统
- `install-deps.sh` / `install-deps.ps1` 会装东西，但**默认 dry-run**，必须显式 `--yes` / `-Apply`
- 两者都不跑项目测试、不动项目代码

## 怎么装（依赖安装）

两个脚本，**默认 dry-run**（只打印将执行的命令），确认无误再加参数真正安装；已装的自动跳过，可反复执行。

```powershell
# Windows 宿主：git / uv / bun / node / python（winget + 官方脚本，默认只预览）
powershell -ExecutionPolicy Bypass -File .\scripts\install-deps.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\install-deps.ps1 -Apply
powershell -ExecutionPolicy Bypass -File .\scripts\install-deps.ps1 -Apply -WithNode
```

```bash
# WSL / Linux：Docker + compose v2 + python3 + uv + git（+ 可选 bun/node/swap）
bash scripts/install-deps.sh                                  # 预览
bash scripts/install-deps.sh --yes                            # 真正安装（会用到 sudo）
bash scripts/install-deps.sh --yes --with-bun --with-node      # 额外装 bun / Node 22
bash scripts/install-deps.sh --yes --swap 2048                 # 额外加 2G swap（构建兜底）
```

| 装什么 | Windows 宿主（install-deps.ps1） | WSL / Linux（install-deps.sh） |
|---|---|---|
| git | winget `Git.Git` | 包管理器（apt/dnf/yum/pacman/apk 自动识别） |
| Python | winget `Python.Python.3.12`（仅本地 venv 用） | `python3` + `venv` + `pip` |
| **uv** | 官方脚本 `astral.sh/uv/install.ps1` | 官方脚本 `astral.sh/uv/install.sh`（装到 `~/.local/bin`） |
| **Docker** | —（构建在 WSL 里跑；也可装 Docker Desktop） | `docker.io` + `docker-compose-v2`，并 `systemctl enable --now docker`、用户加入 `docker` 组 |
| **bun** | 官方脚本 `bun.sh/install.ps1` | `--with-bun` 时 `bun.sh/install`（装到 `~/.bun/bin`） |
| Node | `-WithNode` 时 winget LTS | `--with-node` 时 NodeSource 22.x |
| swap | 不适用 | `--swap N` 建 swapfile 并写入 fstab |

安装后的收尾（脚本会提示，部分需重新登录生效）：

| 场景 | 命令 |
|---|---|
| 加入 docker 组后免 sudo | `newgrp docker` 或重新登录 |
| uv / bun 装到用户目录后找不到命令 | 确保 PATH 含 `~/.local/bin`、`~/.bun/bin`（`source ~/.bashrc`） |
| 发行版仓库 docker 版本过旧 | `curl -fsSL https://get.docker.com | sh` |

> 只读边界：`preflight.sh/ps1` **永远只读**；只有 `install-deps.*` 会改系统，且必须显式加 `--yes` / `-Apply`。

## 怎么跑

```powershell
# Windows 宿主：一条命令同时体检 Windows 与 WSL 两侧，并做项目级版本一致性检查
powershell -ExecutionPolicy Bypass -File .\scripts\preflight.ps1 -ProjectPath E:\agent-skills\demo

# 只体检宿主，不检查具体项目
powershell -ExecutionPolicy Bypass -File .\scripts\preflight.ps1

# 指定发行版
powershell -ExecutionPolicy Bypass -File .\scripts\preflight.ps1 -Distro Ubuntu -ProjectPath E:\path\to\proj

# 机器可读（输出 OK=.. WARN=.. FAIL=.. 的汇总行，便于 CI/脚本判断）
powershell -ExecutionPolicy Bypass -File .\scripts\preflight.ps1 -Json
```

**原生 Linux（服务器/云主机）**：把 `scripts/preflight.sh` 放到机器上直接跑即可（无需 PowerShell），它会自己识别为 Linux 形态并做服务器专属检查：

```bash
bash preflight.sh /opt/agent-demo                 # 人读输出
bash preflight.sh /opt/agent-demo --json          # 协议输出（OK|/WARN|/FAIL|/META|/SUMMARY|）
PF_FORCE_PLATFORM=Linux bash preflight.sh /path   # 强制按 Linux 形态检查（如在 WSL 里预览）
```

WSL 内也能直接跑这半边（此时形态=WSL，跳过 Linux 专属项）：

```bash
bash scripts/preflight.sh /mnt/e/path/to/project
```

**退出码**：`0` = 无必须项失败；`1` = 存在 `FAIL`（必须先修）。

## 检查项清单

### 宿主 Windows 侧

| 检查 | 为什么 | 命中时怎么办 |
|---|---|---|
| `wsl.exe` 存在、发行版列表与 `WSL2` | Docker/Linux 构建全依赖 WSL2 | `wsl --install -d Ubuntu`；版本不对 `wsl --set-version Ubuntu 2` |
| 发行版可启动（`wsl -d X -e true`） | 有些发行版状态坏掉无法执行命令 | `wsl --shutdown` 后重试 |
| `.wslconfig` 内存与 `vmIdleTimeout` | 构建峰值吃内存；`vmIdleTimeout` 是 WSL1 遗留键，**对 WSL2 无效** | 需要限内存写 `[wsl2] memory=8GB`；保活要靠会话或 `restart` 策略 |
| 端口 2024 / 5173 / 5433 / 6379 | 与 WSL 共享 localhost，冲突则容器起不来或你打到了遗留进程 | 先 `docker-down.ps1`；再找占用 PID 处理 |
| 项目路径与 WSL 映射 | 构建上下文路径、文件权限、性能 | 放本地盘（非网络盘）；WSL 视角是 `/mnt/<盘符小写>/...` |
| `git core.autocrlf` | `.sh` 被转成 CRLF 会在 WSL 报 `$'\r': command not found` | `git config core.autocrlf input`（脚本已内置 `tr -d '\r'` 兜底） |
| `.env` 里有没有模型密钥 | 没有就只能在 UI 里填/或对话直接提示未配置 | 复制 `.env.example` 填 `DEEPSEEK_API_KEY` |

### 公共部分（WSL 与原生 Linux 都查）

| 检查 | 为什么 | 命中时怎么办 |
|---|---|---|
| 发行版版本、内核、架构 | 过老的发行版工具链版本偏低 | 22.04+ / Debian 12+ |
| PID 1 是否 `systemd` | Docker 服务托管与开机自启都靠它 | 非 systemd 时手动 `sudo service docker start` |
| `python3` / `uv` | venv 由 uv 创建（可自带版本，系统 Python 版本不重要） | 装 uv：`curl -LsSf https://astral.sh/uv/install.sh \| sh` |
| `node` / `bun` | 仅"在 WSL 里直接构建前端"时需要；**Docker 构建不需要**（镜像自带 bun） | 按需装；或用 Docker 构建 |
| `docker` CLI + **守护进程存活** + `compose v2` | 守护进程不在，容器/构建全失败 | `sudo service docker start` 或 `sudo systemctl start docker` |
| 端口占用（WSL 内） | 同上 | 同上 |
| CPU / 内存 / 磁盘 | 镜像 + 构建层 + 4 个容器，建议 ≥8G 内存、≥8G 空闲盘 | `.wslconfig` 调内存；清 `docker system prune` |
| 网络：PyPI / npm registry / Docker Hub | 拉依赖与镜像 | 配镜像源（pip index-url、npm registry、docker registry-mirrors） |
| locale / UTF-8 | 中文 Windows 下 Python 读写中文文件易 `UnicodeDecodeError` | 启动命令前加 `PYTHONUTF8=1` |
| 项目所在文件系统 | `9p`（WSL 挂 Windows 盘）/ NFS / CIFS 会显著拖慢 Docker 构建与热重载 | 追求速度把项目放本机盘 / WSL 内部盘 |

### 原生 Linux 专属（服务器场景）

| 检查 | 为什么 | 命中时怎么办 |
|---|---|---|
| `docker` 组 / root | 不在 docker 组时每条 docker 命令都要 sudo，`docker-up` 脚本会失败 | `sudo usermod -aG docker $USER && newgrp docker`（重新登录） |
| `systemctl is-enabled docker` | 服务器重启后容器要自己回来 | `sudo systemctl enable docker` |
| **防火墙 ufw / firewalld** | 容器发布了端口，被防火墙挡住一样访问不了 | `sudo ufw allow 2024/tcp`（5173/5433 同理）或 `firewall-cmd --permanent --add-port=2024/tcp && firewall-cmd --reload` |
| **云安全组** | 云主机还有一层安全组，脚本查不到 | 控制台放行 2024 / 5173（5433 视需要） |
| NTP 时间同步 | checkpoint 时间戳、TLS、令牌都依赖准确时间 | `sudo timedatectl set-ntp true` |
| swap | 构建峰值（前端/镜像层）可能 OOM | 加 2–4G swapfile |
| 本机 IP | 告知从哪个地址访问 | 结合安全组/防火墙确认 |

### 项目级：版本一致性矩阵（最关键）

```
langgraph.json  python_version  ──┐
pyproject.toml  requires-python ──┼── 必须相容，否则 Docker 官方镜像构建直接 not satisfiable
backend/.venv   python 版本     ──┤
Docker 基础镜像 Python 版本     ──┘   （由 python_version 决定，如 langchain/langgraph-api:3.12）

frontend/package.json engines  ──── 实际 node/bun 版本
langgraph.json graphs 键名     ──── 前端 assistantId 必须一致
```

脚本会打印这四项的实际取值并比对，还会跑 `uv pip check` 检查已安装依赖之间是否冲突。

## 端口规划约定（避免与宿主冲突）

| 端口 | 用途 | 谁监听 |
|---|---|---|
| 2024 | 后端 API（容器内 8000 → 宿主 2024） | `langgraph-api` 容器 |
| 5173 | 前端（容器内 80 → 宿主 5173） | `frontend`(nginx) 容器 |
| 5433 | PostgreSQL（容器内 5432） | `postgres` 容器（便于直连查数据） |
| 6379 | Redis | 仅容器网络内，不对外映射 |

> 从 Windows 排查端口时注意：容器映射过来的端口在宿主显示为 `wslrelay` 占用——**那不是冲突，是你的栈在跑**。

## 与其它 skill 的配合

```
env-preflight ① install-deps（第 0 步：装依赖：docker/python/uv/bun/git）
   ↓
env-preflight ② preflight（体检：端口/资源/网络/版本一致性）
   ↓ 全绿
agent-init（第 1 步：项目骨架 / 代码约定 / 踩坑表）
   ↓ 需要持久化
Docker 部署（第 2 步：docker-up.ps1 → Postgres 落数据；见 agent-init 第五章）
```

`agent-init` 的坑表里属于"环境/版本"类的条目，本质上都可以由本 skill 提前拦掉；新增坑时先判断它属于哪一类。

## 常见 FAIL 速修

| FAIL 文案 | 修复 |
|---|---|
| `docker 守护进程未运行` | `wsl -d Ubuntu -e bash -lc "sudo service docker start"` |
| `WSL 里没有 docker` / `缺少 docker compose v2` | 装 Docker Desktop 并打开 WSL 集成，或 `sudo apt install docker.io docker-compose-v2` |
| `distro X = WSL1: Docker needs WSL2` | `wsl --set-version X 2` |
| `requires-python 与 python_version 可能冲突` | 对齐两处（推荐都写 3.12），改完 `langgraph dockerfile Dockerfile` 重新生成 |
| `端口 X 被占用（非 wslrelay）` | `Get-NetTCPConnection -LocalPort X` 找 PID → 处理遗留进程（本地 dev 服务用 `restart-backend.ps1` 清） |
| `locale 非 UTF-8` | 启动命令加 `PYTHONUTF8=1` |
| `当前用户不在 docker 组` | `sudo usermod -aG docker $USER && newgrp docker`，重新登录 |
| `docker 未设开机自启` | `sudo systemctl enable docker` |
| `ufw 已启用但未见放行 2024` | `sudo ufw allow 2024/tcp`（5173/5433 同理） |
| `firewalld 运行中但未放行 2024` | `sudo firewall-cmd --permanent --add-port=2024/tcp && sudo firewall-cmd --reload` |
| `系统时间未同步` | `sudo timedatectl set-ntp true` |
| `无 swap` | 加 2–4G swapfile（`fallocate` + `mkswap` + `swapon`），构建时兜底 |
| `项目在 9p / 网络文件系统` | 把项目移到本机盘或 WSL 内部盘（`~/proj`）再构建 |
| `uv pip check 有冲突` | `cd backend && uv pip check` 看具体包，按 deepagents/langchain 兼容区间收紧依赖 |

## 脚本自身的编码约定（改脚本时必看）

Windows + WSL 混合环境下，脚本文件本身最容易出问题：

| 文件 | 必须是 | 原因 |
|---|---|---|
| `preflight.sh` | **LF**（无 CRLF） | CRLF 会让 bash 报 `$'\r': command not found`（PS1 已内置 `tr -d '\r'` 兜底） |
| `preflight.ps1` / `install-deps.ps1` | **UTF-8 with BOM** | Windows PowerShell 5.1 读无 BOM 的 UTF-8 会把中文当 ANSI，出现乱码/解析错 |
| `install-deps.sh` | **LF**（无 CRLF） | 同上，CRLF 会让 bash 报 command not found |

其他实现要点（都是踩过的）：
- **`wsl.exe -l -v` 输出是 UTF-16**，解析极易出错 → 发行版列表改读注册表 `HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss`
- **WSL 侧报告写文件再按 UTF-8 读**，不要直接把 `wsl.exe` 输出接进 PowerShell 管道（控制台编码会毁掉中文）
- 两侧用 **`OK|/WARN|/FAIL|/META|/SUMMARY|` 协议行**通信，由 PS1 统一渲染，避免乱码与计数丢失
- PowerShell 里避免反引号与框线字符（`═`）出现在字符串里，容易触发解析错误

## 已验证的健康样例（对照基线）

**Windows + WSL 形态**（本机实测）：

```
Windows: node v24.13.0 / bun 1.4.1 / uv 0.10.5 / git 2.53 / python 3.12.4
WSL:     Ubuntu 26.04 LTS / systemd / kernel 6.6.x-microsoft-standard-WSL2 / 16 核 / 7.7G / swap 2G
         docker 29.8.0 + compose v5.5.1（守护进程存活）/ uv 0.12.10
         NTP 已同步 / 运行形态自动识别为 WSL
项目:    python_version=3.12 ↔ requires-python>=3.12 ↔ 镜像 3.12（一致）
         .env 有密钥 / docker-compose.yml 存在 / 项目在 9p（构建偏慢，属预期）
最终:    OK=30  WARN=12  FAIL=0
安装脚本: install-deps.ps1 预览 -> 5 项已满足 / 0 待执行（幂等）
          install-deps.sh  预览 -> 8 项已满足 / 0 待执行（幂等）
```

**原生 Linux 形态**（在同一台机器的 WSL 里用 `PF_FORCE_PLATFORM=Linux` 预览到的检查项）：

```
OK|当前用户在 docker 组（docker 无需 sudo）
OK|docker 已设置开机自启（systemctl is-enabled = enabled）
OK|未检测到 ufw/firewalld（云主机请确认安全组放行 2024/5173/5433）
OK|系统时间已同步（NTP）
OK|swap 2048Mi（构建峰值有兜底）
OK|本机地址：172.25.166.97 …（确认从外部访问用的是哪个）
```
