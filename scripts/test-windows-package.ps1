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

function Assert-RejectedWithoutChangingMarker {
  param(
    [Parameter(Mandatory = $true)][scriptblock]$Action,
    [Parameter(Mandatory = $true)][string]$ExpectedMessage,
    [Parameter(Mandatory = $true)][string]$MarkerPath,
    [Parameter(Mandatory = $true)][string]$MarkerContent
  )

  $rejected = $false
  try {
    & $Action | Out-Null
  } catch {
    $rejected = $true
    Assert-True ($_.Exception.Message -match $ExpectedMessage) `
      '拒绝原因与预期不符。'
  }
  Assert-True $rejected '危险路径没有被拒绝。'
  Assert-True (Test-Path -LiteralPath $MarkerPath -PathType Leaf) `
    '拒绝后标记文件消失。'
  Assert-True ((Get-Content -Raw -Encoding UTF8 $MarkerPath) -eq $MarkerContent) `
    '拒绝后标记文件被修改。'
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
    (@{ product = 'Qiyu'; version = $Version; architecture = 'x64' } |
      ConvertTo-Json),
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
$credentialHasher = [Security.Cryptography.SHA256]::Create()
try {
  $credentialScopeHash = ($credentialHasher.ComputeHash(
    [Text.Encoding]::UTF8.GetBytes("ticket25-package-test-$PID")
  ) | ForEach-Object { $_.ToString('x2') }) -join ''
} finally {
  $credentialHasher.Dispose()
}
$credentialTarget = "Qiyu.Provider.ApiKey.$credentialScopeHash"
$credentialPrefix = $credentialTarget

try {
  New-PackageFixture -SourceRoot $sourceRoot -Version '0.1.0-test.1'
  $genericInstallRoot = Join-Path $testRoot 'Documents'
  $genericInstallMarker = Join-Path $genericInstallRoot 'keep.txt'
  $genericInstallMarkerContent = 'must survive rejected install'
  New-Item -ItemType Directory -Force -Path $genericInstallRoot | Out-Null
  [IO.File]::WriteAllText(
    $genericInstallMarker,
    $genericInstallMarkerContent,
    [Text.UTF8Encoding]::new($false)
  )
  Assert-RejectedWithoutChangingMarker `
    -ExpectedMessage '专用 Qiyu 目录' `
    -MarkerPath $genericInstallMarker `
    -MarkerContent $genericInstallMarkerContent `
    -Action {
      & (Join-Path $sourceRoot 'Install-Qiyu.ps1') `
        -InstallRoot $genericInstallRoot `
        -StartMenuRoot $startMenuRoot `
        -DesktopRoot $desktopRoot `
        -NoLaunch
    }

  $foreignInstallRoot = Join-Path $testRoot 'foreign\Qiyu'
  $foreignInstallMarker = Join-Path $foreignInstallRoot 'keep.txt'
  $foreignInstallMarkerContent = 'must survive rejected upgrade'
  New-Item -ItemType Directory -Force -Path $foreignInstallRoot | Out-Null
  [IO.File]::WriteAllText(
    $foreignInstallMarker,
    $foreignInstallMarkerContent,
    [Text.UTF8Encoding]::new($false)
  )
  Assert-RejectedWithoutChangingMarker `
    -ExpectedMessage '现有目录不是栖语安装' `
    -MarkerPath $foreignInstallMarker `
    -MarkerContent $foreignInstallMarkerContent `
    -Action {
      & (Join-Path $sourceRoot 'Install-Qiyu.ps1') `
        -InstallRoot $foreignInstallRoot `
        -StartMenuRoot $startMenuRoot `
        -DesktopRoot $desktopRoot `
        -NoLaunch
    }

  $wrongProductRoot = Join-Path $testRoot 'wrong-product\Qiyu'
  New-PackageFixture -SourceRoot $wrongProductRoot -Version '0.1.0-test.1'
  $wrongProductRelease = Get-Content -Raw -Encoding UTF8 `
    (Join-Path $wrongProductRoot 'release.json') | ConvertFrom-Json
  $wrongProductRelease.product = 'OtherProduct'
  [IO.File]::WriteAllText(
    (Join-Path $wrongProductRoot 'release.json'),
    ($wrongProductRelease | ConvertTo-Json),
    [Text.UTF8Encoding]::new($false)
  )
  $wrongProductMarker = Join-Path $wrongProductRoot 'keep.txt'
  $wrongProductMarkerContent = 'must survive wrong-product upgrade'
  [IO.File]::WriteAllText(
    $wrongProductMarker,
    $wrongProductMarkerContent,
    [Text.UTF8Encoding]::new($false)
  )
  Assert-RejectedWithoutChangingMarker `
    -ExpectedMessage '现有目录不是栖语安装' `
    -MarkerPath $wrongProductMarker `
    -MarkerContent $wrongProductMarkerContent `
    -Action {
      & (Join-Path $sourceRoot 'Install-Qiyu.ps1') `
        -InstallRoot $wrongProductRoot `
        -StartMenuRoot $startMenuRoot `
        -DesktopRoot $desktopRoot `
        -NoLaunch
    }

  $invalidUninstallRoot = Join-Path $testRoot 'invalid-uninstall\Qiyu'
  New-Item -ItemType Directory -Force -Path $invalidUninstallRoot | Out-Null
  Copy-Item -LiteralPath `
    (Join-Path $sourceRoot 'Uninstall-Qiyu.ps1') `
    -Destination $invalidUninstallRoot
  $invalidUninstallMarker = Join-Path $invalidUninstallRoot 'keep.txt'
  $invalidUninstallMarkerContent = 'must survive invalid uninstall identity'
  [IO.File]::WriteAllText(
    $invalidUninstallMarker,
    $invalidUninstallMarkerContent,
    [Text.UTF8Encoding]::new($false)
  )
  Assert-RejectedWithoutChangingMarker `
    -ExpectedMessage '不是可验证的栖语安装' `
    -MarkerPath $invalidUninstallMarker `
    -MarkerContent $invalidUninstallMarkerContent `
    -Action {
      & (Join-Path $invalidUninstallRoot 'Uninstall-Qiyu.ps1') `
        -InstallRoot $invalidUninstallRoot `
        -DataRoot $memoryRoot `
        -RuntimeRoot $runtimeRoot `
        -StartMenuRoot $startMenuRoot `
        -DesktopRoot $desktopRoot `
        -KeepData
    }

  $wrongUninstallRoot = Join-Path $testRoot 'wrong-uninstall\Qiyu'
  New-PackageFixture -SourceRoot $wrongUninstallRoot -Version '0.1.0-test.1'
  $wrongUninstallRelease = Get-Content -Raw -Encoding UTF8 `
    (Join-Path $wrongUninstallRoot 'release.json') | ConvertFrom-Json
  $wrongUninstallRelease.product = 'OtherProduct'
  [IO.File]::WriteAllText(
    (Join-Path $wrongUninstallRoot 'release.json'),
    ($wrongUninstallRelease | ConvertTo-Json),
    [Text.UTF8Encoding]::new($false)
  )
  $wrongUninstallMarker = Join-Path $wrongUninstallRoot 'keep.txt'
  $wrongUninstallMarkerContent = 'must survive wrong-product uninstall'
  [IO.File]::WriteAllText(
    $wrongUninstallMarker,
    $wrongUninstallMarkerContent,
    [Text.UTF8Encoding]::new($false)
  )
  Assert-RejectedWithoutChangingMarker `
    -ExpectedMessage '产品标识不是 Qiyu' `
    -MarkerPath $wrongUninstallMarker `
    -MarkerContent $wrongUninstallMarkerContent `
    -Action {
      & (Join-Path $wrongUninstallRoot 'Uninstall-Qiyu.ps1') `
        -InstallRoot $wrongUninstallRoot `
        -DataRoot $memoryRoot `
        -RuntimeRoot $runtimeRoot `
        -StartMenuRoot $startMenuRoot `
        -DesktopRoot $desktopRoot `
        -KeepData
    }

  $genericUninstallRoot = Join-Path $testRoot 'uninstall\Documents'
  New-PackageFixture -SourceRoot $genericUninstallRoot `
    -Version '0.1.0-test.1'
  $genericUninstallMarker = Join-Path $genericUninstallRoot 'keep.txt'
  $genericUninstallMarkerContent = 'must survive rejected uninstall'
  [IO.File]::WriteAllText(
    $genericUninstallMarker,
    $genericUninstallMarkerContent,
    [Text.UTF8Encoding]::new($false)
  )
  Assert-RejectedWithoutChangingMarker `
    -ExpectedMessage '专用 Qiyu 目录' `
    -MarkerPath $genericUninstallMarker `
    -MarkerContent $genericUninstallMarkerContent `
    -Action {
      & (Join-Path $genericUninstallRoot 'Uninstall-Qiyu.ps1') `
        -InstallRoot $genericUninstallRoot `
        -DataRoot $memoryRoot `
        -RuntimeRoot $runtimeRoot `
        -StartMenuRoot $startMenuRoot `
        -DesktopRoot $desktopRoot `
        -KeepData
    }

  & (Join-Path $sourceRoot 'Install-Qiyu.ps1') `
    -InstallRoot $installRoot `
    -StartMenuRoot $startMenuRoot `
    -DesktopRoot $desktopRoot `
    -NoLaunch 6>$null | Out-Null

  Assert-True (Test-Path -LiteralPath (Join-Path $installRoot 'qiyu_windows_host.exe')) `
    '首次安装没有复制宿主可执行文件。'
  Assert-True (Test-Path -LiteralPath (Join-Path $startMenuRoot '栖语.lnk')) `
    '首次安装没有创建开始菜单快捷方式。'
  Assert-True (Test-Path -LiteralPath (Join-Path $desktopRoot '栖语.lnk')) `
    '首次安装没有创建桌面快捷方式。'

  $genericDataRoot = Join-Path $testRoot 'data\Documents'
  $genericDataMarker = Join-Path $genericDataRoot 'keep.txt'
  $genericDataMarkerContent = 'must survive rejected data removal'
  $dedicatedRuntimeRoot = Join-Path $testRoot 'data-runtime\Qiyu'
  New-Item -ItemType Directory -Force -Path `
    $genericDataRoot, $dedicatedRuntimeRoot | Out-Null
  [IO.File]::WriteAllText(
    $genericDataMarker,
    $genericDataMarkerContent,
    [Text.UTF8Encoding]::new($false)
  )
  Assert-RejectedWithoutChangingMarker `
    -ExpectedMessage '数据目录.*专用' `
    -MarkerPath $genericDataMarker `
    -MarkerContent $genericDataMarkerContent `
    -Action {
      & (Join-Path $installRoot 'Uninstall-Qiyu.ps1') `
        -InstallRoot $installRoot `
        -DataRoot $genericDataRoot `
        -RuntimeRoot $dedicatedRuntimeRoot `
        -StartMenuRoot $startMenuRoot `
        -DesktopRoot $desktopRoot `
        -CredentialTargetPrefix $credentialPrefix `
        -RemoveData
    }

  $dedicatedDataRoot = Join-Path $testRoot 'runtime-test\.qiyu'
  $genericRuntimeRoot = Join-Path $testRoot 'runtime-test\Documents'
  $genericRuntimeMarker = Join-Path $genericRuntimeRoot 'keep.txt'
  $genericRuntimeMarkerContent = 'must survive rejected runtime removal'
  New-Item -ItemType Directory -Force -Path `
    $dedicatedDataRoot, $genericRuntimeRoot | Out-Null
  [IO.File]::WriteAllText(
    $genericRuntimeMarker,
    $genericRuntimeMarkerContent,
    [Text.UTF8Encoding]::new($false)
  )
  Assert-RejectedWithoutChangingMarker `
    -ExpectedMessage '运行目录.*专用' `
    -MarkerPath $genericRuntimeMarker `
    -MarkerContent $genericRuntimeMarkerContent `
    -Action {
      & (Join-Path $installRoot 'Uninstall-Qiyu.ps1') `
        -InstallRoot $installRoot `
        -DataRoot $dedicatedDataRoot `
        -RuntimeRoot $genericRuntimeRoot `
        -StartMenuRoot $startMenuRoot `
        -DesktopRoot $desktopRoot `
        -CredentialTargetPrefix $credentialPrefix `
        -RemoveData
    }

  $credentialDataRoot = Join-Path $testRoot 'credential-test\.qiyu'
  $credentialRuntimeRoot = Join-Path $testRoot 'credential-test\Qiyu'
  $credentialMarker = Join-Path $credentialDataRoot 'keep.txt'
  $credentialMarkerContent = 'must survive rejected credential namespace'
  New-Item -ItemType Directory -Force -Path `
    $credentialDataRoot, $credentialRuntimeRoot | Out-Null
  [IO.File]::WriteAllText(
    $credentialMarker,
    $credentialMarkerContent,
    [Text.UTF8Encoding]::new($false)
  )
  Assert-RejectedWithoutChangingMarker `
    -ExpectedMessage '凭据.*Qiyu.Provider.ApiKey' `
    -MarkerPath $credentialMarker `
    -MarkerContent $credentialMarkerContent `
    -Action {
      & (Join-Path $installRoot 'Uninstall-Qiyu.ps1') `
        -InstallRoot $installRoot `
        -DataRoot $credentialDataRoot `
        -RuntimeRoot $credentialRuntimeRoot `
        -StartMenuRoot $startMenuRoot `
        -DesktopRoot $desktopRoot `
        -CredentialTargetPrefix "MicrosoftAccount:ticket25-$PID" `
        -RemoveData
    }

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
    -NoLaunch 6>$null | Out-Null

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
    -KeepData 6>$null | Out-Null

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
    -NoLaunch 6>$null | Out-Null
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
    -RemoveData 6>$null | Out-Null

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
