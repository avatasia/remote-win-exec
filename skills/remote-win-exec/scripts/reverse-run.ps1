<#
.SYNOPSIS
    Runs a PowerShell command on the other machine of the pair over plain SSH.
.DESCRIPTION
    The peer side of the channel has no wrapper, so commands go back over plain
    ssh. Two rules make that path reliable:

      * The ssh client's stdout must be a FILE, not a .NET pipe. With a pipe the
        client completes the protocol (channel freed, exit status received) and
        then never exits - measured 2026-11-03, on any target, so a caller's
        PowerShell capture ($out = & ssh ...) hangs forever. Redirecting to a
        file makes the same command exit in about a second.
      * The exit code travels in the __RSH_EXIT__ marker: the remote shell does
        not pass on a nested PowerShell's status (cmd.exe does, PowerShell does
        not).

    The command runs in a child PowerShell, so 'exit N' inside it is captured
    exactly instead of killing the session before the marker is written.
.PARAMETER Command
    PowerShell to run on the other machine.
.PARAMETER RemoteHost
    The other machine: user@host or an alias from ~/.ssh/config. Defaults to
    the wrapper's own destination, or to the config entry whose HostName is one
    of this machine's addresses.
.PARAMETER TimeoutSec
    Hard limit for the ssh call. Default 30 seconds.
.EXAMPLE
    pwsh -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.minimax\skills\remote-win-exec\scripts\reverse-run.ps1" -Command 'Get-Date'
.OUTPUTS
    The remote stdout verbatim; the remote stderr on stderr.
    Exit code: the remote command's exit code.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Command,
  [string]$RemoteHost,
  [int]$TimeoutSec = 30
)

$ErrorActionPreference = 'Stop'

function Get-ThisMachineAddresses {
  try {
    @(Get-NetIPAddress -AddressFamily IPv4 |
      Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
      ForEach-Object { $_.IPAddress })
  } catch { @() }
}

# --- 1. resolve the other machine ------------------------------------------
$target = $RemoteHost
if (-not $target) {
  $wrapper = Join-Path $env:USERPROFILE '.ssh\rsh.ps1'
  if (Test-Path -LiteralPath $wrapper) {
    $pattern = [regex]::Escape('$RemoteHost') + '\s*=\s*\x27([^\x27]+)\x27'
    $m = [regex]::Match([IO.File]::ReadAllText($wrapper), $pattern)
    if ($m.Success -and $m.Groups[1].Value -notmatch '<') { $target = $m.Groups[1].Value }
  }
}
if (-not $target) {
  $configPath = Join-Path $env:USERPROFILE '.ssh\config'
  if (Test-Path -LiteralPath $configPath) {
    $addrs = Get-ThisMachineAddresses
    $cur = $null
    foreach ($line in [IO.File]::ReadAllLines($configPath)) {
      $t = $line.Trim()
      if ($t -eq '' -or $t.StartsWith('#')) { continue }
      if ($t -match '^(?i)Host\s+(.+)$') {
        if ($null -ne $cur -and $cur.HostName -and ($addrs -contains $cur.HostName)) {
          $target = $cur.User + '@' + $cur.Alias
        }
        $cur = [pscustomobject]@{ Alias = ($Matches[1].Trim() -split '\s+')[0]; User = $null; HostName = $null }
        continue
      }
      if ($null -eq $cur) { continue }
      if ($t -match '^(?i)User\s+(.+)$') { $cur.User = $Matches[1].Trim() }
      elseif ($t -match '^(?i)HostName\s+(.+)$') { $cur.HostName = $Matches[1].Trim() }
    }
    if ($null -ne $cur -and $cur.HostName -and ($addrs -contains $cur.HostName)) {
      $target = $cur.User + '@' + $cur.Alias
    }
  }
}
if (-not $target) {
  Write-Error 'Could not determine the other machine. Pass -RemoteHost <user>@<alias>.'
  exit 2
}

# --- 2. build the remote payload ------------------------------------------
$childScript = '[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new(); ' +
               '$OutputEncoding = [System.Text.UTF8Encoding]::new(); ' + $Command
$childB64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childScript))
$payload = @'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$OutputEncoding = [System.Text.UTF8Encoding]::new()
$code = 0
try {
  & (Get-Process -Id $PID).Path -NoProfile -EncodedCommand __CHILD__
  $code = $LASTEXITCODE
} catch {
  Write-Output ('__RSH_ERROR__=' + $_.Exception.Message)
  $code = 1
}
Write-Output ('__RSH_EXIT__=' + $code)
exit 0
'@
$payload = $payload.Replace('__CHILD__', $childB64)
$payloadB64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($payload))

# --- 3. run it, with the client's stdout redirected to a file ---------------
$stamp = [Guid]::NewGuid().ToString('N')
$outFile = Join-Path $env:TEMP ('rshrev_out_' + $stamp + '.txt')
$errFile = Join-Path $env:TEMP ('rshrev_err_' + $stamp + '.txt')

# The redirection to files is the whole point: a .NET pipe makes this client
# stall after the session completes.
# -T: the payload is a command, never a terminal session. -n: stdin comes
# from NUL, so the client never waits on the console - the symptom the
# upstream hang reports describe. The file redirection below is what keeps the
# client from stalling in its teardown.
$argList = @('-T','-n','-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','ConnectTimeout=10',
             $target,'powershell','-NoProfile','-EncodedCommand',$payloadB64)
$proc = Start-Process -FilePath 'ssh.exe' -PassThru -NoNewWindow -RedirectStandardOutput $outFile -RedirectStandardError $errFile -ArgumentList $argList

if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
  try { $proc.Kill() } catch {}
  Write-Error ('ssh to ' + $target + ' did not return within ' + $TimeoutSec + ' s')
  exit 124
}
$proc.WaitForExit()
$remoteExit = $proc.ExitCode

# --- 4. read the result ----------------------------------------------------
$stdout = ''
if (Test-Path -LiteralPath $outFile) { $stdout = [IO.File]::ReadAllText($outFile, [Text.Encoding]::UTF8) }
$stderr = ''
if (Test-Path -LiteralPath $errFile) { $stderr = [IO.File]::ReadAllText($errFile, [Text.Encoding]::UTF8) }

$code = 0
$kept = @()
foreach ($line in ($stdout -split '[\r\n]+')) {
  if ($line -match '^__RSH_EXIT__=(\d+)$') { $code = [int]$Matches[1]; continue }
  if ($line -match '^__RSH_ERROR__=(.*)$') { $stderr += [Environment]::NewLine + $Matches[1]; continue }
  $kept += $line
}
$text = ($kept -join [Environment]::NewLine).TrimEnd()
if ($text) { Write-Output $text }
if ($stderr.Trim()) { [Console]::Error.WriteLine($stderr.TrimEnd()) }

Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue

if ($code -eq 0 -and $remoteExit -ne 0) { $code = $remoteExit }
exit $code
