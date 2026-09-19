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

function Get-ZipEntryNameFlags {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  # zip 条目名的通用标志 bit 11 声明「名字按 UTF-8 解码」。Windows PowerShell
  # 5.1 的 ZipArchive 在显式指定 UTF-8 编码时写 UTF-8 字节却不置这一位
  # （Compress-Archive 同样），中文系统解压时按本机代码页解码，顶层目录
  # 「栖语」会乱码，甚至把分隔符一起吞进多字节字符里。这里按 zip 结构
  # 读出每个条目两个头的偏移与当前标志状态，供修补、断言与测试使用。
  $bytes = [IO.File]::ReadAllBytes($Path)
  $scanStart = [Math]::Max(0, $bytes.Length - 22 - 65535)
  $eocdOffset = -1
  for ($i = $bytes.Length - 22; $i -ge $scanStart; $i--) {
    if (
      $bytes[$i] -eq 0x50 -and $bytes[$i + 1] -eq 0x4B -and
      $bytes[$i + 2] -eq 0x05 -and $bytes[$i + 3] -eq 0x06
    ) {
      $eocdOffset = $i
      break
    }
  }
  if ($eocdOffset -lt 0) {
    throw "无法定位 zip 的中央目录结尾（EOCD）：$Path"
  }
  $entryCount = [BitConverter]::ToUInt16($bytes, $eocdOffset + 10)
  $cursor = [BitConverter]::ToInt32($bytes, $eocdOffset + 16)
  $entries = @()
  for ($entry = 0; $entry -lt $entryCount; $entry++) {
    if ([BitConverter]::ToUInt32($bytes, $cursor) -ne 0x02014B50) {
      throw "zip 中央目录第 $($entry + 1) 个条目签名异常：$Path"
    }
    $localHeaderOffset = [BitConverter]::ToInt32($bytes, $cursor + 42)
    $nameLength = [BitConverter]::ToUInt16($bytes, $cursor + 28)
    $hasUtf8Flag = (
      ([BitConverter]::ToUInt16($bytes, $cursor + 8) -band 0x800) -ne 0 -and
      ([BitConverter]::ToUInt16($bytes, $localHeaderOffset + 6) -band 0x800) -ne 0
    )
    $entries += [pscustomobject]@{
      Name = [Text.Encoding]::UTF8.GetString(
        $bytes[($cursor + 46)..($cursor + 46 + $nameLength - 1)]
      )
      CentralHeaderOffset = $cursor
      LocalHeaderOffset = $localHeaderOffset
      HasUtf8Flag = $hasUtf8Flag
    }
    $cursor += 46 +
      $nameLength +
      [BitConverter]::ToUInt16($bytes, $cursor + 30) +
      [BitConverter]::ToUInt16($bytes, $cursor + 32)
  }
  return $entries
}

function Set-ZipUtf8NameFlag {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  # bit 11 位于 16 位通用标志的高字节（小端第 2 个字节），按位或 0x08 即置位；
  # 对已置位的条目是幂等的。
  $bytes = [IO.File]::ReadAllBytes($Path)
  $patched = 0
  foreach ($entry in (Get-ZipEntryNameFlags -Path $Path)) {
    if (-not $entry.HasUtf8Flag) {
      $bytes[$entry.CentralHeaderOffset + 9] =
        $bytes[$entry.CentralHeaderOffset + 9] -bor 0x08
      $bytes[$entry.LocalHeaderOffset + 7] =
        $bytes[$entry.LocalHeaderOffset + 7] -bor 0x08
      $patched++
    }
  }
  [IO.File]::WriteAllBytes($Path, $bytes)
  return $patched
}

function Compress-BundleArchive {
  param(
    [Parameter(Mandatory = $true)]
    [string]$BundlePath,
    [Parameter(Mandatory = $true)]
    [string]$ArchivePath,
    [Parameter(Mandatory = $true)]
    [string]$RootDirectoryName
  )

  # 发布 zip 的顶层目录用产品名（如「栖语」），用户解压看到的就是它；
  # 条目名一律按 UTF-8 写入，写完统一补置 bit 11（原因见上面的注释）。
  Add-Type -AssemblyName System.IO.Compression
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $resolvedBundle = [IO.Path]::GetFullPath($BundlePath)
  if (-not (Test-Path -LiteralPath $resolvedBundle -PathType Container)) {
    throw "Windows bundle directory is missing: $resolvedBundle"
  }
  $zip = [IO.Compression.ZipFile]::Open(
    $ArchivePath,
    [IO.Compression.ZipArchiveMode]::Create,
    [Text.Encoding]::UTF8
  )
  try {
    $files = Get-ChildItem -LiteralPath $resolvedBundle -Recurse -File |
      Sort-Object FullName
    foreach ($file in $files) {
      $relative = $file.FullName.Substring($resolvedBundle.Length + 1).Replace('\', '/')
      [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
        $zip,
        $file.FullName,
        "$RootDirectoryName/$relative",
        [IO.Compression.CompressionLevel]::Optimal
      )
    }
  } finally {
    $zip.Dispose()
  }
  [void](Set-ZipUtf8NameFlag -Path $ArchivePath)
}
