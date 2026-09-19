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

  # --- zip 条目名 UTF-8 标志位：检出、修补、解压回归 ---
  Add-Type -AssemblyName System.IO.Compression
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $flagZipPath = Join-Path $testRoot 'names.zip'
  $flagSourceFile = Join-Path $testRoot 'names-src.txt'
  Set-Content -LiteralPath $flagSourceFile -Value 'x'
  $fixtureZip = [IO.Compression.ZipFile]::Open(
    $flagZipPath, [IO.Compression.ZipArchiveMode]::Create
  )
  try {
    [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
      $fixtureZip, $flagSourceFile, '栖语/a.txt'
    )
  } finally {
    $fixtureZip.Dispose()
  }
  # 部分运行时（.NET/.NET Core 不带 encoding 的 ZipArchive）会自动置好标志；
  # 为了让夹具在任何运行时都带上缺标志的状态，这里按条目偏移手工清掉 bit 11。
  $fixtureBytes = [IO.File]::ReadAllBytes($flagZipPath)
  foreach ($entry in (Get-ZipEntryNameFlags -Path $flagZipPath)) {
    $fixtureBytes[$entry.CentralHeaderOffset + 9] =
      $fixtureBytes[$entry.CentralHeaderOffset + 9] -band 0xF7
    $fixtureBytes[$entry.LocalHeaderOffset + 7] =
      $fixtureBytes[$entry.LocalHeaderOffset + 7] -band 0xF7
  }
  [IO.File]::WriteAllBytes($flagZipPath, $fixtureBytes)
  $unflaggedBefore = @(
    Get-ZipEntryNameFlags -Path $flagZipPath |
      Where-Object { -not $_.HasUtf8Flag }
  )
  Assert-Condition ($unflaggedBefore.Count -gt 0) `
    '清掉标志后未检出缺 UTF-8 标志的 zip 条目。'
  $patchedCount = Set-ZipUtf8NameFlag -Path $flagZipPath
  Assert-Condition ($patchedCount -eq $unflaggedBefore.Count) `
    '修补的条目数与检出的缺标志条目数不一致。'
  Assert-Condition (
    @(
      Get-ZipEntryNameFlags -Path $flagZipPath |
        Where-Object { -not $_.HasUtf8Flag }
    ).Count -eq 0
  ) '修补后仍有条目缺 UTF-8 文件名标志。'
  $flagExpandedRoot = Join-Path $testRoot 'names-out'
  Expand-Archive -LiteralPath $flagZipPath -DestinationPath $flagExpandedRoot
  Assert-Condition (
    (Get-ChildItem -LiteralPath $flagExpandedRoot | Select-Object -First 1).Name -eq '栖语'
  ) '修补后解压出来的顶层目录名不是「栖语」。'

  # --- 发布压缩：顶层目录「栖语」与 UTF-8 标志位一次到位 ---
  $bundleSourceRoot = Join-Path $testRoot 'bundle-src'
  New-Item -ItemType Directory -Path $bundleSourceRoot -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $bundleSourceRoot 'release.json') -Value '{}'
  Set-Content -LiteralPath (Join-Path $bundleSourceRoot 'install.cmd') -Value 'rem fixture'
  $bundleArchivePath = Join-Path $testRoot 'bundle.zip'
  Compress-BundleArchive `
    -BundlePath $bundleSourceRoot `
    -ArchivePath $bundleArchivePath `
    -RootDirectoryName '栖语'
  Assert-Condition (
    @(
      Get-ZipEntryNameFlags -Path $bundleArchivePath |
        Where-Object { -not $_.HasUtf8Flag }
    ).Count -eq 0
  ) '发布压缩产出的 zip 缺 UTF-8 文件名标志。'
  $bundleExpandedRoot = Join-Path $testRoot 'bundle-out'
  Expand-Archive -LiteralPath $bundleArchivePath -DestinationPath $bundleExpandedRoot
  $bundleTopEntries = @(Get-ChildItem -LiteralPath $bundleExpandedRoot)
  Assert-Condition (
    $bundleTopEntries.Count -eq 1 -and
    $bundleTopEntries[0].Name -eq '栖语' -and
    (Test-Path -LiteralPath (Join-Path $bundleTopEntries[0].FullName 'release.json')) -and
    (Test-Path -LiteralPath (Join-Path $bundleTopEntries[0].FullName 'install.cmd'))
  ) '发布压缩产出的 zip 顶层目录应为「栖语」且包含包内文件。'

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
