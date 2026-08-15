# Ticket 12 浏览器真实测试：启动 bundle Host，兑换会话，配置 DeepSeek Provider。
# 凭据逐项落盘；任何一步失败立即退出，不覆盖已有凭据。
$ErrorActionPreference = 'Stop'
$base = 'E:\Agent\Qiyu\.scratch\ticket12-browser'
$exe = 'E:\Agent\Qiyu\apps\qiyu_windows_host\build\windows-bundle\qiyu_windows_host.exe'

Remove-Item "$base\host-stdout.txt", "$base\host-stderr.txt" -Force -ErrorAction SilentlyContinue
$proc = Start-Process -FilePath $exe `
  -ArgumentList @('--no-browser', '--runtime-dir', "$base\runtime", '--memory-dir', "$base\memory") `
  -WorkingDirectory ([IO.Path]::GetTempPath()) -WindowStyle Hidden `
  -RedirectStandardOutput "$base\host-stdout.txt" `
  -RedirectStandardError "$base\host-stderr.txt" -PassThru
Set-Content -Path "$base\host-pid.txt" -Value $proc.Id -Encoding ascii

$url = ''
$deadline = [DateTime]::UtcNow.AddSeconds(15)
do {
  Start-Sleep -Milliseconds 400
  $text = Get-Content -Raw -Encoding UTF8 "$base\host-stdout.txt" -ErrorAction SilentlyContinue
  if ($text) {
    $match = [regex]::Match($text, 'http://127\.0\.0\.1:\d+/_session/start\?token=[A-Za-z0-9_-]+')
    if ($match.Success) { $url = $match.Value }
  }
} while (-not $url -and -not $proc.HasExited -and [DateTime]::UtcNow -lt $deadline)
if (-not $url) { throw 'Host 未发布启动 URL' }
$port = [regex]::Match($url, '127\.0\.0\.1:(\d+)').Groups[1].Value
$origin = "http://127.0.0.1:$port"
Set-Content -Path "$base\port.txt" -Value $port -Encoding ascii

$ws = New-Object Microsoft.PowerShell.Commands.WebRequestSession
$null = Invoke-WebRequest -Uri $url -WebSession $ws -MaximumRedirection 5 -UseBasicParsing
$cookie = $ws.Cookies.GetCookies($origin) | Where-Object { $_.Name -eq 'qiyu_session' } | Select-Object -First 1
if (-not $cookie) { throw '未获得会话 cookie' }
Set-Content -Path "$base\session-cookie.txt" -Value $cookie.Value -Encoding ascii

$boot = Invoke-RestMethod -Uri "$origin/api/bootstrap" -WebSession $ws
if (-not $boot.csrfToken) { throw 'bootstrap 未返回 csrfToken' }
Set-Content -Path "$base\csrf.txt" -Value $boot.csrfToken -Encoding ascii

$headers = @{ 'x-qiyu-csrf' = $boot.csrfToken; 'Origin' = $origin }
$body = @{
  provider = 'openai_compatible'
  baseUrl = 'https://api.deepseek.com/v1'
  model = 'deepseek-chat'
  temperature = 0.7
  timeoutSeconds = 60
  apiKey = $env:Qiyu_API_KEY
} | ConvertTo-Json
$saved = Invoke-RestMethod -Uri "$origin/api/provider" -Method Put -WebSession $ws `
  -Headers $headers -Body $body -ContentType 'application/json; charset=utf-8'
Write-Output "provider-saved: $($saved | ConvertTo-Json -Compress -Depth 4)"

$test = Invoke-RestMethod -Uri "$origin/api/provider/test" -Method Post -WebSession $ws `
  -Headers $headers -Body '{}' -ContentType 'application/json'
Write-Output "provider-test: $($test | ConvertTo-Json -Compress)"
if ($test.ok -ne $true) { throw 'Provider 连通测试失败' }
Write-Output 'SETUP_OK'
