function Publish-WindowsBundle {
  param(
    [Parameter(Mandatory = $true)]
    [string]$StagingPath,
    [Parameter(Mandatory = $true)]
    [string]$BundlePath,
    [Parameter(Mandatory = $true)]
    [string]$ExpectedParent
  )

  $resolvedBundle = [IO.Path]::GetFullPath($BundlePath)
  $resolvedParent = [IO.Path]::GetFullPath($ExpectedParent)
  if ([IO.Path]::GetDirectoryName($resolvedBundle) -ne $resolvedParent) {
    throw "Refusing to replace unexpected bundle path: $resolvedBundle"
  }
  $resolvedStaging = [IO.Path]::GetFullPath($StagingPath)
  if (-not (Test-Path -LiteralPath $resolvedStaging -PathType Container)) {
    throw "Windows bundle staging directory is missing: $resolvedStaging"
  }

  $hadExistingBundle = Test-Path -LiteralPath $resolvedBundle -PathType Container
  $bundleExecutable = Join-Path $resolvedBundle 'qiyu_windows_host.exe'
  if ($hadExistingBundle -and (Test-Path -LiteralPath $bundleExecutable)) {
    $lockProbe = $null
    try {
      $lockProbe = [IO.File]::Open(
        $bundleExecutable,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::None
      )
    } catch {
      throw 'Windows bundle is in use; close Qiyu and retry the build.'
    } finally {
      if ($null -ne $lockProbe) {
        $lockProbe.Dispose()
      }
    }
  }

  $backupPath = Join-Path $resolvedParent `
    ((Split-Path -Leaf $resolvedBundle) + '.previous')
  if (Test-Path -LiteralPath $backupPath) {
    Remove-Item -LiteralPath $backupPath -Recurse -Force
  }

  if ($hadExistingBundle) {
    # 锁探针已经排除运行中的 Host；目录切换失败时仍可从 previous 回滚。
    [IO.Directory]::Move($resolvedBundle, $backupPath)
  }

  try {
    [IO.Directory]::Move($resolvedStaging, $resolvedBundle)
  } catch {
    $publishError = $_
    if (
      $hadExistingBundle -and
      (Test-Path -LiteralPath $backupPath -PathType Container) -and
      -not (Test-Path -LiteralPath $resolvedBundle)
    ) {
      [IO.Directory]::Move($backupPath, $resolvedBundle)
    }
    throw $publishError
  }

  if (Test-Path -LiteralPath $backupPath) {
    Remove-Item -LiteralPath $backupPath -Recurse -Force
  }
}
