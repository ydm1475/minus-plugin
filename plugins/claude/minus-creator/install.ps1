# Minus Creator Plugin 安装脚本 (Windows / PowerShell)
# 用法: powershell -ExecutionPolicy Bypass -File install.ps1
#   （从网上下载的 .ps1 默认被 ExecutionPolicy / MoTW 拦截，必须加 -ExecutionPolicy Bypass，
#     或先对文件 Unblock-File 再运行。）
# 对应 install.sh 的 Windows 版本，固化了 marketplace remove->add 规避逻辑。

$ErrorActionPreference = 'Stop'
# PS 7.4+ 默认 $PSNativeCommandUseErrorActionPreference=$true：Stop 模式下原生命令(claude.cmd)
# 非零退出会直接抛异常，绕过下面手动的 $LASTEXITCODE 检查。关掉它，改由 $LASTEXITCODE 控制流程。
# （此变量在 Windows PowerShell 5.1 不存在，赋值只是创建普通变量，无副作用。）
$PSNativeCommandUseErrorActionPreference = $false

# 脚本所在目录；marketplace 根目录是 minus-creator 的父级（marketplace.json 所在处）
$ScriptDir       = $PSScriptRoot
$MarketplaceDir  = Split-Path $ScriptDir -Parent
$PluginName      = 'minus-creator'
$MarketplaceName = 'minus-plugin'
$PluginId        = "$PluginName@$MarketplaceName"
$NodeFloor       = 24   # 对外推荐：Node 24
$NodeMin         = 18   # 技术硬下限：MCP server 用到 global fetch，需 Node 18

function Write-Ok   ($m) { Write-Host "[OK] $m"   -ForegroundColor Green }
function Write-Step ($m) { Write-Host "`n-> $m" }
function Write-Err  ($m) { Write-Host "[X] $m"    -ForegroundColor Red }

# 查询插件状态：返回 enabled / disabled / missing（用 PowerShell 原生 JSON 解析，不依赖 node）
function Get-PluginState {
  try {
    $json = & claude plugin list --json 2>$null | Out-String
    if (-not $json.Trim()) { return 'missing' }
    $arr = $json | ConvertFrom-Json
    $p = $arr | Where-Object { $_.id -eq $PluginId } | Select-Object -First 1
    if (-not $p)    { return 'missing' }
    if ($p.enabled) { return 'enabled' }
    return 'disabled'
  } catch { return 'missing' }
}

function Get-NodeMajor {
  if (-not (Get-Command node -ErrorAction SilentlyContinue)) { return $null }
  try { return [int](node -p "process.versions.node.split('.')[0]" 2>$null) }
  catch { return $null }
}

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

# 2. Node 版本 gate（建议 Node 24，硬下限 18）
#    Windows 上 winget 安装的 node 不会进入当前会话 PATH，必须重开终端再跑本脚本。
Write-Step "检查 Node 版本（建议 Node $NodeFloor）..."
$nmaj = Get-NodeMajor
if ($null -eq $nmaj -or $nmaj -lt $NodeMin) {
  if ($null -eq $nmaj) {
    Write-Host "  未检测到 Node.js，需要 Node $NodeFloor（最低 $NodeMin）。"
  } else {
    Write-Host "  当前 Node v$nmaj 过旧，需要升级到 Node $NodeFloor（最低 $NodeMin）。"
  }
  if (Get-Command winget -ErrorAction SilentlyContinue) {
    $ans = Read-Host "  是否现在用 winget 安装 Node $NodeFloor LTS？[Y/n]"
    if ($ans -match '^[Nn]') {
      Write-Err "已取消。请自行安装 Node $NodeFloor（最低 $NodeMin）后重跑 install.ps1。"
      exit 1
    }
    Write-Host "  正在通过 winget 安装 Node.js LTS..."
    & winget install --id OpenJS.NodeJS.LTS -e --accept-source-agreements --accept-package-agreements
    Write-Host ""
    Write-Ok "Node 安装命令已执行。"
    Write-Host "  请关闭并重新打开 PowerShell（让 PATH 生效），然后重新运行 install.ps1。" -ForegroundColor Yellow
    exit 0
  } else {
    Write-Err "未检测到 winget。请手动安装 Node $NodeFloor（最低 $NodeMin）："
    Write-Host "  https://nodejs.org/  （下载 LTS 安装包）"
    Write-Host "  安装后重开 PowerShell 再运行 install.ps1。"
    exit 1
  }
} elseif ($nmaj -lt $NodeFloor) {
  Write-Ok "Node v$nmaj 可用；建议升级到 Node $NodeFloor 以获得最佳体验。"
} else {
  Write-Ok "Node 已就绪（v$nmaj）"
}

# 2.5 自迁移：把 marketplace 根目录固化到稳定家目录，绝不从临时/下载目录注册。
#     根因：directory-source marketplace 存的是对该路径的实时引用，每次启动都去读；
#     源目录一旦被删/移动（如 Agent 清理解压临时目录），就 cache-miss，/minus 消失。
#     把"目录必须持久"从口头契约变成代码保证（对齐设计原则 #1：能硬编码的别靠 Agent 自觉）。
$StableHome = Join-Path $env:USERPROFILE '.claude\minus-creator-marketplace'
$srcResolved = (Resolve-Path $MarketplaceDir).Path.TrimEnd('\')
if ($srcResolved -ine $StableHome.TrimEnd('\')) {
  Write-Step "固化 marketplace 到稳定目录：$StableHome"
  # robocopy /MIR 镜像，排除 node_modules/.git；退出码 <8 都算成功（1=有文件被复制）
  robocopy $MarketplaceDir $StableHome /MIR /XD node_modules .git /NFL /NDL /NJH /NJS /NP | Out-Null
  if ($LASTEXITCODE -ge 8) { Write-Err "固化失败（robocopy 退出码 $LASTEXITCODE）。"; exit 1 }
  $global:LASTEXITCODE = 0   # robocopy 的非零成功码会污染后续 $LASTEXITCODE 判断
  $MarketplaceDir = $StableHome
  Write-Ok "已固化到 $StableHome"
}

# 3. 注册 marketplace —— 固化 remove->add 规避逻辑
#    已知坑：单纯 add 在某些情况下报"成功"但后续 install 找不到 marketplace。
#    先 remove（忽略"不存在"错误）再 add，强制刷新到可用列表。
#    重指：机器上若残留指向已死临时目录的旧注册，remove->add 会重新指向上面的稳定目录，自愈。
Write-Step "注册 marketplace（remove->add 强制重指稳定目录）..."
try { & claude plugin marketplace remove $MarketplaceName 2>$null | Out-Null } catch {}
& claude plugin marketplace add "$MarketplaceDir"
if ($LASTEXITCODE -ne 0) {
  Write-Err "marketplace 注册失败，来源目录：$MarketplaceDir"
  exit 1
}
# 校验确实进了列表
$mlist = (& claude plugin marketplace list 2>$null | Out-String)
if ($mlist -notmatch [regex]::Escape($MarketplaceName)) {
  Write-Err "marketplace 注册后未出现在列表中（来源：$MarketplaceDir）。"
  exit 1
}
Write-Ok "Marketplace 注册成功"

# 4. 安装并启用插件（区分 未装 / 已装未启用 / 已启用）
Write-Step "安装插件..."
switch (Get-PluginState) {
  'enabled'  { Write-Ok "插件已安装并启用" }
  'disabled' {
    Write-Host "  插件已安装但未启用，启用中..."
    & claude plugin enable $PluginId
    if ($LASTEXITCODE -ne 0) { Write-Err "启用插件失败。"; exit 1 }
    Write-Ok "插件已启用"
  }
  default {
    # 装前清残留缓存：claude plugin install 先把插件解到 temp_local_* 暂存目录，再
    # rename 成 cache\<mp>\<plugin>\<ver>。Windows 上 fs.rename 无法覆盖已存在的非空
    # 目标目录 → 撞到上次失败/旧版的残留就 EPERM（mac 的 rename 语义不同，不复现）。
    # 清掉残留暂存目录 + 本插件 cache 目标，保证 rename 有干净落点（原则 #1：别靠 agent 手动清）。
    $cacheRoot = Join-Path $env:USERPROFILE '.claude\plugins\cache'
    if (Test-Path $cacheRoot) {
      Get-ChildItem -Path $cacheRoot -Filter 'temp_local_*' -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-Item -Recurse -Force $_.FullName -ErrorAction SilentlyContinue }
      $pluginCache = Join-Path $cacheRoot (Join-Path $MarketplaceName $PluginName)
      if (Test-Path $pluginCache) { Remove-Item -Recurse -Force $pluginCache -ErrorAction SilentlyContinue }
    }
    & claude plugin install $PluginId
    if ($LASTEXITCODE -ne 0) { Write-Err "安装插件失败。"; exit 1 }
    Write-Ok "插件安装成功"
  }
}

# 5. 校验 MCP Server 产物（自包含 bundle，无需 npm install）
Write-Step "校验 MCP Server 产物..."
$installPath = ''
try {
  $arr = (& claude plugin list --json 2>$null | Out-String) | ConvertFrom-Json
  $p = $arr | Where-Object { $_.id -eq $PluginId } | Select-Object -First 1
  if ($p) { $installPath = $p.installPath }
} catch {}
$mcpDir = Join-Path $installPath 'mcp-servers\minus-platform'
$bundle = Join-Path $mcpDir 'dist\minus-platform.cjs'
$launch = Join-Path $mcpDir 'launch.cjs'
if (-not $installPath -or -not (Test-Path $bundle)) {
  Write-Err "未找到 MCP Server 产物 dist/minus-platform.cjs（installPath=[$installPath]）。MCP 是必需项，安装中止。"
  exit 1
}
if (-not (Test-Path $launch)) {
  Write-Err "未找到 MCP launcher（$launch）。MCP 是必需项，安装中止。"
  exit 1
}
Write-Ok "MCP Server 产物就绪"

# 6. 校验：插件是否真的被启用（凭实际状态，不凭"没报错"）
Write-Step "校验安装结果..."
$state = Get-PluginState
if ($state -ne 'enabled') {
  Write-Err "校验失败：$PluginId 当前状态为 [$state]，未处于 enabled。"
  Write-Host "   marketplace 来源目录：$MarketplaceDir"
  exit 1
}
Write-Ok "已确认插件安装并启用（enabled）"

# 7. 完成
Write-Host ""
Write-Host "======================================"
Write-Host "安装完成！" -ForegroundColor Green
Write-Host ""
Write-Host "使用方法："
Write-Host "  1. 重启 Claude Code 会话"
Write-Host "  2. 输入 /minus 开始开发 Skill"
Write-Host "======================================"
Write-Host ""
