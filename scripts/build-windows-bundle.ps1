param(
  [switch]$SkipFlutterBuild
)

$ErrorActionPreference = 'Stop'

function Get-Sha256Hex {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  $stream = [IO.File]::OpenRead($Path)
  try {
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
      return ([BitConverter]::ToString(
        $sha256.ComputeHash($stream)
      )).Replace('-', '')
    } finally {
      $sha256.Dispose()
    }
  } finally {
    $stream.Dispose()
  }
}

function Invoke-Step {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name,
    [Parameter(Mandatory = $true)]
    [scriptblock]$Command
  )

  Write-Host "==> $Name"
  & $Command
  if ($LASTEXITCODE -ne 0) {
    throw "$Name failed with exit code $LASTEXITCODE"
  }
}

function Remove-GeneratedDirectory {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [string]$ExpectedParent
  )

  $resolvedPath = [IO.Path]::GetFullPath($Path)
  $resolvedParent = [IO.Path]::GetFullPath($ExpectedParent)
  if ([IO.Path]::GetDirectoryName($resolvedPath) -ne $resolvedParent) {
    throw "Refusing to replace unexpected bundle path: $resolvedPath"
  }
  if (Test-Path -LiteralPath $resolvedPath) {
    Remove-Item -LiteralPath $resolvedPath -Recurse -Force
  }
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$flutterPath = Join-Path $repositoryRoot 'apps\qiyu_flutter'
$hostPath = Join-Path $repositoryRoot 'apps\qiyu_windows_host'
$hostBuildPath = Join-Path $hostPath 'build'
$bundlePath = Join-Path $hostBuildPath 'windows-bundle'
$stagingParent = Join-Path $hostPath '.dart_tool'
$stagingPath = Join-Path $stagingParent 'windows-bundle-staging'
$flutterWebPath = Join-Path $flutterPath 'build\web'
$hostPubspec = Get-Content -Raw -Encoding UTF8 `
  (Join-Path $hostPath 'pubspec.yaml')
if ($hostPubspec -notmatch '(?m)^version:\s*([0-9A-Za-z.+-]+)\s*$') {
  throw 'Windows host pubspec.yaml is missing a valid version.'
}
$packageVersion = $Matches[1]
$archivePath = Join-Path $hostBuildPath "qiyu-windows-x64-$packageVersion.zip"

if (-not $SkipFlutterBuild) {
  Push-Location $flutterPath
  try {
    Invoke-Step 'Flutter dependencies' { flutter pub get }
    Invoke-Step 'Flutter Web build' {
      flutter build web --no-web-resources-cdn
    }
  } finally {
    Pop-Location
  }
}

if (-not (Test-Path -LiteralPath (Join-Path $flutterWebPath 'index.html'))) {
  throw 'Flutter Web build is missing; run without -SkipFlutterBuild'
}

New-Item -ItemType Directory -Force -Path $hostBuildPath | Out-Null
New-Item -ItemType Directory -Force -Path $stagingParent | Out-Null
Remove-GeneratedDirectory -Path $stagingPath -ExpectedParent $stagingParent
New-Item -ItemType Directory -Path $stagingPath | Out-Null

Push-Location $hostPath
try {
  Invoke-Step 'Windows host dependencies' { dart pub get }
  Invoke-Step 'Windows host executable' {
    dart compile exe bin/qiyu_windows_host.dart `
      -o (Join-Path $stagingPath 'qiyu_windows_host.exe')
  }
} finally {
  Pop-Location
}

Copy-Item -LiteralPath $flutterWebPath `
  -Destination (Join-Path $stagingPath 'web') -Recurse
$personaConstitutionFileName = ([char]0x6816) + ([char]0x8BED) + `
  ([char]0x4EBA) + ([char]0x683C) + ([char]0x5BAA) + ([char]0x6CD5) + '.md'
Copy-Item -LiteralPath (Join-Path $repositoryRoot $personaConstitutionFileName) `
  -Destination (Join-Path $stagingPath 'persona-constitution.md')

$packageScriptPath = Join-Path $repositoryRoot 'scripts\windows-package'
foreach ($scriptName in @(
  'Install-Qiyu.ps1',
  'install.cmd',
  'Uninstall-Qiyu.ps1',
  'uninstall.cmd'
)) {
  Copy-Item -LiteralPath (Join-Path $packageScriptPath $scriptName) `
    -Destination $stagingPath
}

$licensesPath = Join-Path $stagingPath 'licenses'
New-Item -ItemType Directory -Path $licensesPath | Out-Null
$flutterCommand = Get-Command flutter -ErrorAction Stop
$flutterRoot = Split-Path -Parent (Split-Path -Parent $flutterCommand.Source)
$flutterLicense = Join-Path $flutterRoot 'LICENSE'
$dartLicense = Join-Path $flutterRoot 'bin\cache\dart-sdk\LICENSE'
foreach ($licenseFile in @($flutterLicense, $dartLicense)) {
  if (-not (Test-Path -LiteralPath $licenseFile -PathType Leaf)) {
    throw "Required SDK license is missing: $licenseFile"
  }
}
Copy-Item -LiteralPath $flutterLicense `
  -Destination (Join-Path $licensesPath 'Flutter-LICENSE.txt')
Copy-Item -LiteralPath $dartLicense `
  -Destination (Join-Path $licensesPath 'Dart-SDK-LICENSE.txt')

$packageConfigPath = Join-Path $hostPath '.dart_tool\package_config.json'
$packageConfig = Get-Content -Raw -Encoding UTF8 $packageConfigPath |
  ConvertFrom-Json
$licenseText = New-Object Text.StringBuilder
foreach ($package in $packageConfig.packages | Sort-Object name) {
  if (-not ([string]$package.rootUri).StartsWith('file:')) {
    continue
  }
  $packageRoot = ([Uri]$package.rootUri).LocalPath
  $packageLicenses = Get-ChildItem -LiteralPath $packageRoot -File |
    Where-Object Name -Match '^(LICENSE|COPYING|NOTICE)' |
    Sort-Object Name
  if (-not $packageLicenses) {
    throw "Package license is missing: $($package.name)"
  }
  [void]$licenseText.AppendLine("===== $($package.name) =====")
  foreach ($license in $packageLicenses) {
    [void]$licenseText.AppendLine("--- $($license.Name) ---")
    [void]$licenseText.AppendLine(
      (Get-Content -Raw -Encoding UTF8 $license.FullName).TrimEnd()
    )
  }
  [void]$licenseText.AppendLine()
}
[IO.File]::WriteAllText(
  (Join-Path $licensesPath 'Host-Packages-LICENSES.txt'),
  $licenseText.ToString(),
  [Text.UTF8Encoding]::new($false)
)

$manifestFiles = @(
  Get-ChildItem -LiteralPath $stagingPath -Recurse -File |
    Sort-Object FullName |
    ForEach-Object {
      @{
        path = $_.FullName.Substring($stagingPath.Length + 1).Replace('\', '/')
        size = $_.Length
        sha256 = Get-Sha256Hex -Path $_.FullName
      }
    }
)
$release = @{
  schemaVersion = 1
  product = 'Qiyu'
  version = $packageVersion
  architecture = 'x64'
  builtAt = [DateTime]::UtcNow.ToString('o')
  files = $manifestFiles
}
[IO.File]::WriteAllText(
  (Join-Path $stagingPath 'release.json'),
  ($release | ConvertTo-Json -Depth 4),
  [Text.UTF8Encoding]::new($false)
)

Remove-GeneratedDirectory -Path $bundlePath -ExpectedParent $hostBuildPath
Move-Item -LiteralPath $stagingPath -Destination $bundlePath

if (Test-Path -LiteralPath $archivePath) {
  if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($archivePath)) -ne `
    [IO.Path]::GetFullPath($hostBuildPath)) {
    throw "Refusing to replace unexpected archive path: $archivePath"
  }
  Remove-Item -LiteralPath $archivePath -Force
}
Compress-Archive -LiteralPath $bundlePath -DestinationPath $archivePath `
  -CompressionLevel Optimal

Write-Host "==> Windows bundle ready: $bundlePath"
Write-Host "==> Windows release archive ready: $archivePath"
