param([Parameter(Mandatory=$true)][string]$ScriptB64)
$ErrorActionPreference = 'Stop'
$bytes = [Convert]::FromBase64String($ScriptB64)
$text = [Text.Encoding]::UTF8.GetString($bytes)
$tmp = Join-Path $env:TEMP ('rsh_' + [Guid]::NewGuid().ToString('N') + '.ps1')
[IO.File]::WriteAllText($tmp, $text, [Text.Encoding]::UTF8)
$ec = 0
try {
  cmd.exe /c 'chcp 65001 > nul'
  $p = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$tmp) -NoNewWindow -PassThru -Wait
  $ec = $p.ExitCode
} finally {
  Remove-Item $tmp -Force -ErrorAction SilentlyContinue
}
Write-Output ('__RSH_EXIT__=' + $ec)
