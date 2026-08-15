$forwardedArgs = @($args)
$candidates = [System.Collections.Generic.List[string]]::new()

function Add-Candidate([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }
    $expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim('"'))
    if (-not $candidates.Contains($expanded)) {
        $candidates.Add($expanded)
    }
}

function Test-Python3([string]$Path) {
    if ($Path -like '*\Microsoft\WindowsApps\*' -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }
    try {
        $version = (& $Path --version 2>&1 | Out-String).Trim()
        return $LASTEXITCODE -eq 0 -and $version -match '^Python 3(?:\.|$)'
    }
    catch {
        return $false
    }
}

if ($env:VIRTUAL_ENV) {
    Add-Candidate (Join-Path $env:VIRTUAL_ENV 'Scripts\python.exe')
}
if ($env:CONDA_PREFIX) {
    Add-Candidate (Join-Path $env:CONDA_PREFIX 'python.exe')
}

$pyLauncher = Get-Command py.exe -ErrorAction SilentlyContinue
if ($pyLauncher) {
    & $pyLauncher.Source -0p 2>$null | ForEach-Object {
        if ($_ -match '([A-Za-z]:\\.*python(?:3(?:\.\d+)?)?\.exe)\s*$') {
            Add-Candidate $Matches[1]
        }
    }
}

foreach ($commandName in 'python.exe', 'python3.exe') {
    Get-Command $commandName -All -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.CommandType -eq 'Application') {
            Add-Candidate $_.Source
        }
    }
}

foreach ($registryRoot in 'Registry::HKEY_CURRENT_USER\Software\Python\PythonCore', 'Registry::HKEY_LOCAL_MACHINE\Software\Python\PythonCore') {
    Get-ChildItem -LiteralPath $registryRoot -ErrorAction SilentlyContinue | ForEach-Object {
        $installPath = Get-ItemProperty -LiteralPath (Join-Path $_.PSPath 'InstallPath') -ErrorAction SilentlyContinue
        if ($installPath) {
            Add-Candidate $installPath.ExecutablePath
            $directory = $installPath.'(default)'
            if ($directory) {
                Add-Candidate (Join-Path $directory 'python.exe')
            }
        }
    }
}

$commonDirectoryNames = 'Anaconda', 'Anaconda3', 'Miniconda', 'Miniconda3'
Get-PSDrive -PSProvider FileSystem | ForEach-Object {
    foreach ($directoryName in $commonDirectoryNames) {
        Add-Candidate (Join-Path $_.Root "$directoryName\python.exe")
    }
}

foreach ($pythonPath in $candidates) {
    if (Test-Python3 $pythonPath) {
        & $pythonPath (Join-Path $PSScriptRoot 'analyze_image.py') @forwardedArgs
        exit $LASTEXITCODE
    }
}

Write-Error 'No working Python 3 interpreter was found. Install Python 3 or activate a Conda/virtual environment, then retry.'
exit 1
