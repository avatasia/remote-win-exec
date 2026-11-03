<#
.SYNOPSIS
    Installs or updates the remote-win-exec channel on this machine and on the peer.
.DESCRIPTION
    Deploys three things and then verifies the channel end to end:
      * scripts\rsh-wrapper.ps1 -> $env:USERPROFILE\.ssh\rsh.ps1   (this machine)
      * the skill directory   -> $env:USERPROFILE\.minimax\skills\remote-win-exec\
      * scripts\rsh-runner.ps1  -> <peer>:bin/rsh.ps1                  (the peer)
    The wrapper is a template: its <remote-user>@<remote-host> default is
    replaced with the peer you pass in, so the deployed copy has no placeholder
    left and its own guard will not fire.
.PARAMETER RemoteHost
    The peer: user@host, or an alias from ~/.ssh/config.
.PARAMETER Check
    Report what is installed and what differs. Changes nothing.
.PARAMETER SetDefaultShell
    Also set the peer's sshd default shell to pwsh. Needs an elevated session
    on the peer; the value is read per connection, so no service restart.
.EXAMPLE
    .\scripts\install-channel.ps1 -RemoteHost 'user@host' -Check
    (run it from the skill directory, or point at the script by its full path)
.NOTES
    The peer side assumes sshd is already serving and that this machine can
    reach it with a key. See docs\openssh.md for that part.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$RemoteHost,
  [switch]$Check,
  [switch]$SetDefaultShell
)

$ErrorActionPreference = 'Stop'
$script:Changes = 0

function Say([string]$msg) { Write-Host $msg }
function Changed([string]$msg) { $script:Changes++; Write-Host ('  [changed] ' + $msg) }
function Same([string]$msg) { Write-Host ('  [same]    ' + $msg) }

function Get-Sha([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
}

# Runs an ssh command on the peer and returns its output lines.
#
# The client's stdout goes to a file, not to a pipe: with a pipe the client can
# finish the protocol and then never exit, and the installer would hang
# instead of reporting. Measured 2026-11-03 on the paired peer - see
# docs\ssh-client-behavior.md.
function Invoke-SshCapture([string]$target, [string[]]$remoteArgs, [int]$timeoutSec = 60) {
  $stamp = [Guid]::NewGuid().ToString('N')
  $outFile = Join-Path $env:TEMP ('rshinst_out_' + $stamp + '.txt')
  $errFile = Join-Path $env:TEMP ('rshinst_err_' + $stamp + '.txt')
  try {
    $argList = @('-T', '-n', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15', $target) + $remoteArgs
    $proc = Start-Process -FilePath 'ssh.exe' -PassThru -NoNewWindow -RedirectStandardOutput $outFile -RedirectStandardError $errFile -ArgumentList $argList
    if (-not $proc.WaitForExit($timeoutSec * 1000)) {
      try { $proc.Kill() } catch {}
      return @{ Lines = @(); Code = -1; TimedOut = $true }
    }
    $proc.WaitForExit()
    $lines = @()
    if (Test-Path -LiteralPath $outFile) { $lines = @(([IO.File]::ReadAllText($outFile, [Text.Encoding]::UTF8)) -split '[\r\n]+' | Where-Object { $_ -ne '' }) }
    if (Test-Path -LiteralPath $errFile) {
      $errText = [IO.File]::ReadAllText($errFile, [Text.Encoding]::UTF8).Trim()
      if ($errText) { $lines += ($errText -split '[\r\n]+' | Where-Object { $_ -ne '' }) }
    }
    return @{ Lines = $lines; Code = $proc.ExitCode; TimedOut = $false }
  }
  finally {
    Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
  }
}

# --- 1. local prerequisites -------------------------------------------------
Say '== local prerequisites =='
$sshExe = (Get-Command ssh -ErrorAction SilentlyContinue)
if ($sshExe) { Say ('  ssh client : ' + $sshExe.Source) } else { Say '  ssh client : MISSING (OpenSSH Client capability not installed)' }
$sshdSvc = Get-Service sshd -ErrorAction SilentlyContinue
if ($sshdSvc) { Say ('  sshd service: ' + $sshdSvc.Status + ' / ' + $sshdSvc.StartType) } else { Say '  sshd service: not installed (this machine cannot be logged into)' }

# --- 2. the wrapper, rendered ----------------------------------------------
# The skill root is this script's own parent directory. That is the same
# layout whether the skill sits in a repository (skills\remote-win-exec\scripts)
# or was installed on its own (~/.minimax\skills\remote-win-exec\scripts), so
# one code path serves both and nothing depends on a fixed install root.
$skillSrc = Split-Path -Parent $PSScriptRoot
$wrapperSrc = Join-Path $skillSrc 'scripts\rsh-wrapper.ps1'
$runnerSrc = Join-Path $skillSrc 'scripts\rsh-runner.ps1'
foreach ($p in @($wrapperSrc, $runnerSrc, $skillSrc)) {
  if (-not (Test-Path -LiteralPath $p)) { throw ('Missing source: ' + $p) }
}

$wrapperDst = Join-Path $env:USERPROFILE '.ssh\rsh.ps1'
$skillDst = Join-Path $env:USERPROFILE '.minimax\skills\remote-win-exec'

$rendered = [IO.File]::ReadAllText($wrapperSrc)
$rendered = $rendered.Replace('<remote-user>@<remote-host>', $RemoteHost)
if ($rendered -match '<remote-user>@<remote-host>') { throw 'Placeholder was not replaced.' }
$renderedBytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($rendered)

# the skill is deployed as a whole directory: SKILL.md + references\ + scripts\.
# Deploying SKILL.md alone would leave the links it points at broken.
$skillFiles = @()
Get-ChildItem -LiteralPath $skillSrc -Recurse -File | ForEach-Object {
  $rel = $_.FullName.Substring($skillSrc.Length).TrimStart([char]92).Replace([char]92, '/')
  $skillFiles += [pscustomobject]@{
    Rel  = $rel
    Full = $_.FullName
    Sha  = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
  }
}
$peerSkillRoot = '.minimax/skills/remote-win-exec'

Say '== this machine =='
if ($Check) {
  Say ('  wrapper -> ' + $wrapperDst + '   sha=' + (Get-Sha $wrapperDst) + ' (source sha=' + (Get-Sha $wrapperSrc) + ')')
  foreach ($f in $skillFiles) {
    $dst = Join-Path $skillDst ($f.Rel.Replace('/', [string][char]92))
    $h = Get-Sha $dst
    $flag = if ($h -eq $f.Sha) { 'same' } else { 'DIFFERS' }
    Say ('  skill   -> ' + $f.Rel + '   sha=' + $h + '  [' + $flag + ']')
  }
} else {
  New-Item -ItemType Directory -Path (Split-Path -Parent $wrapperDst) -Force | Out-Null
  $same = $false
  if (Test-Path -LiteralPath $wrapperDst) {
    $cur = [IO.File]::ReadAllBytes($wrapperDst)
    if ($cur.Length -eq $renderedBytes.Length) {
      $same = $true
      for ($i = 0; $i -lt $cur.Length; $i++) { if ($cur[$i] -ne $renderedBytes[$i]) { $same = $false; break } }
    }
  }
  if ($same) {
    Same ('wrapper already current')
  } else {
    if (Test-Path -LiteralPath $wrapperDst) {
      Copy-Item -LiteralPath $wrapperDst -Destination ($wrapperDst + '.bak') -Force
      Say ('  [backup]  ' + $wrapperDst + '.bak')
    }
    [IO.File]::WriteAllBytes($wrapperDst, $renderedBytes)
    Changed ('wrapper -> ' + $wrapperDst)
  }
  New-Item -ItemType Directory -Path $skillDst -Force | Out-Null
  foreach ($f in $skillFiles) {
    $dst = Join-Path $skillDst ($f.Rel.Replace('/', [string][char]92))
    $dstDir = Split-Path -Parent $dst
    if (-not (Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
    if ((Get-Sha $dst) -eq $f.Sha) {
      Same ('skill ' + $f.Rel + ' already current')
    } else {
      [IO.File]::Copy($f.Full, $dst, $true)
      Changed ('skill ' + $f.Rel + ' -> ' + $skillDst)
    }
  }
}

# --- 3. the peer ------------------------------------------------------------
Say '== peer =='
if (-not $Check) {
  & scp -o BatchMode=yes -o ConnectTimeout=15 $runnerSrc ($RemoteHost + ':bin/rsh.ps1')
  if ($LASTEXITCODE) { throw ('scp of the runner failed: ' + $LASTEXITCODE) }
  Changed ('runner -> ' + $RemoteHost + ':bin/rsh.ps1')

  # the peer needs the same skill directory: SKILL.md plus references\ and scripts\
  # directories to create under the peer's skill root: the root itself ('') plus
  # every subdirectory the local skill has
  $peerSubDirs = @('')
  foreach ($d in (Get-ChildItem -LiteralPath $skillSrc -Directory | Select-Object -ExpandProperty Name)) {
    $peerSubDirs += $d
  }
  $dirList = ($peerSubDirs | ForEach-Object { "'" + $_ + "'" }) -join ', '
  $mkdirCmd = @'
$ProgressPreference = 'SilentlyContinue'
$root = Join-Path $env:USERPROFILE '.minimax\skills\remote-win-exec'
$dirs = @(__DIRS__)
foreach ($d in $dirs) {
  $p = if ($d) { Join-Path $root $d } else { $root }
  New-Item -ItemType Directory -Path $p -Force | Out-Null
}
'PEER_DIRS_OK'
'@
  $mkdirCmd = $mkdirCmd.Replace('__DIRS__', $dirList)
  $b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($mkdirCmd))
  $mkdirRes = Invoke-SshCapture $RemoteHost @('powershell', '-NoProfile', '-EncodedCommand', $b64)
  Write-Host ('  ' + ($mkdirRes.Lines -join ' '))
  if ($mkdirRes.TimedOut) { throw 'the peer did not answer within the timeout while creating the skill directories' }
  if ($mkdirRes.Code) { throw ('could not create the skill directories on the peer: ' + $mkdirRes.Code) }

  foreach ($f in $skillFiles) {
    & scp -o BatchMode=yes -o ConnectTimeout=15 $f.Full ($RemoteHost + ':' + $peerSkillRoot + '/' + $f.Rel)
    if ($LASTEXITCODE) { throw ('scp of ' + $f.Rel + ' failed: ' + $LASTEXITCODE) }
    Changed ('skill ' + $f.Rel + ' -> ' + $RemoteHost)
  }

  $shaCmd = @'
$ProgressPreference = 'SilentlyContinue'
$root = Join-Path $env:USERPROFILE '.minimax\skills\remote-win-exec'
Get-ChildItem -LiteralPath $root -Recurse -File | ForEach-Object {
  $rel = $_.FullName.Substring($root.Length).TrimStart([char]92).Replace([char]92, '/')
  'SHA|' + $rel + '|' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
}
'@
  $b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($shaCmd))
  $shaRes = Invoke-SshCapture $RemoteHost @('powershell', '-NoProfile', '-EncodedCommand', $b64)
  if ($shaRes.TimedOut) { throw 'the peer did not answer within the timeout while reading the skill hashes' }
  $peerHashes = @{}
  foreach ($line in @($shaRes.Lines)) {
    if ($line -match '^SHA\|(.+)\|([0-9A-Fa-f]{64})$') { $peerHashes[$Matches[1]] = $Matches[2].ToUpper() }
  }
  foreach ($f in $skillFiles) {
    if (-not $peerHashes.ContainsKey($f.Rel)) {
      Write-Host ('  [warn]    the peer has no ' + $f.Rel)
    } elseif ($peerHashes[$f.Rel] -ne $f.Sha) {
      Write-Host ('  [warn]    the peer ' + $f.Rel + ' differs (peer ' + $peerHashes[$f.Rel].Substring(0, 8) + ', local ' + $f.Sha.Substring(0, 8) + ')')
    } else {
      Same ('peer skill ' + $f.Rel)
    }
  }
  if ($SetDefaultShell) {
    Say '  setting the peer default shell to pwsh (needs elevation there)'
    $setCmd = 'Set-ItemProperty -Path ''HKLM:\SOFTWARE\OpenSSH'' -Name DefaultShell -Value ''C:\Program Files\PowerShell\7\pwsh.exe'' -Type String; Write-Output (''PEER_SHELL='' + (Get-ItemProperty -Path ''HKLM:\SOFTWARE\OpenSSH'' -Name DefaultShell).DefaultShell)'
    $setB64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($setCmd))
    $setRes = Invoke-SshCapture $RemoteHost @('powershell', '-NoProfile', '-EncodedCommand', $setB64)
    Write-Host ('  ' + ($setRes.Lines -join ' '))
  }
} else {
  Say ('  runner -> ' + $RemoteHost + ':bin/rsh.ps1')
  Say ('  skill   -> ' + $RemoteHost + ':.minimax\skills\remote-win-exec\SKILL.md')
}

# --- 4. verify --------------------------------------------------------------
if (-not $Check) {
  Say '== verify =='
  $probe = Join-Path $env:TEMP ('rshverify_' + [Guid]::NewGuid().ToString('N') + '.ps1')
  [IO.File]::WriteAllText($probe, "Write-Output ('HOST=' + `$env:COMPUTERNAME)`r`nWrite-Output '通道中文-ok'`r`nexit 0`r`n", (New-Object System.Text.UTF8Encoding($false)))
  $out = & pwsh -NoProfile -ExecutionPolicy Bypass -File $wrapperDst -ScriptFile $probe 2>&1 | Out-String
  $code = $LASTEXITCODE
  Write-Host ('  ' + ($out -replace "`r?`n", ' | '))
  Write-Host ('  exit code: ' + $code)
  Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
  if ($code -ne 0) { throw ('Channel verification failed with exit code ' + $code) }

  $checkScript = Join-Path $skillDst 'scripts\check-channel.ps1'
  if (Test-Path -LiteralPath $checkScript) {
    Say '== channel health check (read-only) =='
    $chk = & pwsh -NoProfile -ExecutionPolicy Bypass -File $checkScript 2>&1
    $chkCode = $LASTEXITCODE
    foreach ($line in @($chk)) { Write-Host ('  ' + $line) }
    if ($chkCode -eq 1) { throw ('the channel health check reported a FAIL (exit ' + $chkCode + ')') }
  }
}

Say ('== done (' + $script:Changes + ' change(s)) ==')
