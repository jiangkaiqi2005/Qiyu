[CmdletBinding()]
param(
  [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'Programs\Qiyu'),
  [string]$StartMenuRoot = (
    Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
  ),
  [string]$DesktopRoot = [Environment]::GetFolderPath('Desktop'),
  [switch]$NoDesktopShortcut,
  [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'

# 快捷方式写入走 Shell 链接的 Unicode 接口：WScript.Shell 组件会把
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

function Resolve-SafeApplicationPath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [string]$Purpose
  )

  $resolved = [IO.Path]::GetFullPath($Path)
  $root = [IO.Path]::GetPathRoot($resolved)
  if (
    $resolved -eq $root -or
    [string]::IsNullOrWhiteSpace([IO.Path]::GetFileName($resolved))
  ) {
    throw "拒绝把 $Purpose 指向磁盘根目录：$resolved"
  }
  return $resolved.TrimEnd([IO.Path]::DirectorySeparatorChar)
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
        throw '栖语仍在运行。请先关闭本机程序，再安装或升级。'
      }
    } catch [System.ComponentModel.Win32Exception] {
      continue
    }
  }
}

function Test-QiyuInstallation {
  param([Parameter(Mandatory = $true)][string]$Path)

  $executable = Join-Path $Path 'qiyu_windows_host.exe'
  $releasePath = Join-Path $Path 'release.json'
  if (
    -not (Test-Path -LiteralPath $executable -PathType Leaf) -or
    -not (Test-Path -LiteralPath $releasePath -PathType Leaf)
  ) {
    return $false
  }
  try {
    $release = Get-Content -Raw -Encoding UTF8 $releasePath |
      ConvertFrom-Json
    return $release.product -eq 'Qiyu'
  } catch {
    return $false
  }
}

function New-QiyuShortcut {
  param(
    [Parameter(Mandatory = $true)][string]$ShortcutPath,
    [Parameter(Mandatory = $true)][string]$ExecutablePath
  )

  $shortcutDirectory = Split-Path -Parent $ShortcutPath
  New-Item -ItemType Directory -Force -Path $shortcutDirectory | Out-Null
  [Qiyu.Installer.ShortcutWriter]::Create(
    $ShortcutPath,
    $ExecutablePath,
    (Split-Path -Parent $ExecutablePath),
    '打开栖语'
  )
}

if (-not [Environment]::Is64BitOperatingSystem) {
  throw '栖语 Windows 首发候选包只支持 64 位 Windows。'
}

$sourceRoot = Resolve-SafeApplicationPath -Path $PSScriptRoot -Purpose '安装包目录'
$resolvedInstallRoot = Resolve-SafeApplicationPath `
  -Path $InstallRoot -Purpose '安装目录'
if ([IO.Path]::GetFileName($resolvedInstallRoot) -ine 'Qiyu') {
  throw '安装目录必须是名称为 Qiyu 的专用 Qiyu 目录。'
}
if ($resolvedInstallRoot -eq $sourceRoot) {
  throw '安装目录不能与安装包目录相同。'
}
if (Test-Path -LiteralPath $resolvedInstallRoot) {
  if (-not (Test-Path -LiteralPath $resolvedInstallRoot -PathType Container)) {
    throw '现有安装路径不是目录，拒绝覆盖。'
  }
  $existingItems = @(Get-ChildItem -LiteralPath $resolvedInstallRoot -Force)
  if (
    $existingItems.Count -gt 0 -and
    -not (Test-QiyuInstallation -Path $resolvedInstallRoot)
  ) {
    throw '现有目录不是栖语安装，拒绝覆盖或升级。'
  }
}

$requiredItems = @(
  'qiyu_windows_host.exe',
  'web',
  'persona-constitution.md',
  'licenses',
  'release.json',
  'Uninstall-Qiyu.ps1',
  'uninstall.cmd'
)
foreach ($item in $requiredItems) {
  if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot $item))) {
    throw "安装包不完整，缺少：$item"
  }
}

$installedExecutable = Join-Path $resolvedInstallRoot 'qiyu_windows_host.exe'
Assert-HostNotRunning -ExecutablePath $installedExecutable

$installParent = Split-Path -Parent $resolvedInstallRoot
$installLeaf = Split-Path -Leaf $resolvedInstallRoot
New-Item -ItemType Directory -Force -Path $installParent | Out-Null
$stagingRoot = Join-Path $installParent "$installLeaf.installing-$PID"
$backupRoot = Join-Path $installParent "$installLeaf.previous-$PID"
foreach ($temporaryRoot in @($stagingRoot, $backupRoot)) {
  $resolvedTemporaryRoot = Resolve-SafeApplicationPath `
    -Path $temporaryRoot -Purpose '安装临时目录'
  if ([IO.Path]::GetDirectoryName($resolvedTemporaryRoot) -ne $installParent) {
    throw "拒绝使用意外的安装临时目录：$resolvedTemporaryRoot"
  }
  if (Test-Path -LiteralPath $resolvedTemporaryRoot) {
    Remove-Item -LiteralPath $resolvedTemporaryRoot -Recurse -Force
  }
}

New-Item -ItemType Directory -Path $stagingRoot | Out-Null
try {
  foreach ($item in $requiredItems) {
    Copy-Item -LiteralPath (Join-Path $sourceRoot $item) `
      -Destination $stagingRoot -Recurse
  }

  if (Test-Path -LiteralPath $resolvedInstallRoot) {
    Move-Item -LiteralPath $resolvedInstallRoot -Destination $backupRoot
  }
  try {
    Move-Item -LiteralPath $stagingRoot -Destination $resolvedInstallRoot
  } catch {
    if (Test-Path -LiteralPath $backupRoot) {
      Move-Item -LiteralPath $backupRoot -Destination $resolvedInstallRoot
    }
    throw
  }
  if (Test-Path -LiteralPath $backupRoot) {
    Remove-Item -LiteralPath $backupRoot -Recurse -Force
  }
} finally {
  if (Test-Path -LiteralPath $stagingRoot) {
    Remove-Item -LiteralPath $stagingRoot -Recurse -Force
  }
}

$startMenuShortcut = Join-Path $StartMenuRoot '栖语.lnk'
New-QiyuShortcut -ShortcutPath $startMenuShortcut `
  -ExecutablePath $installedExecutable
if (-not $NoDesktopShortcut) {
  $desktopShortcut = Join-Path $DesktopRoot '栖语.lnk'
  New-QiyuShortcut -ShortcutPath $desktopShortcut `
    -ExecutablePath $installedExecutable
}

$release = Get-Content -Raw -Encoding UTF8 `
  (Join-Path $resolvedInstallRoot 'release.json') | ConvertFrom-Json
Write-Host "栖语 $($release.version) 已安装到：$resolvedInstallRoot"
Write-Host '聊天、记忆和 Provider 凭据保存在安装目录之外，升级不会覆盖。'

if (-not $NoLaunch) {
  Start-Process -FilePath $installedExecutable `
    -WorkingDirectory $resolvedInstallRoot
}
