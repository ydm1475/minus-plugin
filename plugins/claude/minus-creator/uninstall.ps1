# uninstall.ps1
# 卸载 Minus Creator Plugin 并清理所有缓存（Windows 版，对应 uninstall.sh）
# 用法: powershell -ExecutionPolicy Bypass -File uninstall.ps1

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

function Write-Ok  ($msg) { Write-Host "✓ $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "⚠ $msg" -ForegroundColor Yellow }

$Home_ = $env:USERPROFILE

Write-Host "Minus Creator Plugin 卸载工具"
Write-Host ""

# 1. 卸载插件（通过 CLI）
Write-Host "→ 卸载插件..."
try {
  claude plugin uninstall minus-creator@minus-plugin 2>$null | Out-Null
  if ($LASTEXITCODE -eq 0) { Write-Ok "插件已卸载" }
  else { Write-Warn "插件未安装或已卸载" }
} catch { Write-Warn "插件未安装或已卸载" }

# 2. 清理插件缓存（cache + data）
Write-Host "→ 清理缓存..."
Remove-Item -Recurse -Force "$Home_\.claude\plugins\cache\minus-plugin" -ErrorAction SilentlyContinue
Get-ChildItem -Path "$Home_\.claude\plugins\data" -Filter "minus-creator*" -Directory -ErrorAction SilentlyContinue |
  ForEach-Object { Remove-Item -Recurse -Force $_.FullName -ErrorAction SilentlyContinue }
Write-Ok "缓存已清理"

# 3. 移除 marketplace 注册
Write-Host "→ 移除 marketplace 注册..."
$mpRemoved = $false
if (Get-Command claude -ErrorAction SilentlyContinue) {
  try {
    claude plugin marketplace remove minus-plugin 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { $mpRemoved = $true }
  } catch {}
}
if (-not $mpRemoved) {
  $kmFile = "$Home_\.claude\plugins\known_marketplaces.json"
  if (Test-Path $kmFile) {
    try {
      $d = Get-Content $kmFile -Raw | ConvertFrom-Json
      if ($d.PSObject.Properties['minus-plugin']) {
        $d.PSObject.Properties.Remove('minus-plugin')
        $d | ConvertTo-Json -Depth 10 | Set-Content $kmFile -Encoding UTF8
        $mpRemoved = $true
      }
    } catch {}
  }
}
if ($mpRemoved) { Write-Ok "Marketplace 注册已移除" }
else { Write-Warn "Marketplace 无注册记录" }

# 4. 清理旧版 skills/agents 副本
Remove-Item -Recurse -Force "$Home_\.claude\skills\minus" -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "$Home_\.claude\skills\minus-publish" -ErrorAction SilentlyContinue
Remove-Item -Force "$Home_\.claude\agents\skill-guide.md" -ErrorAction SilentlyContinue
Remove-Item -Force "$Home_\.claude\agents\node-dev.md" -ErrorAction SilentlyContinue
Write-Ok "Skills/Agents 副本已清理"

# 5. 清理散落的插件副本 / 解压目录
Remove-Item -Recurse -Force "$Home_\.claude\minus-creator-marketplace" -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "$Home_\.claude\claude\minus-creator" -ErrorAction SilentlyContinue
if ((Test-Path "$Home_\.claude\claude") -and (Get-ChildItem "$Home_\.claude\claude" -ErrorAction SilentlyContinue).Count -eq 0) {
  Remove-Item "$Home_\.claude\claude" -ErrorAction SilentlyContinue
}
Remove-Item -Recurse -Force "$Home_\.claude\minus-installer" -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "$Home_\.minus-creator-plugin" -ErrorAction SilentlyContinue

# ~/.claude-plugins/claude/ 下的 minus 残留
Remove-Item -Recurse -Force "$Home_\.claude-plugins\claude\minus-creator" -ErrorAction SilentlyContinue
$mpJson = "$Home_\.claude-plugins\claude\.claude-plugin\marketplace.json"
if ((Test-Path $mpJson) -and (Get-Content $mpJson -Raw) -match 'minus-plugin') {
  Remove-Item -Recurse -Force "$Home_\.claude-plugins\claude\.claude-plugin" -ErrorAction SilentlyContinue
}
# 空壳目录清理
@("$Home_\.claude-plugins\claude", "$Home_\.claude-plugins") | ForEach-Object {
  if ((Test-Path $_) -and (Get-ChildItem $_ -ErrorAction SilentlyContinue).Count -eq 0) {
    Remove-Item $_ -ErrorAction SilentlyContinue
  }
}

# ~/.claude/plugins/claude/ 下的 minus 残留
Remove-Item -Recurse -Force "$Home_\.claude\plugins\claude\minus-creator" -ErrorAction SilentlyContinue
$mpJson2 = "$Home_\.claude\plugins\claude\.claude-plugin\marketplace.json"
if ((Test-Path $mpJson2) -and (Get-Content $mpJson2 -Raw) -match 'minus-plugin') {
  Remove-Item -Recurse -Force "$Home_\.claude\plugins\claude\.claude-plugin" -ErrorAction SilentlyContinue
}
if ((Test-Path "$Home_\.claude\plugins\claude") -and (Get-ChildItem "$Home_\.claude\plugins\claude" -ErrorAction SilentlyContinue).Count -eq 0) {
  Remove-Item "$Home_\.claude\plugins\claude" -ErrorAction SilentlyContinue
}
Write-Ok "散落副本/解压目录已清理"

Write-Host ""
Write-Host "卸载完成。如需同时清理登录凭证，运行: Remove-Item -Recurse -Force ~\.minus"
