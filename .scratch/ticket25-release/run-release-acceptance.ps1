[CmdletBinding()]
param([string]$BundlePath)

$ErrorActionPreference = 'Stop'

function Assert-Condition {
  param(
    [Parameter(Mandatory = $true)][bool]$Condition,
    [Parameter(Mandatory = $true)][string]$Message
  )
  if (-not $Condition) {
    throw $Message
  }
}

function Start-QiyuHost {
  param(
    [Parameter(Mandatory = $true)][string]$ExecutablePath,
    [Parameter(Mandatory = $true)][string]$RuntimeDirectory,
    [Parameter(Mandatory = $true)][string]$MemoryDirectory,
    [Parameter(Mandatory = $true)][string]$OutputPrefix
  )

  $stdoutPath = "$OutputPrefix.stdout.txt"
  $stderrPath = "$OutputPrefix.stderr.txt"
  Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force `
    -ErrorAction SilentlyContinue
  $process = Start-Process -FilePath $ExecutablePath `
    -ArgumentList @(
      '--no-browser',
      '--runtime-dir', $RuntimeDirectory,
      '--memory-dir', $MemoryDirectory
    ) `
    -WorkingDirectory ([IO.Path]::GetTempPath()) `
    -WindowStyle Hidden `
    -RedirectStandardOutput $stdoutPath `
    -RedirectStandardError $stderrPath `
    -PassThru
  $deadline = [DateTime]::UtcNow.AddSeconds(15)
  do {
    Start-Sleep -Milliseconds 200
    $text = if (Test-Path -LiteralPath $stdoutPath) {
      [string](Get-Content -Raw -Encoding UTF8 $stdoutPath)
    } else {
      ''
    }
    $launchUrl = [regex]::Match(
      $text,
      'http://127\.0\.0\.1:\d+/_session/start\?token=[A-Za-z0-9_-]+'
    ).Value
  } while (
    -not $launchUrl -and
    -not $process.HasExited -and
    [DateTime]::UtcNow -lt $deadline
  )
  if (-not $launchUrl) {
    $errorText = if (Test-Path -LiteralPath $stderrPath) {
      [string](Get-Content -Raw -Encoding UTF8 $stderrPath)
    } else {
      ''
    }
    throw "宿主没有发布启动地址：$errorText"
  }
  return [pscustomobject]@{
    Process = $process
    LaunchUrl = $launchUrl
    Origin = ([Uri]$launchUrl).GetLeftPart([UriPartial]::Authority)
    StdoutPath = $stdoutPath
    StderrPath = $stderrPath
  }
}

function Stop-QiyuHost {
  param($HostProcess)
  if ($null -eq $HostProcess -or $HostProcess.Process.HasExited) {
    return
  }
  $expectedPath = [IO.Path]::GetFullPath($HostProcess.Process.Path)
  if ($expectedPath -notmatch '(?i)qiyu_windows_host\.exe$') {
    throw "拒绝停止意外进程：$expectedPath"
  }
  Stop-Process -Id $HostProcess.Process.Id -Force
  $HostProcess.Process.WaitForExit()
}

function Open-QiyuSession {
  param([Parameter(Mandatory = $true)]$HostProcess)
  $webSession = New-Object Microsoft.PowerShell.Commands.WebRequestSession
  Invoke-WebRequest -Uri $HostProcess.LaunchUrl -WebSession $webSession `
    -MaximumRedirection 5 -UseBasicParsing | Out-Null
  $bootstrap = Invoke-WebRequest `
    -Uri "$($HostProcess.Origin)/api/bootstrap" `
    -WebSession $webSession `
    -Headers @{ Referer = "$($HostProcess.Origin)/" } `
    -UseBasicParsing
  $json = $bootstrap.Content | ConvertFrom-Json
  return [pscustomobject]@{
    WebSession = $webSession
    CsrfToken = $json.csrfToken
    Origin = $HostProcess.Origin
  }
}

function Invoke-QiyuMutation {
  param(
    [Parameter(Mandatory = $true)]$Session,
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Body,
    [string]$Method = 'POST'
  )
  return Invoke-WebRequest -Uri "$($Session.Origin)$Path" `
    -Method $Method `
    -WebSession $Session.WebSession `
    -Headers @{
      Origin = $Session.Origin
      'x-qiyu-csrf' = $Session.CsrfToken
    } `
    -ContentType 'application/json; charset=utf-8' `
    -Body ([Text.Encoding]::UTF8.GetBytes($Body)) `
    -UseBasicParsing
}

function Get-ResponseStatus {
  param(
    [Parameter(Mandatory = $true)][scriptblock]$Request
  )
  try {
    return [int](& $Request).StatusCode
  } catch [Net.WebException] {
    if ($null -eq $_.Exception.Response) {
      throw
    }
    return [int]$_.Exception.Response.StatusCode
  }
}

function Read-ChatEvents {
  param([Parameter(Mandatory = $true)]$Content)
  $text = if ($Content -is [byte[]] -or $Content -is [object[]]) {
    [Text.Encoding]::UTF8.GetString([byte[]]$Content)
  } else {
    [string]$Content
  }
  return @(
    $text -split "`r?`n" |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
      ForEach-Object { $_ | ConvertFrom-Json }
  )
}

function Get-ChatEvent {
  param(
    [Parameter(Mandatory = $true)][array]$Events,
    [Parameter(Mandatory = $true)][string]$Type
  )
  return $Events | Where-Object event -eq $Type | Select-Object -Last 1
}

function Test-LanConnectionRefused {
  param([Parameter(Mandatory = $true)][int]$Port)
  $lanAddress = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object {
      $_.IPAddress -ne '127.0.0.1' -and
      $_.IPAddress -notlike '169.254.*'
    } |
    Select-Object -First 1 -ExpandProperty IPAddress
  if ([string]::IsNullOrWhiteSpace($lanAddress)) {
    return $null
  }
  $client = New-Object Net.Sockets.TcpClient
  try {
    $task = $client.ConnectAsync($lanAddress, $Port)
    if (-not $task.Wait(1500)) {
      return $true
    }
    return -not $client.Connected
  } catch {
    return $true
  } finally {
    $client.Dispose()
  }
}

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if ([string]::IsNullOrWhiteSpace($BundlePath)) {
  $BundlePath = Join-Path $repositoryRoot `
    'apps\qiyu_windows_host\build\windows-bundle'
}
$workRoot = Join-Path $PSScriptRoot 'work'
$installRoot = Join-Path $workRoot 'installed\Qiyu'
$dataRoot = Join-Path $workRoot 'profile\.qiyu'
$memoryRoot = Join-Path $dataRoot 'memories'
$runtimeRoot = Join-Path $workRoot 'local-app-data\Qiyu'
$startMenuRoot = Join-Path $workRoot 'start-menu'
$desktopRoot = Join-Path $workRoot 'desktop'
$backupPath = Join-Path $workRoot 'qiyu-backup.zip'
$reportPath = Join-Path $PSScriptRoot 'acceptance-results.json'
$providerBaseUrl = 'https://ticket25@api.deepseek.com/v1'
$providerScope = 'openai_compatible|https://ticket25@api.deepseek.com/v1?#'
$scopeHasher = [Security.Cryptography.SHA256]::Create()
try {
  $providerScopeHash = ($scopeHasher.ComputeHash(
    [Text.Encoding]::UTF8.GetBytes($providerScope)
  ) | ForEach-Object { $_.ToString('x2') }) -join ''
} finally {
  $scopeHasher.Dispose()
}
$credentialTarget = "Qiyu.Provider.ApiKey.$providerScopeHash"
$credentialExistedBefore = ((& cmdkey.exe /list) -join "`n") -match `
  [regex]::Escape($credentialTarget)
Assert-Condition (-not $credentialExistedBefore) `
  '隔离的 Provider 验收凭据 target 已存在，拒绝覆盖。'
$primary = $null
$restart = $null
$portPeer = $null

if (Test-Path -LiteralPath $workRoot) {
  $resolvedWork = [IO.Path]::GetFullPath($workRoot)
  $resolvedScratch = [IO.Path]::GetFullPath($PSScriptRoot)
  if (-not $resolvedWork.StartsWith(
    $resolvedScratch,
    [StringComparison]::OrdinalIgnoreCase
  )) {
    throw "拒绝清理意外目录：$resolvedWork"
  }
  Remove-Item -LiteralPath $resolvedWork -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $workRoot | Out-Null

$results = [ordered]@{
  generatedAt = [DateTime]::UtcNow.ToString('o')
  baseline = '547734b'
  environment = [ordered]@{
    os = [Environment]::OSVersion.VersionString
    is64Bit = [Environment]::Is64BitOperatingSystem
    cleanVmExecuted = $false
    cleanVmReason = '当前会话无管理员权限，Windows Sandbox 状态查询被系统拒绝。'
  }
}

try {
  $bundle = [IO.Path]::GetFullPath($BundlePath)
  & (Join-Path $bundle 'Install-Qiyu.ps1') `
    -InstallRoot $installRoot `
    -StartMenuRoot $startMenuRoot `
    -DesktopRoot $desktopRoot `
    -NoLaunch
  $installedExe = Join-Path $installRoot 'qiyu_windows_host.exe'
  Assert-Condition (Test-Path -LiteralPath $installedExe) '真实安装失败。'

  $oldPath = $env:PATH
  try {
    $env:PATH = "$env:SystemRoot\System32;$env:SystemRoot"
    $preflightText = & $installedExe --check
  } finally {
    $env:PATH = $oldPath
  }
  $preflight = $preflightText | ConvertFrom-Json
  Assert-Condition $preflight.ready '无开发工具 PATH 下预检失败。'
  $results.install = [ordered]@{
    installed = $true
    preflightWithoutDevPath = $preflight.ready
    startMenuShortcut = Test-Path -LiteralPath (Join-Path $startMenuRoot '栖语.lnk')
    desktopShortcut = Test-Path -LiteralPath (Join-Path $desktopRoot '栖语.lnk')
  }

  $primary = Start-QiyuHost -ExecutablePath $installedExe `
    -RuntimeDirectory $runtimeRoot -MemoryDirectory $memoryRoot `
    -OutputPrefix (Join-Path $workRoot 'host-1')
  $session = Open-QiyuSession -HostProcess $primary
  $offlineResponse = Invoke-QiyuMutation -Session $session -Path '/api/chat' `
    -Body (@{ requestId = 'ticket25-offline'; text = '今天有点累' } |
      ConvertTo-Json -Compress)
  $offlineEvents = Read-ChatEvents -Content $offlineResponse.Content
  $offlineState = Get-ChatEvent -Events $offlineEvents -Type 'state'
  $accepted = Get-ChatEvent -Events $offlineEvents -Type 'accepted'
  Assert-Condition ($offlineState.source -eq 'local') `
    "离线聊天没有使用本地引擎：source=$($offlineState.source)，events=$(
      ($offlineEvents | ForEach-Object event) -join ','
    )"
  Assert-Condition ($offlineState.fallbackReason -eq 'no_llm_config') `
    '未配置 Provider 时没有给出预期降级原因。'
  $sessionId = $accepted.sessionId

  $listener = Get-NetTCPConnection -State Listen -OwningProcess $primary.Process.Id |
    Where-Object LocalPort -eq ([Uri]$primary.Origin).Port |
    Select-Object -First 1
  Assert-Condition ($listener.LocalAddress -eq '127.0.0.1') `
    '宿主没有只监听 127.0.0.1。'
  $badOrigin = Get-ResponseStatus {
    Invoke-WebRequest -Uri "$($primary.Origin)/api/bootstrap" `
      -WebSession $session.WebSession `
      -Headers @{ Origin = 'https://evil.example' } `
      -UseBasicParsing
  }
  $badHost = Get-ResponseStatus {
    Invoke-WebRequest -Uri "$($primary.Origin)/api/bootstrap" `
      -WebSession $session.WebSession `
      -Headers @{ Host = 'evil.example'; Referer = "$($primary.Origin)/" } `
      -UseBasicParsing
  }
  # Windows PowerShell 5 会把自定义 Host 留在 WebRequestSession；移除安全
  # 负例注入的请求头，继续使用已建立且启动凭据只消费一次的会话。
  [void]$session.WebSession.Headers.Remove('Host')
  [void]$session.WebSession.Headers.Remove('Origin')
  [void]$session.WebSession.Headers.Remove('x-qiyu-csrf')
  $missingCsrf = Get-ResponseStatus {
    Invoke-WebRequest -Uri "$($primary.Origin)/api/session/verify" `
      -Method POST -WebSession $session.WebSession `
      -Headers @{ Origin = $session.Origin } `
      -UseBasicParsing
  }
  $forgedMutation = Get-ResponseStatus {
    Invoke-WebRequest -Uri "$($primary.Origin)/api/session/verify" `
      -Method POST `
      -Headers @{
        Origin = $session.Origin
        'x-qiyu-csrf' = $session.CsrfToken
      } `
      -UseBasicParsing
  }
  Assert-Condition ($badOrigin -eq 403) '异常 Origin 未被拒绝。'
  Assert-Condition ($badHost -eq 403) '异常 Host 未被拒绝。'
  Assert-Condition ($missingCsrf -eq 403) '缺失 CSRF 的修改请求未被拒绝。'
  Assert-Condition ($forgedMutation -eq 401) '伪造无会话修改请求未被拒绝。'
  $lanRefused = Test-LanConnectionRefused -Port ([Uri]$primary.Origin).Port
  Assert-Condition ($lanRefused -ne $false) '宿主可经非回环地址访问。'

  $secondOutput = Join-Path $workRoot 'single-instance.stdout.txt'
  $secondError = Join-Path $workRoot 'single-instance.stderr.txt'
  $second = Start-Process -FilePath $installedExe `
    -ArgumentList @(
      '--no-browser', '--runtime-dir', $runtimeRoot,
      '--memory-dir', $memoryRoot
    ) `
    -WorkingDirectory ([IO.Path]::GetTempPath()) -WindowStyle Hidden `
    -RedirectStandardOutput $secondOutput `
    -RedirectStandardError $secondError -PassThru -Wait
  Assert-Condition ($second.ExitCode -eq 0) '第二实例没有正常转交主实例。'
  Assert-Condition ((Get-Content -Raw -Encoding UTF8 $secondOutput) -match '已在运行') `
    '第二实例没有报告已有实例。'

  if ([string]::IsNullOrWhiteSpace($env:Qiyu_API_KEY)) {
    throw '环境变量 Qiyu_API_KEY 不存在，不能执行真实 Provider 验收。'
  }
  $providerBody = @{
    provider = 'openai_compatible'
    baseUrl = $providerBaseUrl
    model = 'deepseek-chat'
    temperature = 0.6
    timeoutSeconds = 60
    apiKey = $env:Qiyu_API_KEY
  } | ConvertTo-Json -Compress
  $providerSave = Invoke-QiyuMutation -Session $session -Path '/api/provider' `
    -Method PUT -Body $providerBody
  Assert-Condition ($providerSave.Content -notmatch [regex]::Escape($env:Qiyu_API_KEY)) `
    'Provider 保存响应泄露了 API Key。'
  $providerSnapshot = $providerSave.Content | ConvertFrom-Json
  Assert-Condition $providerSnapshot.keySet 'Provider Key 没有写入安全存储。'
  $providerChat = Invoke-QiyuMutation -Session $session -Path '/api/chat' `
    -Body (@{ requestId = 'ticket25-provider'; sessionId = $sessionId; text = '在吗' } |
      ConvertTo-Json -Compress)
  $providerEvents = Read-ChatEvents -Content $providerChat.Content
  $providerState = Get-ChatEvent -Events $providerEvents -Type 'state'
  Assert-Condition ($providerState.source -eq 'llm') '真实 Provider 聊天没有成功。'

  Invoke-WebRequest -Uri "$($session.Origin)/api/backup/export" `
    -WebSession $session.WebSession `
    -Headers @{ Referer = "$($session.Origin)/" } `
    -OutFile $backupPath -UseBasicParsing
  $backupBytes = [IO.File]::ReadAllBytes($backupPath)
  Assert-Condition ($backupBytes.Length -gt 100) '导出的备份为空。'

  Stop-QiyuHost -HostProcess $primary
  $primary = $null
  $oldOrigin = $session.Origin
  $restart = Start-QiyuHost -ExecutablePath $installedExe `
    -RuntimeDirectory $runtimeRoot -MemoryDirectory $memoryRoot `
    -OutputPrefix (Join-Path $workRoot 'host-2')
  [void]$session.WebSession.Headers.Remove('Host')
  [void]$session.WebSession.Headers.Remove('Origin')
  [void]$session.WebSession.Headers.Remove('x-qiyu-csrf')
  $oldSessionStatus = Get-ResponseStatus {
    Invoke-WebRequest -Uri "$($restart.Origin)/api/bootstrap" `
      -WebSession $session.WebSession `
      -Headers @{ Referer = "$($restart.Origin)/" } `
      -UseBasicParsing
  }
  Assert-Condition ($oldSessionStatus -eq 401) '宿主重启后旧会话仍然有效。'
  $restartedSession = Open-QiyuSession -HostProcess $restart
  $providerRead = Invoke-WebRequest -Uri "$($restart.Origin)/api/provider" `
    -WebSession $restartedSession.WebSession `
    -Headers @{ Referer = "$($restart.Origin)/" } -UseBasicParsing
  $providerAfterRestart = $providerRead.Content | ConvertFrom-Json
  Assert-Condition ($providerAfterRestart.configured -and $providerAfterRestart.keySet) `
    '宿主重启后 Provider 或 Key 未保留。'
  Assert-Condition ($providerRead.Content -notmatch [regex]::Escape($env:Qiyu_API_KEY)) `
    'Provider 读取响应泄露了 API Key。'
  $restoredSession = Invoke-WebRequest `
    -Uri "$($restart.Origin)/api/chat/session?sessionId=$sessionId" `
    -WebSession $restartedSession.WebSession `
    -Headers @{ Referer = "$($restart.Origin)/" } -UseBasicParsing
  $restoredSessionJson = $restoredSession.Content | ConvertFrom-Json
  Assert-Condition ($restoredSessionJson.turns.Count -ge 4) '重启后聊天没有恢复。'

  $portPeerRuntime = Join-Path $workRoot 'peer-runtime'
  $portPeerMemory = Join-Path $workRoot 'peer-data\memories'
  $portPeer = Start-QiyuHost -ExecutablePath $installedExe `
    -RuntimeDirectory $portPeerRuntime -MemoryDirectory $portPeerMemory `
    -OutputPrefix (Join-Path $workRoot 'host-peer')
  Assert-Condition (([Uri]$portPeer.Origin).Port -ne ([Uri]$restart.Origin).Port) `
    '并行隔离宿主没有避开已占用端口。'
  Stop-QiyuHost -HostProcess $portPeer
  $portPeer = $null

  Stop-QiyuHost -HostProcess $restart
  $restart = $null
  Remove-Item -LiteralPath $memoryRoot -Recurse -Force
  $restart = Start-QiyuHost -ExecutablePath $installedExe `
    -RuntimeDirectory $runtimeRoot -MemoryDirectory $memoryRoot `
    -OutputPrefix (Join-Path $workRoot 'host-3')
  $restoreSession = Open-QiyuSession -HostProcess $restart
  $backupBase64 = [Convert]::ToBase64String($backupBytes)
  $preview = Invoke-QiyuMutation -Session $restoreSession `
    -Path '/api/backup/preview' `
    -Body (@{ dataBase64 = $backupBase64 } | ConvertTo-Json -Compress)
  $previewJson = $preview.Content | ConvertFrom-Json
  Assert-Condition ($previewJson.counts.added -gt 0) '空目录预览没有识别备份内容。'
  $import = Invoke-QiyuMutation -Session $restoreSession `
    -Path '/api/backup/import' `
    -Body (@{ dataBase64 = $backupBase64 } | ConvertTo-Json -Compress)
  $importJson = $import.Content | ConvertFrom-Json
  Assert-Condition ($importJson.added -gt 0) '备份恢复没有导入文件。'

  Stop-QiyuHost -HostProcess $restart
  $restart = $null
  & (Join-Path $bundle 'Install-Qiyu.ps1') `
    -InstallRoot $installRoot `
    -StartMenuRoot $startMenuRoot `
    -DesktopRoot $desktopRoot `
    -NoLaunch
  Assert-Condition (Test-Path -LiteralPath $memoryRoot) '升级删除了恢复后的 Markdown。'

  $credentialBeforeUninstall = ((& cmdkey.exe /list) -join "`n") -match `
    [regex]::Escape($credentialTarget)
  Assert-Condition $credentialBeforeUninstall 'Provider Key 未出现在 Windows 安全存储。'

  & (Join-Path $installRoot 'Uninstall-Qiyu.ps1') `
    -InstallRoot $installRoot -DataRoot $dataRoot -RuntimeRoot $runtimeRoot `
    -StartMenuRoot $startMenuRoot -DesktopRoot $desktopRoot `
    -CredentialTargetPrefix $credentialTarget -KeepData
  Assert-Condition (Test-Path -LiteralPath $memoryRoot) '保留数据卸载删除了 Markdown。'
  Assert-Condition (((& cmdkey.exe /list) -join "`n") -match `
    [regex]::Escape($credentialTarget)) '保留数据卸载删除了 Provider Key。'

  & (Join-Path $bundle 'Install-Qiyu.ps1') `
    -InstallRoot $installRoot `
    -StartMenuRoot $startMenuRoot `
    -DesktopRoot $desktopRoot `
    -NoLaunch
  & (Join-Path $installRoot 'Uninstall-Qiyu.ps1') `
    -InstallRoot $installRoot -DataRoot $dataRoot -RuntimeRoot $runtimeRoot `
    -StartMenuRoot $startMenuRoot -DesktopRoot $desktopRoot `
    -CredentialTargetPrefix $credentialTarget -RemoveData
  Assert-Condition (-not (Test-Path -LiteralPath $installRoot)) '彻底卸载未删除程序。'
  Assert-Condition (-not (Test-Path -LiteralPath $dataRoot)) '彻底卸载未删除数据。'
  Assert-Condition (-not (((& cmdkey.exe /list) -join "`n") -match `
    [regex]::Escape($credentialTarget))) '彻底卸载未删除 Provider Key。'

  $results.functional = [ordered]@{
    offlineChat = [ordered]@{
      passed = $true
      source = $offlineState.source
      fallbackReason = $offlineState.fallbackReason
    }
    providerChat = [ordered]@{
      passed = $true
      source = $providerState.source
      keyRedacted = $true
    }
    restartPersistence = [ordered]@{
      passed = $true
      restoredTurns = $restoredSessionJson.turns.Count
      providerConfigured = $providerAfterRestart.configured
      keySet = $providerAfterRestart.keySet
    }
    backupRestore = [ordered]@{
      passed = $true
      archiveBytes = $backupBytes.Length
      previewAdded = $previewJson.counts.added
      imported = $importJson.added
    }
  }
  $results.security = [ordered]@{
    loopbackListener = $listener.LocalAddress
    lanConnectionRefused = $lanRefused
    abnormalHostStatus = $badHost
    abnormalOriginStatus = $badOrigin
    missingCsrfStatus = $missingCsrf
    forgedMutationStatus = $forgedMutation
    oldSessionAfterRestartStatus = $oldSessionStatus
  }
  $results.resilience = [ordered]@{
    singleInstancePassed = $true
    dynamicPortAvoidedCompetition = $true
    unexpectedExitRecoveredByRestart = ($oldOrigin -ne $null)
    browserFailure = '由 host_runner_test 的 copyable local URL 用例验证；实机默认浏览器可用，未破坏系统关联来制造失败。'
    osRestart = '未重启当前用户机器；验证了进程强制退出后重启留存，安装器未写开机自启，用户从快捷方式重新启动。'
  }
  $results.uninstall = [ordered]@{
    keepDataPassed = $true
    removeDataPassed = $true
    credentialRemoved = $true
  }
  $results.overall = 'passed_with_environment_limits'
} finally {
  Stop-QiyuHost -HostProcess $primary
  Stop-QiyuHost -HostProcess $restart
  Stop-QiyuHost -HostProcess $portPeer
  if (
    $results.overall -ne 'passed_with_environment_limits' -and
    -not $credentialExistedBefore
  ) {
    & cmdkey.exe "/delete:$credentialTarget" 2>$null | Out-Null
  }
  [IO.File]::WriteAllText(
    $reportPath,
    ($results | ConvertTo-Json -Depth 8),
    [Text.UTF8Encoding]::new($false)
  )
}

Write-Host "Release acceptance completed: $reportPath"
