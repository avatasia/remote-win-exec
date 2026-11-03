<#
.SYNOPSIS
    Read-only health check for the remote-win-exec channel.
.DESCRIPTION
    Checks what can be checked without changing anything on either machine:
      * which side of the channel this machine is on (wrapper present or not)
      * which peer the channel is pointed at
      * key-based SSH reachability to the peer
      * the peer's runner and skill files
      * the peer's SSH default shell
      * one end-to-end probe through the channel
    Writes nothing. Creates nothing. Removes nothing. It only reads local
    files and runs read-only commands on the peer.
    Every ssh call is bounded by a hard timeout, so a call that never returns
    is reported instead of hanging the check.
.PARAMETER RemoteHost
    The peer to check, as user@host or an alias from ~/.ssh/config. Defaults to
    the wrapper's own destination; on the peer side (no wrapper) it defaults to
    the only ~/.ssh/config entry that carries both User and IdentityFile. If
    several entries qualify, the script reports them instead of guessing.
.PARAMETER TimeoutSec
    Hard limit for each ssh call. Default 20 seconds.
.EXAMPLE
    pwsh -NoProfile -ExecutionPolicy Bypass -File "<skill-dir>\scripts\check-channel.ps1"
.OUTPUTS
    One line per check:  OK|WARN|FAIL|<check>|<detail>|<action>
    Last line:            CHECK_SUMMARY ok=<n> warn=<n> fail=<n>
    Exit code: 0 all OK, 1 at least one FAIL, 2 warnings only.
#>
[CmdletBinding()]
param(
  [string]$RemoteHost,
  [int]$TimeoutSec = 20
)

$ErrorActionPreference = 'Stop'

$script:Ok = 0
$script:Warn = 0
$script:Fail = 0

function Report([string]$status, [string]$check, [string]$detail, [string]$action) {
  switch ($status) {
    'OK'   { $script:Ok++ }
    'WARN' { $script:Warn++ }
    'FAIL' { $script:Fail++ }
  }
  Write-Output ($status + '|' + $check + '|' + $detail + '|' + $action)
}

# Every ssh call goes through here, with a hard timeout: an ssh that
# authenticates, runs the command and then never returns is a real failure mode,
# and a health check must report it rather than hang on it.
function Invoke-SshBounded([string]$target, [string]$remoteCommand, [int]$timeoutSec) {
  # The client's stdout goes to a FILE, never to a .NET pipe: with a pipe the
  # ssh client finishes the protocol and then never exits (measured 2026-11-03).
  $stamp = [Guid]::NewGuid().ToString('N')
  $outFile = Join-Path $env:TEMP ('rshchk_out_' + $stamp + '.txt')
  $errFile = Join-Path $env:TEMP ('rshchk_err_' + $stamp + '.txt')
  # ssh joins the remaining arguments into one remote command, so the pieces are
  # passed separately and no quoting is needed.
  $argList = @('-T','-n','-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','ConnectTimeout=10',$target) + @($remoteCommand -split ' ')
  $proc = Start-Process -FilePath 'ssh.exe' -PassThru -NoNewWindow -RedirectStandardOutput $outFile -RedirectStandardError $errFile -ArgumentList $argList
  if (-not $proc.WaitForExit($timeoutSec * 1000)) {
    try { $proc.Kill() } catch {}
    Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{ Text = ''; Code = -1; TimedOut = $true }
  }
  $proc.WaitForExit()
  $code = $proc.ExitCode
  $out = ''
  if (Test-Path -LiteralPath $outFile) { $out = [IO.File]::ReadAllText($outFile, [Text.Encoding]::UTF8) }
  $err = ''
  if (Test-Path -LiteralPath $errFile) { $err = [IO.File]::ReadAllText($errFile, [Text.Encoding]::UTF8) }
  Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
  return [pscustomobject]@{ Text = (($out + [Environment]::NewLine + $err).Trim()); Code = $code; TimedOut = $false }
}

# --- 1. which side am I on -------------------------------------------------
$wrapper   = Join-Path $env:USERPROFILE '.ssh\rsh.ps1'
# This script lives in the skill's own scripts\ directory, so the skill root is
# one level up - the same whether the skill was installed on its own or shipped
# inside a plugin.
$skillRoot = Split-Path -Parent $PSScriptRoot
$hasWrapper = Test-Path -LiteralPath $wrapper
$role = if ($hasWrapper) { 'originating' } else { 'peer' }
Report 'OK' 'role' ("this machine is the " + $role + " side (wrapper " + $(if ($hasWrapper) { 'present' } else { 'absent' }) + ")") 'no action'

# --- 2. the ~/.ssh/config entries -----------------------------------------
$entries = @()
$configPath = Join-Path $env:USERPROFILE '.ssh\config'
if (Test-Path -LiteralPath $configPath) {
  $cur = $null
  foreach ($line in [IO.File]::ReadAllLines($configPath)) {
    $t = $line.Trim()
    if ($t -eq '' -or $t.StartsWith('#')) { continue }
    if ($t -match '^(?i)Host\s+(.+)$') {
      if ($null -ne $cur) { $entries += $cur }
      $cur = [pscustomobject]@{ Alias = ($Matches[1].Trim() -split '\s+')[0]; User = $null; HostName = $null; IdentityFile = $null }
      continue
    }
    if ($null -eq $cur) { continue }
    if ($t -match '^(?i)User\s+(.+)$') { $cur.User = $Matches[1].Trim() }
    elseif ($t -match '^(?i)HostName\s+(.+)$') { $cur.HostName = $Matches[1].Trim() }
    elseif ($t -match '^(?i)IdentityFile\s+(.+)$') { $cur.IdentityFile = $Matches[1].Trim() }
  }
  if ($null -ne $cur) { $entries += $cur }
}

# --- 3. which peer does the channel point at -------------------------------
$target = $null
$source = ''
if ($RemoteHost) {
  $target = $RemoteHost
  $source = '-RemoteHost'
}
elseif ($hasWrapper) {
  # the wrapper carries the destination the channel was installed with
  $m = [regex]::Match([IO.File]::ReadAllText($wrapper), "\`$RemoteHost\s*=\s*'([^']+)'")
  if ($m.Success -and $m.Groups[1].Value -notmatch '<') {
    $target = $m.Groups[1].Value
    $source = "the wrapper's own destination"
  }
}
else {
  $candidates = @($entries | Where-Object { $_.User -and $_.IdentityFile })
  if ($candidates.Count -eq 1) {
    $target = $candidates[0].User + '@' + $candidates[0].Alias
    $source = 'the only ~/.ssh/config entry with User and IdentityFile'
  }
  elseif ($candidates.Count -gt 1) {
    Report 'WARN' 'ssh-config' ('several config entries qualify (' + (($candidates | ForEach-Object { $_.Alias }) -join ', ') + ') and this machine has no wrapper to name the peer') 're-run with -RemoteHost <user>@<alias> (the paired Windows machine)'
  }
}

if ($target) {
  $alias = ($target -split '@')[-1]
  $entry = @($entries | Where-Object { $_.Alias -eq $alias })[0]
  $detail = 'peer ' + $target
  if ($null -ne $entry) {
    $hostLabel = if ($entry.HostName) { $entry.HostName } else { $entry.Alias }
    $detail += ' (host=' + $hostLabel + ', user=' + $entry.User + ', key=' + (Split-Path -Leaf $entry.IdentityFile) + ')'
  }
  Report 'OK' 'ssh-config' ($detail + ' — ' + $source) 'no action'
}
elseif (-not $RemoteHost -and -not $hasWrapper) {
  # already reported above
}
else {
  Report 'FAIL' 'ssh-config' 'the channel destination could not be determined' 'setup: pass -RemoteHost <user>@<alias>'
}

# --- 4. ssh client ---------------------------------------------------------
$sshCmd = Get-Command ssh -ErrorAction SilentlyContinue
if ($null -eq $sshCmd) {
  Report 'FAIL' 'ssh-client' 'ssh is not on PATH' 'setup: install the OpenSSH Client capability'
}
else {
  Report 'OK' 'ssh-client' $sshCmd.Source 'no action'
}

# --- 5. peer reachability --------------------------------------------------
$reachable = $false
if ($target -and $null -ne $sshCmd) {
  $probe = Invoke-SshBounded $target 'echo RSH_OK' $TimeoutSec
  if ($probe.TimedOut) {
    Report 'FAIL' 'ssh-reachable' ('ssh to ' + $target + ' did not return within ' + $TimeoutSec + ' s') 'the ssh client never came back; see references/troubleshooting.md (reverse direction)'
  }
  elseif ($probe.Code -eq 0 -and $probe.Text -match 'RSH_OK') {
    $reachable = $true
    Report 'OK' 'ssh-reachable' ('key-based ssh to ' + $target + ' works') 'no action'
  }
  else {
    Report 'FAIL' 'ssh-reachable' ('ssh to ' + $target + ' failed, exit=' + $probe.Code + ' output=' + ($probe.Text -replace '[\r\n]+', ' ')) 'setup: the key exchange or sshd on the peer is wrong (publickey / known_hosts / service down)'
  }
}

# --- 6. peer-side facts ----------------------------------------------------
function Invoke-PeerScript([string]$script) {
  $b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
  return Invoke-SshBounded $target ('powershell -NoProfile -EncodedCommand ' + $b64) $TimeoutSec
}

if ($reachable -and $target) {
  $runnerProbe = Invoke-PeerScript @'
$ProgressPreference = 'SilentlyContinue'
$p = Join-Path $env:USERPROFILE 'bin\rsh.ps1'
'RUNNER=' + (Test-Path -LiteralPath $p)
'@
  if (-not $hasWrapper) {
    # the runner lives on the channel peer, and from the peer side the other
    # machine is the originating side, which never has one
    Report 'OK' 'peer-runner' 'not applicable here: the runner lives on the other side of the channel' 'no action'
  }
  elseif ($runnerProbe.TimedOut) {
    Report 'FAIL' 'peer-runner' ('the peer probe did not return within ' + $TimeoutSec + ' s') 'see references/troubleshooting.md'
  }
  elseif ($runnerProbe.Text -match 'RUNNER=True') {
    Report 'OK' 'peer-runner' 'the peer has bin\rsh.ps1' 'no action'
  }
  elseif ($runnerProbe.Text -match 'RUNNER=False') {
    Report 'FAIL' 'peer-runner' 'the peer has no bin\rsh.ps1' 'setup: deploy the runner to the peer (install-channel.ps1)'
  }
  else {
    Report 'WARN' 'peer-runner' ('could not read the peer state: ' + ($runnerProbe.Text -replace '[\r\n]+', ' ')) 'retry the check'
  }

  $skillProbe = Invoke-PeerScript @'
$ProgressPreference = 'SilentlyContinue'
$root = Join-Path $env:USERPROFILE '.minimax\skills\remote-win-exec'
$f = Join-Path $root 'SKILL.md'
$h = ''
if (Test-Path -LiteralPath $f) { $h = (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash }
'PEERSKILL=' + (Test-Path -LiteralPath $f) + '|' + $h
'@
  $peerSkillHash = ''
  if (-not $skillProbe.TimedOut -and $skillProbe.Text -match 'PEERSKILL=True\|([0-9A-Fa-f]{64})') { $peerSkillHash = $Matches[1].ToUpper() }
  $localSkill = Join-Path $skillRoot 'SKILL.md'
  $localHash = ''
  if (Test-Path -LiteralPath $localSkill) { $localHash = (Get-FileHash -LiteralPath $localSkill -Algorithm SHA256).Hash }
  if ($peerSkillHash -and $localHash -and $peerSkillHash -ne $localHash) {
    Report 'WARN' 'peer-skill' ('the two sides run different skill copies (local ' + $localHash.Substring(0, 8) + ', peer ' + $peerSkillHash.Substring(0, 8) + ')') 'setup: redeploy the skill to both sides so they match'
  }
  elseif ($peerSkillHash -and $localHash) {
    Report 'OK' 'peer-skill' ('both sides run the same skill copy (' + $localHash.Substring(0, 8) + ')') 'no action'
  }
  else {
    Report 'WARN' 'peer-skill' ('could not compare the skill copies (local=' + $localHash + ' peer=' + $peerSkillHash + ')') 'retry the check'
  }

  $shellProbe = Invoke-PeerScript @'
$ProgressPreference = 'SilentlyContinue'
$v = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -ErrorAction SilentlyContinue).DefaultShell
if ($v) { 'SHELL=' + $v } else { 'SHELL=<unset>' }
'@
  if (-not $shellProbe.TimedOut -and $shellProbe.Text -match 'SHELL=(.+)') {
    Report 'OK' 'peer-shell' ('the peer SSH default shell is ' + $Matches[1].Trim()) 'no action - the wrapper adapts to it'
  }
  else {
    Report 'WARN' 'peer-shell' ('could not read the peer default shell: ' + ($shellProbe.Text -replace '[\r\n]+', ' ')) 'retry the check'
  }
}

# --- 7. end-to-end probe ---------------------------------------------------
try {
  if ($hasWrapper) {
    $probe = & pwsh -NoProfile -ExecutionPolicy Bypass -File $wrapper -Script 'Write-Output "RSH_PROBE_OK"' 2>&1
    $probeCode = $LASTEXITCODE
    $probeText = (@($probe) -join [Environment]::NewLine)
  }
  elseif ($target) {
    $probe = Invoke-PeerScript 'Write-Output ''RSH_PROBE_OK'''
    $probeCode = $probe.Code
    $probeText = $probe.Text
  }
  else {
    # no peer to talk to: that is a "cannot tell" case, not a broken channel
    Report 'WARN' 'probe' 'skipped: no peer to probe (see the ssh-config line)' 're-run with -RemoteHost <user>@<alias>'
    $probeText = ''
    $probeCode = -2
  }
  if ($probeCode -eq -2) {
    # already reported above
  }
  elseif ($probeText -match 'RSH_PROBE_OK' -and $probeCode -eq 0) {
    Report 'OK' 'probe' 'a payload ran through the channel and returned its output' 'no action'
  }
  elseif ($probeText -match 'RSH_PROBE_OK') {
    Report 'WARN' 'probe' ('the payload ran but the exit code came back as ' + $probeCode) 'check the exit-code path (see references/troubleshooting.md)'
  }
  else {
    Report 'FAIL' 'probe' ('the end-to-end probe produced no output (exit=' + $probeCode + ')') 'the channel is not usable: read references/troubleshooting.md'
  }
}
catch {
  Report 'FAIL' 'probe' ('the probe raised: ' + $_.Exception.Message) 'read references/troubleshooting.md'
}

Write-Output ('CHECK_SUMMARY ok=' + $script:Ok + ' warn=' + $script:Warn + ' fail=' + $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
elseif ($script:Warn -gt 0) { exit 2 }
else { exit 0 }
