$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'windows-bundle-publish.ps1')

function Assert-Condition {
  param(
    [Parameter(Mandatory = $true)][bool]$Condition,
    [Parameter(Mandatory = $true)][string]$Message
  )

  if (-not $Condition) {
    throw $Message
  }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) `
  ('qiyu-bundle-publish-' + [Guid]::NewGuid().ToString('N'))
$buildPath = Join-Path $testRoot 'build'
$bundlePath = Join-Path $buildPath 'windows-bundle'
$stagingPath = Join-Path $testRoot 'windows-bundle-staging'
$oldWebPath = Join-Path $bundlePath 'web\index.html'
$oldExecutablePath = Join-Path $bundlePath 'qiyu_windows_host.exe'
$newWebPath = Join-Path $stagingPath 'web\index.html'
$newExecutablePath = Join-Path $stagingPath 'qiyu_windows_host.exe'
$backupPath = "$bundlePath.previous"
$lockHandle = $null

try {
  New-Item -ItemType Directory -Path (Split-Path -Parent $oldWebPath) `
    -Force | Out-Null
  New-Item -ItemType Directory -Path (Split-Path -Parent $newWebPath) `
    -Force | Out-Null
  [IO.File]::WriteAllText($oldWebPath, 'old-web')
  [IO.File]::WriteAllText($oldExecutablePath, 'old-executable')
  [IO.File]::WriteAllText($newWebPath, 'new-web')
  [IO.File]::WriteAllText($newExecutablePath, 'new-executable')

  $lockHandle = [IO.File]::Open(
    $oldExecutablePath,
    [IO.FileMode]::Open,
    [IO.FileAccess]::Read,
    [IO.FileShare]::Read
  )
  $publishFailed = $false
  try {
    Publish-WindowsBundle `
      -StagingPath $stagingPath `
      -BundlePath $bundlePath `
      -ExpectedParent $buildPath
  } catch {
    $publishFailed = $true
  }

  Assert-Condition $publishFailed `
    '锁定旧 EXE 时发布应失败。'
  Assert-Condition (Test-Path -LiteralPath $oldWebPath -PathType Leaf) `
    '发布失败删除了旧 bundle 的 Web 入口。'
  Assert-Condition (
    (Get-Content -Raw -LiteralPath $oldWebPath) -eq 'old-web'
  ) '发布失败改写了旧 bundle 的 Web 入口。'
  Assert-Condition (Test-Path -LiteralPath $oldExecutablePath -PathType Leaf) `
    '发布失败删除了旧 bundle 的 EXE。'
  Assert-Condition (-not (Test-Path -LiteralPath $backupPath)) `
    '发布失败留下了不完整的 previous bundle。'

  $lockHandle.Dispose()
  $lockHandle = $null
  Publish-WindowsBundle `
    -StagingPath $stagingPath `
    -BundlePath $bundlePath `
    -ExpectedParent $buildPath

  Assert-Condition (
    (Get-Content -Raw -LiteralPath $oldWebPath) -eq 'new-web'
  ) '解锁后的发布没有切换到新 Web 资源。'
  Assert-Condition (
    (Get-Content -Raw -LiteralPath $oldExecutablePath) -eq 'new-executable'
  ) '解锁后的发布没有切换到新 EXE。'
  Assert-Condition (-not (Test-Path -LiteralPath $stagingPath)) `
    '发布成功后 staging 目录仍然存在。'

  Write-Host 'Windows bundle publish tests passed'
} finally {
  if ($null -ne $lockHandle) {
    $lockHandle.Dispose()
  }
  if (Test-Path -LiteralPath $testRoot) {
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if (-not $resolvedTestRoot.StartsWith(
      $resolvedTemp,
      [StringComparison]::OrdinalIgnoreCase
    )) {
      throw "Refusing to clean unexpected test path: $resolvedTestRoot"
    }
    [IO.Directory]::Delete($resolvedTestRoot, $true)
  }
}
