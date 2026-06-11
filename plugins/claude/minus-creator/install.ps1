# Minus Creator Plugin 安装引导 (Windows / PowerShell)
# 用法: powershell -ExecutionPolicy Bypass -File install.ps1
#   （从网上下载的 .ps1 默认被 ExecutionPolicy / MoTW 拦截，必须加 -ExecutionPolicy Bypass，
#     或先对文件 Unblock-File 再运行。）
#
# 本脚本是「引导薄壳」：只做 PowerShell 才能做的事（检测 claude CLI、
# 引导安装 Git Bash / Node），随后把安装逻辑整体委托给 install.sh ——
# 安装逻辑的唯一权威实现（单源化：同一规则只定义一次）。
# Claude Code 在 Windows 上本就依赖 Git Bash 跑插件 hooks，没有它插件装上也无法工作，
# 所以"确保 bash 存在"本身就是安装的必要前置，而非额外负担。

$ErrorActionPreference = 'Stop'
# PS 7.4+ 默认 $PSNativeCommandUseErrorActionPreference=$true：Stop 模式下原生命令
# 非零退出会直接抛异常，绕过手动的 $LASTEXITCODE 检查。关掉，改由 $LASTEXITCODE 控制。
$PSNativeCommandUseErrorActionPreference = $false

$ScriptDir = $PSScriptRoot

function Write-Ok   ($m) { Write-Host "[OK] $m"   -ForegroundColor Green }
function Write-Step ($m) { Write-Host "`n-> $m" }
function Write-Err  ($m) { Write-Host "[X] $m"    -ForegroundColor Red }

Write-Host ""
Write-Host "+======================================+"
Write-Host "|   Minus Creator Plugin Installer     |"
Write-Host "+======================================+"

# 1. 检测 Claude Code CLI
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
  Write-Err "未检测到 Claude Code CLI，请先安装。"
  exit 1
}
$cliVer = (& claude --version 2>$null) -join ' '
Write-Ok "检测到 Claude Code: $cliVer"

# 2. 确保 Git Bash 存在（install.sh 与插件 hooks 都跑在它上面）
#    非交互：用户多为非程序员，缺了直接用 winget 自动装，不询问（可逆、用户级安装）。
Write-Step "检查 Git Bash..."
$bashCandidates = @(
  (Get-Command bash -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue),
  "$env:ProgramFiles\Git\bin\bash.exe",
  "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
  "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe"
) | Where-Object { $_ -and (Test-Path $_) }
$bash = $bashCandidates | Select-Object -First 1

if (-not $bash) {
  if (Get-Command winget -ErrorAction SilentlyContinue) {
    Write-Host "  未检测到 Git Bash，正在通过 winget 自动安装 Git for Windows..."
    & winget install --id Git.Git -e --accept-source-agreements --accept-package-agreements
    # winget 装完不进当前会话 PATH，按已知安装位置直接找
    $bash = @(
      "$env:ProgramFiles\Git\bin\bash.exe",
      "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
      "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $bash) {
      Write-Err "Git for Windows 安装后仍未找到 bash.exe。请关闭并重新打开 PowerShell 后重跑 install.ps1。"
      exit 1
    }
    Write-Ok "Git Bash 已就绪（$bash）"
  } else {
    Write-Err "未检测到 Git Bash 且无 winget。请安装 Git for Windows（https://git-scm.com/download/win）后重跑 install.ps1。"
    exit 1
  }
} else {
  Write-Ok "Git Bash 已就绪（$bash）"
}

# 3. Node 引导（仅兜「彻底没有 node」：winget 是 Windows 原生路径；
#    版本过旧的升级交给 install.sh 的 Volta 自动配给，版本下限单源在 toolchain.sh）
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
  Write-Step "未检测到 Node.js，正在通过 winget 自动安装 Node LTS..."
  if (Get-Command winget -ErrorAction SilentlyContinue) {
    & winget install --id OpenJS.NodeJS.LTS -e --accept-source-agreements --accept-package-agreements
    Write-Ok "Node 安装命令已执行。"
    Write-Host "  请关闭并重新打开 PowerShell（让 PATH 生效），然后重新运行 install.ps1。" -ForegroundColor Yellow
    exit 0
  }
  # 无 winget 也不中止：install.sh 的 Volta 配给可在 Git Bash 内兜底
  Write-Host "  无 winget，交由安装脚本自动配给（Volta）。"
}

# 4. 委托 install.sh —— 安装逻辑唯一权威（固化目录/注册/安装/校验全在里面）
Write-Step "执行安装（install.sh）..."
$installSh = Join-Path $ScriptDir 'install.sh'
if (-not (Test-Path $installSh)) {
  Write-Err "未找到 $installSh。安装包不完整，请重新获取。"
  exit 1
}
# Git Bash 能直接吃 Windows 路径（自动转 /c/...）
& $bash $installSh
exit $LASTEXITCODE
