<#
.SYNOPSIS
    Regression for the forward direction of the channel (this machine -> peer).
.DESCRIPTION
    Drives the local wrapper end to end and checks what actually comes back:
    the text (decoded from UTF-8, GBK and UTF-16 bytes), the stderr and the
    exit code. It is the forward counterpart of test-reverse.ps1.

    Every case sends exact bytes, so the check is about the transport and the
    decoder, not about a lucky round trip: the payload writes a byte sequence
    on the remote's standard output and the test compares what the wrapper
    decoded it back to.

    The exit code has to arrive through the runner's __RSH_EXIT__ marker,
    because a remote PowerShell does not pass on a nested process's status.
.PARAMETER RemoteHost
    The peer: user@host or an alias from ~/.ssh/config. Defaults to the
    destination of the installed wrapper.
.PARAMETER TimeoutSec
    Hard limit for the whole run. Default 180 seconds.
.EXAMPLE
    pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-forward.ps1 -RemoteHost 'user@peer'
#>
[CmdletBinding()]
param(
  [string]$RemoteHost,
  [int]$TimeoutSec = 180
)

$ErrorActionPreference = 'Stop'
$script:Pass = 0
$script:Fail = 0
# The skill root is one level up: the script lives in the skill's scripts\ dir.
$script:Root = Split-Path -Parent $PSScriptRoot
$script:Wrapper = Join-Path $script:Root 'scripts\rsh-wrapper.ps1'

if (-not (Test-Path -LiteralPath $script:Wrapper)) {
  Write-Host ('FAIL|setup|the wrapper is missing: ' + $script:Wrapper)
  exit 1
}

# The destination: the caller's, else the installed wrapper's.
$target = $RemoteHost
if (-not $target) {
  $installed = Join-Path $env:USERPROFILE '.ssh\rsh.ps1'
  if (Test-Path -LiteralPath $installed) {
    $m = [regex]::Match([IO.File]::ReadAllText($installed), "\$RemoteHost\s*=\s*'([^']+)'")
    if ($m.Success -and $m.Groups[1].Value -notmatch '<') { $target = $m.Groups[1].Value }
  }
}
if (-not $target) {
  Write-Host 'FAIL|setup|no peer given and the installed wrapper names none; pass -RemoteHost <user>@<alias>'
  exit 1
}

# The Chinese text is built from code points so this file stays pure ASCII:
# nothing here can be damaged by a code page on the way to the peer.
$script:Text = [string]::Concat([char]0x901A, [char]0x9053, [char]0x4E2D, [char]0x6587) + '-ok'
$script:NiHao = [string]::Concat([char]0x4F60, [char]0x597D)

function Get-Hex([byte[]]$bytes) {
  return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

# The payload: write the given bytes to the remote's standard output, then
# exit with the given code. Byte exact, so the decoder is what is tested.
function New-Payload([string]$hex, [int]$code) {
  return @'
$hex = '__HEX__'
$bytes = [byte[]]::new($hex.Length / 2)
for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = [Convert]::ToByte($hex.Substring($i * 2, 2), 16) }
$out = [Console]::OpenStandardOutput()
$out.Write($bytes, 0, $bytes.Length)
$out.Flush()
exit __CODE__
'@.Replace('__HEX__', $hex).Replace('__CODE__', [string]$code)
}

# The payload for the stderr case.
function New-StderrPayload([string]$text, [int]$code) {
  return @'
[Console]::Error.WriteLine('__TEXT__')
exit __CODE__
'@.Replace('__TEXT__', $text).Replace('__CODE__', [string]$code)
}

function Invoke-Case([string]$name, [string]$payloadText, [int]$expectExit, [string]$expectText) {
  $payload = Join-Path $env:TEMP ('rshfwd_' + [Guid]::NewGuid().ToString('N') + '.ps1')
  [IO.File]::WriteAllText($payload, $payloadText, (New-Object System.Text.UTF8Encoding($false)))
  $out = & pwsh -NoProfile -ExecutionPolicy Bypass -File $script:Wrapper -RemoteHost $target -ScriptFile $payload 2>&1
  $code = $LASTEXITCODE
  $text = (@($out) -join [Environment]::NewLine)
  Remove-Item -LiteralPath $payload -Force -ErrorAction SilentlyContinue

  $okExit = ($code -eq $expectExit)
  $okText = if ($expectText) { $text.Contains($expectText) } else { $true }
  if ($okExit -and $okText) {
    $script:Pass++
    Write-Host ('PASS|' + $name + '|exit=' + $code + '|text ok')
  }
  else {
    $script:Fail++
    $shown = $text -replace '[\r\n]+', ' '
    if ($shown.Length -gt 200) { $shown = $shown.Substring(0, 200) }
    Write-Host ('FAIL|' + $name + '|exit=' + $code + ' (want ' + $expectExit + ')|text=' + $shown)
  }
}

Write-Host ('== forward direction regression (this machine -> ' + $target + ') ==')

$utf8 = Get-Hex ([Text.Encoding]::UTF8.GetBytes($script:Text))
$gbk = Get-Hex ([Text.Encoding]::GetEncoding(936).GetBytes($script:Text))
$utf16 = Get-Hex ([Text.Encoding]::Unicode.GetBytes($script:Text))
$ambiguous = Get-Hex ([Text.Encoding]::GetEncoding(936).GetBytes($script:NiHao))

Invoke-Case 'utf8-bytes'   (New-Payload $utf8 0) 0 $script:Text
Invoke-Case 'gbk-bytes'    (New-Payload $gbk 0) 0 $script:Text
Invoke-Case 'utf16-bytes'  (New-Payload $utf16 0) 0 $script:Text
Invoke-Case 'gbk-ambiguous' (New-Payload $ambiguous 0) 0 $script:NiHao
Invoke-Case 'exit-code'    (New-Payload $utf8 7) 7 $script:Text
Invoke-Case 'stderr'       (New-StderrPayload 'remote-stderr-text' 3) 3 'remote-stderr-text'

# A payload past the wrapper's inline limit goes through scp; it has to come
# back with the same text and the same exit code.
$big = $utf8 + (Get-Hex ([Text.Encoding]::UTF8.GetBytes(('x' * 20000))))
Invoke-Case 'large-payload' (New-Payload $big 0) 0 $script:Text

Write-Host ('TOTAL pass=' + $script:Pass + ' fail=' + $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
exit 0
