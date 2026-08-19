[CmdletBinding()]
param(
  [switch]$KeepData,
  [switch]$RemoveData,
  [string]$InstallRoot = $PSScriptRoot,
  [string]$DataRoot = (Join-Path $env:USERPROFILE '.qiyu'),
  [string]$RuntimeRoot = (Join-Path $env:LOCALAPPDATA 'Qiyu'),
  [string]$StartMenuRoot = (
    Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
  ),
  [string]$DesktopRoot = [Environment]::GetFolderPath('Desktop'),
  [string]$CredentialTargetPrefix = 'Qiyu.Provider.ApiKey'
)

$ErrorActionPreference = 'Stop'

function Resolve-SafeRemovalPath {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Purpose
  )

  $resolved = [IO.Path]::GetFullPath($Path).TrimEnd(
    [IO.Path]::DirectorySeparatorChar
  )
  $root = [IO.Path]::GetPathRoot($resolved).TrimEnd(
    [IO.Path]::DirectorySeparatorChar
  )
  if (
    $resolved -eq $root -or
    [string]::IsNullOrWhiteSpace([IO.Path]::GetFileName($resolved))
  ) {
    throw "拒绝把 $Purpose 指向磁盘根目录：$resolved"
  }
  foreach ($protectedPath in @(
    $env:USERPROFILE,
    $env:LOCALAPPDATA,
    [IO.Path]::GetTempPath()
  )) {
    if (
      -not [string]::IsNullOrWhiteSpace($protectedPath) -and
      $resolved -eq [IO.Path]::GetFullPath($protectedPath).TrimEnd(
        [IO.Path]::DirectorySeparatorChar
      )
    ) {
      throw "拒绝把 $Purpose 指向受保护目录：$resolved"
    }
  }
  return $resolved
}

function Assert-HostNotRunning {
  param([Parameter(Mandatory = $true)][string]$ExecutablePath)

  foreach ($process in Get-Process -Name 'qiyu_windows_host' `
    -ErrorAction SilentlyContinue) {
    try {
      if (
        [IO.Path]::GetFullPath($process.Path) -eq
        [IO.Path]::GetFullPath($ExecutablePath)
      ) {
        throw '栖语仍在运行。请先关闭本机程序，再卸载。'
      }
    } catch [System.ComponentModel.Win32Exception] {
      continue
    }
  }
}

function Remove-QiyuShortcut {
  param(
    [Parameter(Mandatory = $true)][string]$ShortcutPath,
    [Parameter(Mandatory = $true)][string]$ExecutablePath
  )

  if (-not (Test-Path -LiteralPath $ShortcutPath)) {
    return
  }
  $shell = New-Object -ComObject WScript.Shell
  $shortcut = $shell.CreateShortcut($ShortcutPath)
  if (
    [IO.Path]::GetFullPath($shortcut.TargetPath) -eq
    [IO.Path]::GetFullPath($ExecutablePath)
  ) {
    Remove-Item -LiteralPath $ShortcutPath -Force
  }
}

function Remove-QiyuCredentials {
  param([Parameter(Mandatory = $true)][string]$TargetPrefix)

  $credentialList = (& cmdkey.exe /list) -join "`n"
  if ($LASTEXITCODE -ne 0) {
    throw '无法读取 Windows 凭据列表，未继续删除用户数据。'
  }
  $pattern = [regex]::Escape($TargetPrefix) + '[A-Za-z0-9._-]*'
  $targets = [regex]::Matches($credentialList, $pattern) |
    ForEach-Object { $_.Value } |
    Sort-Object -Unique
  foreach ($target in $targets) {
    & cmdkey.exe "/delete:$target" | Out-Null
    if ($LASTEXITCODE -ne 0) {
      throw "无法删除 Windows 安全存储中的栖语凭据：$target"
    }
  }
}

if ($KeepData -and $RemoveData) {
  throw '-KeepData 与 -RemoveData 不能同时使用。'
}
if (-not $KeepData -and -not $RemoveData) {
  $answer = Read-Host (
    '卸载后是否保留聊天、Markdown 记忆、Provider 设置和 API Key？' +
    ' 输入 K 保留，输入 R 永久删除'
  )
  switch ($answer.Trim().ToUpperInvariant()) {
    'K' { $KeepData = $true }
    'R' { $RemoveData = $true }
    default { throw '未选择 K 或 R，已取消卸载。' }
  }
}

$resolvedInstallRoot = Resolve-SafeRemovalPath `
  -Path $InstallRoot -Purpose '程序目录'
$installedExecutable = Join-Path $resolvedInstallRoot 'qiyu_windows_host.exe'
Assert-HostNotRunning -ExecutablePath $installedExecutable

Remove-QiyuShortcut -ShortcutPath (Join-Path $StartMenuRoot '栖语.lnk') `
  -ExecutablePath $installedExecutable
Remove-QiyuShortcut -ShortcutPath (Join-Path $DesktopRoot '栖语.lnk') `
  -ExecutablePath $installedExecutable

if ($RemoveData) {
  $resolvedDataRoot = Resolve-SafeRemovalPath -Path $DataRoot -Purpose '数据目录'
  $resolvedRuntimeRoot = Resolve-SafeRemovalPath `
    -Path $RuntimeRoot -Purpose '运行目录'
  Remove-QiyuCredentials -TargetPrefix $CredentialTargetPrefix
  foreach ($path in @($resolvedDataRoot, $resolvedRuntimeRoot)) {
    if (Test-Path -LiteralPath $path) {
      Remove-Item -LiteralPath $path -Recurse -Force
    }
  }
}

if (Test-Path -LiteralPath $resolvedInstallRoot) {
  Remove-Item -LiteralPath $resolvedInstallRoot -Recurse -Force
}

if ($KeepData) {
  Write-Host '栖语已卸载；聊天、Markdown 记忆、Provider 设置和 API Key 已保留。'
} else {
  Write-Host '栖语及本机用户数据已卸载。'
}
