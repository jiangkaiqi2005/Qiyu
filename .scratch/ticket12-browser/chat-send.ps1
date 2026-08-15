param([string]$RequestId, [string]$Text, [string]$SessionId = '')
$ErrorActionPreference = 'Stop'
$base = 'E:\Agent\Qiyu\.scratch\ticket12-browser'
$port = (Get-Content "$base\port.txt" -Raw).Trim()
$csrf = (Get-Content "$base\csrf.txt" -Raw).Trim()
$cookieValue = (Get-Content "$base\session-cookie.txt" -Raw).Trim()
$origin = "http://127.0.0.1:$port"
$payload = @{ requestId = $RequestId; text = $Text }
if ($SessionId) { $payload['sessionId'] = $SessionId }
$body = [Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json))
$request = [Net.HttpWebRequest]::Create("$origin/api/chat")
$request.Method = 'POST'
$request.ContentType = 'application/json; charset=utf-8'
$request.Headers.Add('x-qiyu-csrf', $csrf)
$request.Headers.Add('Origin', $origin)
$request.Headers.Add('Cookie', "qiyu_session=$cookieValue")
$request.Timeout = 120000
$request.ReadWriteTimeout = 120000
$stream = $request.GetRequestStream()
$stream.Write($body, 0, $body.Length)
$stream.Close()
$response = $request.GetResponse()
$reader = New-Object -TypeName System.IO.StreamReader -ArgumentList $response.GetResponseStream(), [Text.Encoding]::UTF8
$messageText = ''
$finalSession = ''
$kinds = @()
while (-not $reader.EndOfStream) {
  $line = $reader.ReadLine()
  if (-not $line) { continue }
  $event = $line | ConvertFrom-Json
  $kinds += $event.event
  if ($event.event -eq 'message') { $messageText = ($event.messages -join '') }
  if ($event.sessionId) { $finalSession = $event.sessionId }
}
$reader.Close()
$response.Close()
Write-Output "kinds: $($kinds -join ',')"
Write-Output "sessionId: $finalSession"
Write-Output "reply: $messageText"