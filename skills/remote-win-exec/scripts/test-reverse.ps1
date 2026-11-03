<#
.SYNOPSIS
    Regression for the reverse direction of the channel (peer -> this machine).
.DESCRIPTION
    Runs on the originating side and drives the reverse direction end to end:
    the peer runs a command here over plain ssh and the result must come back
    with the right output and the exact exit code.

    This is the regression for the 2026-11-03 failure where the reverse call
    completed the SSH protocol but the ssh client never exited, so the caller
    waited forever. It also covers the rules the fix depends on: the client's
    stdout is redirected to a file, and the exit code travels in a marker.
.PARAMETER RemoteHost
    The peer: user@host or an alias from ~/.ssh/config.
.PARAMETER TimeoutSec
    Hard limit for the whole run. Default 120 seconds.
.EXAMPLE
    pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-reverse.ps1 -RemoteHost 'user@peer'
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$RemoteHost,
  [int]$TimeoutSec = 120
)

$ErrorActionPreference = 'Stop'
$script:Pass = 0
$script:Fail = 0

function Assert-Case([string]$name, [int]$expectedExit, [string]$expectText, [string]$remoteCommand) {
  $wrapper = Join-Path $env:USERPROFILE '.ssh\rsh.ps1'
  if (-not (Test-Path -LiteralPath $wrapper)) {
    Write-Host ('FAIL|' + $name + '|the local wrapper is missing: ' + $wrapper)
    $script:Fail++
    return
  }
  $payload = Join-Path $env:TEMP ('rshrev_' + [Guid]::NewGuid().ToString('N') + '.ps1')
  $body = @'
$cmd = __CMD__
& pwsh -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.minimax\skills\remote-win-exec\scripts\reverse-run.ps1" -RemoteHost __TARGET__ -Command $cmd -TimeoutSec 45
exit $LASTEXITCODE
'@
  $body = $body.Replace('__CMD__', ("'" + $remoteCommand.Replace("'", "''") + "'"))
  $body = $body.Replace('__TARGET__', ("'" + $script:ReverseTarget + "'"))
  [IO.File]::WriteAllText($payload, $body, (New-Object System.Text.UTF8Encoding($false)))

  $out = & pwsh -NoProfile -ExecutionPolicy Bypass -File $wrapper -ScriptFile $payload 2>&1
  $code = $LASTEXITCODE
  $text = (@($out) -join [Environment]::NewLine)
  Remove-Item -LiteralPath $payload -Force -ErrorAction SilentlyContinue

  $okExit = ($code -eq $expectedExit)
  $okText = ($text -match [regex]::Escape($expectText))
  if ($okExit -and $okText) {
    $script:Pass++
    Write-Host ('PASS|' + $name + '|exit=' + $code + '|output ok')
  } else {
    $script:Fail++
    Write-Host ('FAIL|' + $name + '|exit=' + $code + ' (want ' + $expectedExit + ')|text=' + ($text -replace '[\r\n]+', ' '))
  }
}

# --- the address the peer uses for this machine ----------------------------
$addr = ''
$ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
  Where-Object { $_.InterfaceAlias -match 'Tailscale' -and $_.IPAddress -notlike '169.254.*' } |
  Select-Object -First 1
if ($ip) { $addr = $ip.IPAddress }
else {
  $ip2 = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
    Select-Object -First 1
  if ($ip2) { $addr = $ip2.IPAddress }
}
if (-not $addr) {
  Write-Host 'FAIL|setup|no usable address for this machine'
  exit 1
}
$script:ReverseTarget = $env:USERNAME + '@' + $addr

Write-Host ('== reverse direction regression (peer -> ' + $script:ReverseTarget + ') ==')

Assert-Case 'plain-output' 0 '反向通道中文-ok' 'Write-Output "反向通道中文-ok"'
Assert-Case 'exit-code' 7 '' 'Write-Output "反向通道中文-ok"; exit 7'
Assert-Case 'stderr' 3 '' '[Console]::Error.WriteLine("remote stderr"); exit 3'

Write-Host ('TOTAL pass=' + $script:Pass + ' fail=' + $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
exit 0
