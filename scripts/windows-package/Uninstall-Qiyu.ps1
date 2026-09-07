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

# 快捷方式读取走 Shell 链接的 Unicode 接口：WScript.Shell 组件会把
# 路径压到系统 ANSI 代码页，「栖语」在非中文区域设置的 Windows 上
# 会被换成问号，导致整个安装或卸载失败。以下定义在两个安装脚本中
# 保持逐字一致。
if (-not ('Qiyu.Installer.ShortcutWriter' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;

namespace Qiyu.Installer
{
    public static class ShortcutWriter
    {
        [ComImport]
        [Guid("00021401-0000-0000-C000-000000000046")]
        private class ShellLinkClass
        {
        }

        [ComImport]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        [Guid("000214F9-0000-0000-C000-000000000046")]
        private interface IShellLinkW
        {
            void GetPath(
                [Out][MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszFile,
                int cch,
                IntPtr pfd,
                uint fFlags);
            void GetIDList(out IntPtr ppidl);
            void SetIDList(IntPtr pidl);
            void GetDescription(
                [Out][MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszName,
                int cch);
            void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string pszName);
            void GetWorkingDirectory(
                [Out][MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszDir,
                int cch);
            void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string pszDir);
            void GetArguments(
                [Out][MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszArgs,
                int cch);
            void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string pszArgs);
            void GetHotkey(out short pwHotkey);
            void SetHotkey(short wHotkey);
            void GetShowCmd(out int piShowCmd);
            void SetShowCmd(int iShowCmd);
            void GetIconLocation(
                [Out][MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszIconPath,
                int cch,
                out int piIcon);
            void SetIconLocation(
                [MarshalAs(UnmanagedType.LPWStr)] string pszIconPath,
                int iIcon);
            void SetRelativePath(
                [MarshalAs(UnmanagedType.LPWStr)] string pszPathRel,
                uint dwReserved);
            void Resolve(IntPtr hwnd, uint fFlags);
            void SetPath([MarshalAs(UnmanagedType.LPWStr)] string pszFile);
        }

        public static void Create(
            string shortcutPath,
            string targetPath,
            string workingDirectory,
            string description)
        {
            IShellLinkW link = (IShellLinkW)new ShellLinkClass();
            link.SetPath(targetPath);
            link.SetWorkingDirectory(workingDirectory);
            link.SetDescription(description);
            IPersistFile persist = (IPersistFile)link;
            persist.Save(shortcutPath, true);
        }

        public static string ReadTarget(string shortcutPath)
        {
            IShellLinkW link = (IShellLinkW)new ShellLinkClass();
            IPersistFile persist = (IPersistFile)link;
            persist.Load(shortcutPath, 0);
            StringBuilder path = new StringBuilder(1024);
            link.GetPath(path, path.Capacity, IntPtr.Zero, 0);
            return path.ToString();
        }
    }
}
'@
}

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

function Assert-QiyuInstallation {
  param([Parameter(Mandatory = $true)][string]$Path)

  if ([IO.Path]::GetFileName($Path) -ine 'Qiyu') {
    throw '程序目录必须是名称为 Qiyu 的专用 Qiyu 目录。'
  }
  $executable = Join-Path $Path 'qiyu_windows_host.exe'
  $releasePath = Join-Path $Path 'release.json'
  if (
    -not (Test-Path -LiteralPath $executable -PathType Leaf) -or
    -not (Test-Path -LiteralPath $releasePath -PathType Leaf)
  ) {
    throw '程序目录不是可验证的栖语安装，拒绝卸载。'
  }
  try {
    $release = Get-Content -Raw -Encoding UTF8 $releasePath |
      ConvertFrom-Json
  } catch {
    throw '程序目录的 release.json 无法读取，拒绝卸载。'
  }
  if ($release.product -ne 'Qiyu') {
    throw '程序目录的产品标识不是 Qiyu，拒绝卸载。'
  }
}

function Assert-DedicatedQiyuDirectory {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$ExpectedName,
    [Parameter(Mandatory = $true)][string]$Purpose
  )

  if ([IO.Path]::GetFileName($Path) -ine $ExpectedName) {
    throw "$Purpose 必须是名称为 $ExpectedName 的栖语专用目录。"
  }
}

function Assert-QiyuCredentialTargetPrefix {
  param([Parameter(Mandatory = $true)][string]$TargetPrefix)

  if (
    $TargetPrefix -ine 'Qiyu.Provider.ApiKey' -and
    $TargetPrefix -notmatch '^Qiyu\.Provider\.ApiKey\.[A-Fa-f0-9]{64}$'
  ) {
    throw '凭据删除范围必须位于 Qiyu.Provider.ApiKey 命名空间。'
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
  $target = [Qiyu.Installer.ShortcutWriter]::ReadTarget($ShortcutPath)
  if (
    [IO.Path]::GetFullPath($target) -eq
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
  $targets = [regex]::Matches(
    $credentialList,
    'Qiyu\.Provider\.ApiKey\.[A-Fa-f0-9]{64}'
  ) |
    ForEach-Object { $_.Value } |
    Where-Object {
      $TargetPrefix -ieq 'Qiyu.Provider.ApiKey' -or
      $_ -ieq $TargetPrefix
    } |
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
Assert-QiyuInstallation -Path $resolvedInstallRoot
$installedExecutable = Join-Path $resolvedInstallRoot 'qiyu_windows_host.exe'
Assert-HostNotRunning -ExecutablePath $installedExecutable
$resolvedDataRoot = Resolve-SafeRemovalPath -Path $DataRoot -Purpose '数据目录'
Assert-DedicatedQiyuDirectory -Path $resolvedDataRoot `
  -ExpectedName '.qiyu' -Purpose '数据目录'
$resolvedRuntimeRoot = Resolve-SafeRemovalPath `
  -Path $RuntimeRoot -Purpose '运行目录'
Assert-DedicatedQiyuDirectory -Path $resolvedRuntimeRoot `
  -ExpectedName 'Qiyu' -Purpose '运行目录'
Assert-QiyuCredentialTargetPrefix -TargetPrefix $CredentialTargetPrefix

Remove-QiyuShortcut -ShortcutPath (Join-Path $StartMenuRoot '栖语.lnk') `
  -ExecutablePath $installedExecutable
Remove-QiyuShortcut -ShortcutPath (Join-Path $DesktopRoot '栖语.lnk') `
  -ExecutablePath $installedExecutable

if ($RemoveData) {
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
