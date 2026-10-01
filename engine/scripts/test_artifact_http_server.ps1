#Requires -Version 7.2
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Archive,[Parameter(Mandatory)][string]$ReadyFile,
      [ValidateRange(1,60)][int]$LifetimeSeconds=30)
$ErrorActionPreference='Stop'
$listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
$listener.Start()
try {
  $port=([Net.IPEndPoint]$listener.LocalEndpoint).Port
  [IO.File]::WriteAllText([IO.Path]::GetFullPath($ReadyFile),[string]$port)
  $deadline=[DateTime]::UtcNow.AddSeconds($LifetimeSeconds)
  while ([DateTime]::UtcNow -lt $deadline) {
    if (-not $listener.Pending()) {Start-Sleep -Milliseconds 20;continue}
    $client=$listener.AcceptTcpClient()
    try {
      $client.ReceiveTimeout=2000; $client.SendTimeout=2000
      $stream=$client.GetStream()
      $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::ASCII,$false,1024,$true)
      $request=$reader.ReadLine()
      while (($line=$reader.ReadLine())) {}
      $reader.Dispose()
      $bytes=[IO.File]::ReadAllBytes([IO.Path]::GetFullPath($Archive))
      $partial=$request -match ' /partial '
      $redirect=$request -match ' /redirect '
      if ($redirect) {$header="HTTP/1.1 302 Found`r`nLocation: /valid`r`nContent-Length: 0`r`nConnection: close`r`n`r`n"}
      else {$header="HTTP/1.1 200 OK`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n"}
      $head=[Text.Encoding]::ASCII.GetBytes($header);$stream.Write($head,0,$head.Length)
      if (-not $redirect) {
        $count=if ($partial) {[Math]::Max(1,[int]($bytes.Length/2))} else {$bytes.Length}
        $stream.Write($bytes,0,$count)
      }
    } finally {$client.Dispose()}
  }
} finally {$listener.Stop()}
