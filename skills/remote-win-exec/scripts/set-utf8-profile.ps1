<#
.SYNOPSIS
    Reports, or optionally adds, the UTF-8 console lines in a PowerShell profile.
.DESCRIPTION
    The channel does not need this. The remote runner already switches the console
    code page to 65001 before it launches a payload, so everything that travels
    through the channel is UTF-8. What a profile changes is the *interactive*
    shell: a person at a prompt, or a program started by hand, still gets the
    system ANSI code page (936 on a Chinese Windows) and sees garbled Chinese.

    So this is opt-in and off by default: with no switch the script only reports
    what the profile currently holds. With -Apply it appends the two lines after
    backing the file up, and it never touches the system ANSI code page.

    Idempotent: the block carries a marker, and the script also recognises a
    profile that already sets a UTF-8 console by hand, so neither case gets a
    second copy of the two lines.

    Payloads that travel through the channel are started with -NoProfile, so they
    never see this block either way.
.PARAMETER Apply
    Write the block. Without it the script only reports.
.PARAMETER ProfilePath
    The profile file to work on. Defaults to $PROFILE.CurrentUserCurrentHost.
    Pass it explicitly for the other profile files: Windows PowerShell 5.1 has
    its own set, and an AllUsers profile applies to every account on the box.
.EXAMPLE
    .\set-utf8-profile.ps1
.EXAMPLE
    .\set-utf8-profile.ps1 -Apply
.EXAMPLE
    .\set-utf8-profile.ps1 -Apply -ProfilePath 'C:\Users\<user>\Documents\PowerShell\profile.ps1'
#>
[CmdletBinding()]
param(
  [switch]$Apply,
  [string]$ProfilePath
)

$ErrorActionPreference = 'Stop'

$marker = '# --- UTF-8 console (remote-win-exec skill) ---'
$crlf = [string][char]13 + [string][char]10
$lf = [string][char]10

if (-not $ProfilePath) { $ProfilePath = $PROFILE.CurrentUserCurrentHost }

# Reads a profile and remembers the encoding it was written in, so writing it
# back does not silently change the encoding underneath the user.
function Read-Profile([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) {
    return @{ Text = ''; Encoding = (New-Object System.Text.UTF8Encoding($false)); Exists = $false }
  }
  $bytes = [IO.File]::ReadAllBytes($path)
  if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    return @{ Text = [Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3); Encoding = (New-Object System.Text.UTF8Encoding($true)); Exists = $true }
  }
  if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
    return @{ Text = [Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2); Encoding = [Text.Encoding]::Unicode; Exists = $true }
  }
  if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
    return @{ Text = [Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, $bytes.Length - 2); Encoding = [Text.Encoding]::BigEndianUnicode; Exists = $true }
  }
  return @{ Text = [Text.Encoding]::UTF8.GetString($bytes); Encoding = (New-Object System.Text.UTF8Encoding($false)); Exists = $true }
}

$state = Read-Profile $ProfilePath
Write-Output ('PROFILE|' + $ProfilePath + '|exists=' + $state.Exists)

# Judge by what the profile actually does, not by the marker: a profile that
# already sets a UTF-8 console (written by hand, or by an earlier version of
# this script) must not get a second copy of the two lines.
$hasMarker = $state.Text.Contains($marker)
$hasChcp = $state.Text -match 'chcp\s+65001'
$hasEncoding = ($state.Text -match '\$OutputEncoding\s*=') -and ($state.Text -match '\[Console\]::OutputEncoding')

if ($hasChcp -and $hasEncoding) {
  Write-Output 'OK|profile|the profile already sets a UTF-8 console|nothing to do'
  exit 0
}

if ($hasMarker) {
  Write-Output 'WARN|profile|the marker is there but the two UTF-8 lines are not|fix it by hand; -Apply will not add a second copy'
  exit 0
}

if (-not $Apply) {
  Write-Output 'OK|profile|no UTF-8 block|optional: -Apply adds it, the channel does not need it'
  exit 0
}

$dir = Split-Path -Parent $ProfilePath
if ($dir -and -not (Test-Path -LiteralPath $dir)) {
  New-Item -ItemType Directory -Path $dir -Force | Out-Null
}

$backup = $null
if ($state.Exists) {
  $backup = $ProfilePath + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
  Copy-Item -LiteralPath $ProfilePath -Destination $backup -Force
}

$nl = if ($state.Text.Contains($crlf)) { $crlf } elseif ($state.Text.Contains($lf)) { $lf } else { [Environment]::NewLine }
$text = $state.Text
if ($text.Length -gt 0) {
  if (-not $text.EndsWith($nl)) { $text += $nl }
  $text += $nl
}
$text += (@(
  $marker
  'chcp 65001 > $null'
  '$OutputEncoding = [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)'
) -join $nl) + $nl

[IO.File]::WriteAllText($ProfilePath, $text, $state.Encoding)

$check = Read-Profile $ProfilePath
if (-not ($check.Text.Contains($marker) -and ($check.Text -match 'chcp\s+65001'))) {
  throw ('the block did not land in ' + $ProfilePath)
}

if ($backup) {
  Write-Output ('CHANGED|profile|the UTF-8 block was added|backup: ' + $backup)
}
else {
  Write-Output 'CHANGED|profile|the UTF-8 block was added|no previous file, so no backup'
}
Write-Output 'NOTE|profile|new shells start with a UTF-8 console|shells that are already open keep the old code page'
Write-Output 'NOTE|profile|the system ANSI code page was not changed|only the console code page and the PowerShell output encoding'
