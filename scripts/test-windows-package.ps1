$ErrorActionPreference = 'Stop'

function Assert-True {
  param(
    [Parameter(Mandatory = $true)]
    [bool]$Condition,
    [Parameter(Mandatory = $true)]
    [string]$Message
  )

  if (-not $Condition) {
    throw $Message
  }
}

function New-PackageFixture {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SourceRoot,
    [Parameter(Mandatory = $true)]
    [string]$Version
  )

  New-Item -ItemType Directory -Force -Path `
    (Join-Path $SourceRoot 'web'), (Join-Path $SourceRoot 'licenses') | Out-Null
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'windows-package\Install-Qiyu.ps1') `
    -Destination $SourceRoot
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'windows-package\Uninstall-Qiyu.ps1') `
    -Destination $SourceRoot
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'windows-package\uninstall.cmd') `
    -Destination $SourceRoot
  [IO.File]::WriteAllBytes(
    (Join-Path $SourceRoot 'qiyu_windows_host.exe'),
    [byte[]](0x4d, 0x5a, 0x00, 0x00)
  )
  [IO.File]::WriteAllText(
    (Join-Path $SourceRoot 'web\index.html'),
    "<html><body>$Version</body></html>",
    [Text.UTF8Encoding]::new($false)
  )
  [IO.File]::WriteAllText(
    (Join-Path $SourceRoot 'persona-constitution.md'),
    '# test fixture',
    [Text.UTF8Encoding]::new($false)
  )
  [IO.File]::WriteAllText(
    (Join-Path $SourceRoot 'licenses\THIRD_PARTY_NOTICES.txt'),
    'test fixture',
    [Text.UTF8Encoding]::new($false)
  )
  [IO.File]::WriteAllText(
    (Join-Path $SourceRoot 'release.json'),
    (@{ version = $Version; architecture = 'x64' } | ConvertTo-Json),
    [Text.UTF8Encoding]::new($false)
  )
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) `
  "qiyu-ticket25-package-test-$PID"
$sourceRoot = Join-Path $testRoot 'source'
$installRoot = Join-Path $testRoot 'installed\Qiyu'
$memoryRoot = Join-Path $testRoot 'profile\.qiyu'
$runtimeRoot = Join-Path $testRoot 'local-app-data\Qiyu'
$startMenuRoot = Join-Path $testRoot 'start-menu'
$desktopRoot = Join-Path $testRoot 'desktop'
$credentialPrefix = "Qiyu.Ticket25.Test.$PID"
$credentialTarget = "$credentialPrefix.sample"

try {
  New-PackageFixture -SourceRoot $sourceRoot -Version '0.1.0-test.1'
  & (Join-Path $sourceRoot 'Install-Qiyu.ps1') `
    -InstallRoot $installRoot `
    -StartMenuRoot $startMenuRoot `
    -DesktopRoot $desktopRoot `
    -NoLaunch

  Assert-True (Test-Path -LiteralPath (Join-Path $installRoot 'qiyu_windows_host.exe')) `
    '首次安装没有复制宿主可执行文件。'
  Assert-True (Test-Path -LiteralPath (Join-Path $startMenuRoot '栖语.lnk')) `
    '首次安装没有创建开始菜单快捷方式。'
  Assert-True (Test-Path -LiteralPath (Join-Path $desktopRoot '栖语.lnk')) `
    '首次安装没有创建桌面快捷方式。'

  New-Item -ItemType Directory -Force -Path $memoryRoot, $runtimeRoot | Out-Null
  [IO.File]::WriteAllText(
    (Join-Path $memoryRoot 'keep.md'),
    'preserve across upgrade',
    [Text.UTF8Encoding]::new($false)
  )
  [IO.File]::WriteAllText(
    (Join-Path $runtimeRoot 'keep.json'),
    '{}',
    [Text.UTF8Encoding]::new($false)
  )

  Remove-Item -LiteralPath $sourceRoot -Recurse -Force
  New-PackageFixture -SourceRoot $sourceRoot -Version '0.1.0-test.2'
  & (Join-Path $sourceRoot 'Install-Qiyu.ps1') `
    -InstallRoot $installRoot `
    -StartMenuRoot $startMenuRoot `
    -DesktopRoot $desktopRoot `
    -NoLaunch

  $installedRelease = Get-Content -Raw -Encoding UTF8 `
    (Join-Path $installRoot 'release.json') | ConvertFrom-Json
  Assert-True ($installedRelease.version -eq '0.1.0-test.2') `
    '升级没有替换应用版本。'
  Assert-True (Test-Path -LiteralPath (Join-Path $memoryRoot 'keep.md')) `
    '升级删除了用户 Markdown 数据。'
  Assert-True (Test-Path -LiteralPath (Join-Path $runtimeRoot 'keep.json')) `
    '升级删除了本机运行配置。'

  & (Join-Path $installRoot 'Uninstall-Qiyu.ps1') `
    -InstallRoot $installRoot `
    -DataRoot $memoryRoot `
    -RuntimeRoot $runtimeRoot `
    -StartMenuRoot $startMenuRoot `
    -DesktopRoot $desktopRoot `
    -CredentialTargetPrefix $credentialPrefix `
    -KeepData

  Assert-True (-not (Test-Path -LiteralPath $installRoot)) `
    '保留数据卸载没有删除程序目录。'
  Assert-True (Test-Path -LiteralPath (Join-Path $memoryRoot 'keep.md')) `
    '保留数据卸载删除了 Markdown 数据。'
  Assert-True (Test-Path -LiteralPath (Join-Path $runtimeRoot 'keep.json')) `
    '保留数据卸载删除了运行配置。'

  & (Join-Path $sourceRoot 'Install-Qiyu.ps1') `
    -InstallRoot $installRoot `
    -StartMenuRoot $startMenuRoot `
    -DesktopRoot $desktopRoot `
    -NoLaunch
  $credentialWriteOutput = & cmdkey.exe `
    "/generic:$credentialTarget" `
    '/user:Qiyu' `
    '/pass:ticket25-test-only'
  $credentialWriteOutput | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw '无法创建隔离的测试凭据。'
  }

  & (Join-Path $installRoot 'Uninstall-Qiyu.ps1') `
    -InstallRoot $installRoot `
    -DataRoot $memoryRoot `
    -RuntimeRoot $runtimeRoot `
    -StartMenuRoot $startMenuRoot `
    -DesktopRoot $desktopRoot `
    -CredentialTargetPrefix $credentialPrefix `
    -RemoveData

  Assert-True (-not (Test-Path -LiteralPath $installRoot)) `
    '删除数据卸载没有删除程序目录。'
  Assert-True (-not (Test-Path -LiteralPath $memoryRoot)) `
    '删除数据卸载没有删除 Markdown 数据。'
  Assert-True (-not (Test-Path -LiteralPath $runtimeRoot)) `
    '删除数据卸载没有删除运行配置。'
  $credentialList = (& cmdkey.exe /list) -join "`n"
  Assert-True ($credentialList -notmatch ([regex]::Escape($credentialTarget))) `
    '删除数据卸载没有删除隔离的 Windows 凭据。'
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $startMenuRoot '栖语.lnk'))) `
    '卸载没有删除开始菜单快捷方式。'
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $desktopRoot '栖语.lnk'))) `
    '卸载没有删除桌面快捷方式。'

  Write-Host 'Windows package lifecycle tests passed'
} finally {
  & cmdkey.exe "/delete:$credentialTarget" 2>$null | Out-Null
  $global:LASTEXITCODE = 0
  if (Test-Path -LiteralPath $testRoot) {
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    $resolvedTempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if (-not $resolvedTestRoot.StartsWith(
      $resolvedTempRoot,
      [StringComparison]::OrdinalIgnoreCase
    )) {
      throw "拒绝清理非临时测试目录：$resolvedTestRoot"
    }
    Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
  }
}
