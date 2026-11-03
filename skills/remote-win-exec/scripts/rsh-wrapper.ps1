<#
.SYNOPSIS
    Send a PowerShell script to the remote host (<remote-host>) over SSH and run it there.
.DESCRIPTION
    This is the LOCAL side of the remote script channel. The remote side is
    C:\Users\<remote-user>\bin\rsh.ps1 on <remote-host>: it decodes the base64 payload, runs it as a
    temporary .ps1 in a child process, cleans up, and prints a marker line
    '__RSH_EXIT__=<code>' carrying the script's real exit code.

    Why the marker instead of ssh's exit status: the exit status a remote shell
    reports for a nested process is not the payload's own code. Measured 2026-11-03
    on a paired Windows host: under a PowerShell default shell it comes back as 1
    whatever the payload did, and under cmd.exe it only happens to match.
    The marker carries the true code across that boundary; this wrapper strips the
    marker from the output and exits with the real code.

    Small scripts travel as base64 on the command line. Large ones are copied with
    scp instead, because the Windows command line caps around 32 KB and base64
    inflates by 4/3.

    Output is read as raw bytes and decoded here rather than by the shell: ssh's
    stdout carries whatever the remote wrote (UTF-8 from PowerShell, GBK from a
    legacy program), and letting the console code page decode it mangles one or
    the other. See Convert-BytesToText for the per-line rule.

.PARAMETER Script
    Inline script text (may span multiple lines).
.PARAMETER ScriptFile
    Path to a local .ps1 file to send instead of inline text.
.PARAMETER RemoteHost
    SSH destination. Defaults to <remote-user>@<remote-host>.
.EXAMPLE
    .\rsh.ps1 -Script 'Write-Output "hi"'
.EXAMPLE
    .\rsh.ps1 -ScriptFile C:\temp\work.ps1
#>
param(
  [string]$Script,
  [string]$ScriptFile,
  [string]$RemoteHost = '<remote-user>@<remote-host>'
)

$ErrorActionPreference = 'Stop'

# This copy ships with the destination as a placeholder. Fill it in before use
# (or pass -RemoteHost) so a run cannot silently target a placeholder name.
if ($RemoteHost -match '<remote') {
  throw 'Set the destination first: edit $RemoteHost in this file, or pass -RemoteHost <user>@<host>.'
}

# The local ANSI code page (936 on a Chinese Windows). Used as the second
# candidate when detecting the charset of the remote's output.
function Get-AnsiCodePage {
  try {
    $cp = [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage
    if ($cp -gt 0) { [void][System.Text.Encoding]::GetEncoding($cp); return $cp }
  } catch { }
  try { [void][System.Text.Encoding]::GetEncoding(936); return 936 } catch { }
  return 0
}

# Scores how plausible a decoded string is as genuine text.
#
# The point is to recognise the mojibake signature: UTF-8 bytes read as GBK
# come out as characters like 鏂板細涓€鎵囩獥, dominated by rare CJK-extension
# ideographs, the CP936 euro sign (U+20AC, which CP936 maps from the single
# byte 0x80) and private-use characters. Real text is dominated by ASCII,
# common CJK and ordinary punctuation, none of which score negative.
# The characters that actually show up in Chinese text.
#
# Counting characters is not enough to tell real Chinese from mojibake: a GBK
# reading of UTF-8 Chinese yields *more* characters (3 bytes become 1.5 hanzi)
# so the wrong reading can out-score the right one - measured 2026-11-03, that
# mangled 4 of 10 realistic Chinese lines. What separates them is *which*
# characters appear: the mojibake ones are rarely the common ones. So a hanzi
# that is not in this set scores negative.
$script:CommonHanzi = New-Object 'System.Collections.Generic.HashSet[char]'
foreach ($ch in '的一是了我不人在他有这个上们来到时大地为子中你说生国年着就那和要她出也得里后自以会家可下而过天去能对小多然于心学么之都好看起发当没成只如事把还用第样道想作种开美总从无情己面最女但现前些所同日手又行意动方期它头经长儿回位分爱老因很给名法间斯知世什次使身者被高已亲其进此话常与活正感见明问力理尔点文几定本公特做外孩相西果走将月十实向声车全信重三机工物气每并别真打太新比才便夫再书部水像眼等体却加电主界门利海受听表德少克代员许稜先口由死安写性马光白或住难望教命花结乐色更拉东神记处让母父应直字场平报友关放至张认接告入笑内英军候民岁往何度山觉路带万男边风解叫任金快原吃妈变通师立象数四失满战远格士音轻目条呢病始达深完今提求清王化空业思切怎非找片罗钱紶吗语元喜曾离飞科言干流欢约各即指合反题必该论交终林请医晚制球决窢传画保读运及则房早院量苦火布品近坐产答星精视五连司巴奇管类未朋且婚台夜青北队久乎越观落尽形影红爸百令周吧识步希亚术留市半热送兴造谈容极随演收首根讲整式取照办强石古华諣拿计您装似足双妻尼转诉米称丽客南领节衣站黑刻统断福城故历惊脸选包紧争另建维绝树系伤示愿持千史谁准联妇纪基买志静阿诗独复痛消社算义竟确酒需单治卡幸兰念举仅钟怕共毛句息功官待究跟穿室易游程号居考突皮哪费倒价图具刚脑永歌响商礼细专黄块脚味灵改据般破引食仍存众注笔甚某沉血备习校默务土微娘须试怀料调广蜖苏显赛查密议底列富梦错座参八除跑亮假印设线温虽掉京初养香停际致阳纸李纳验助激够严证帝饭忘趣支春集丈木研班普导顿睡展跳获艺六波察群皇段急庭创区奥器谢弟店否害草排背止组州朝封睛板角况曲馆育忙质河续哥呼若推境遇雨标姐充围案伦护冷警贝著查技术编码测试提交通道适配无法连接远程仓库版本文件目录命令参数脚本输出错误警告修复更新依赖配置统计完成版本中文乱码默认探测安装部署运行结果内容字符编码检测环境机器通道脚本执行失败成功数量状态读取写入保存路径系统用户主机密钥证书服务端口规则防火墙权限账户组管理员提权后台进程线程内存性能并发超时重试缓存队列日志异常堆栈调用栈接口请求响应报文负载均衡主从备份快照归档清理回收恢复回滚发布版本号标记偏移量边界条件分支循环递归遍历排序查找插入删除合并拆分'.ToCharArray()) { [void]$script:CommonHanzi.Add($ch) }
function Measure-TextPlausibility([string]$text) {
  if ([string]::IsNullOrEmpty($text)) { return 0.0 }
  $score = 0.0
  for ($i = 0; $i -lt $text.Length; $i++) {
    $c = [int]$text[$i]
    # A supplementary character (emoji, rare CJK extension B) is a surrogate
    # pair in .NET strings. Score the code point, not the two halves -
    # otherwise an emoji looks like two broken characters and drags the whole
    # UTF-8 reading down.
    if ($c -ge 0xD800 -and $c -le 0xDBFF -and ($i + 1) -lt $text.Length) {
      $low = [int]$text[$i + 1]
      if ($low -ge 0xDC00 -and $low -le 0xDFFF) {
        $cp = 0x10000 + (($c - 0xD800) -shl 10) + ($low - 0xDC00)
        if ($cp -ge 0x1F000) { $score += 5.0 } else { $score += 2.0 }
        $i++
        continue
      }
    }
    if ($c -ge 0x20 -and $c -le 0x7E) { $score += 1.0 }                # printable ASCII
    elseif ($c -ge 0x4E00 -and $c -le 0x9FA5) {                          # CJK ideograph
      if ($script:CommonHanzi.Contains([char]$c)) { $score += 1.0 } else { $score -= 1.0 }
    }
    elseif ($c -ge 0x3000 -and $c -le 0x303F) { $score += 1.0 }        # CJK punctuation
    elseif ($c -ge 0xFF01 -and $c -le 0xFF60) { $score += 1.0 }        # fullwidth forms
    elseif ($c -ge 0x3040 -and $c -le 0x30FF) { $score += 1.0 }        # kana
    elseif ($c -ge 0xAC00 -and $c -le 0xD7AF) { $score += 1.0 }        # hangul
    elseif ($c -ge 0x2070 -and $c -le 0x2BFF) { $score += 2.0 }        # arrows, symbols, dingbats
    elseif ($c -ge 0x2000 -and $c -le 0x206F) { $score += 1.0 }        # general punctuation
    elseif ($c -ge 0x00A0 -and $c -le 0x024F) { $score += 0.5 }        # latin extended
    elseif ($c -eq 0x20AC) { $score -= 3.0 }                            # CP936 euro: mojibake tell
    elseif ($c -eq 0xFFFD) { $score -= 10.0 }                           # replacement character
    elseif ($c -ge 0x8000 -and $c -le 0xA4CF) { $score -= 2.0 }         # rare CJK extension
    elseif ($c -ge 0xE000 -and $c -le 0xF8FF) { $score -= 5.0 }         # private use
    elseif ($c -eq 0x09 -or $c -eq 0x0A -or $c -eq 0x0D) { }             # tab / CR / LF: normal text
    elseif ($c -ge 0xD800 -and $c -le 0xDFFF) { $score -= 5.0 }         # unpaired surrogate
    elseif ($c -lt 0x20) { $score -= 5.0 }                              # other control characters
  }
  return $score
}
# Decodes a byte range with a named charset.
function Convert-WithCharset([byte[]]$bytes, [string]$charset, $strict, $ansi) {
  switch ($charset) {
    'utf8' {
      try { return $strict.GetString($bytes) } catch { return $ansi.GetString($bytes) }
    }
    'ansi' { return $ansi.GetString($bytes) }
    'utf16le' {
      $even = $bytes.Length - ($bytes.Length % 2)
      return [System.Text.Encoding]::Unicode.GetString($bytes, 0, $even)
    }
    'utf16be' {
      $even = $bytes.Length - ($bytes.Length % 2)
      return [System.Text.Encoding]::BigEndianUnicode.GetString($bytes, 0, $even)
    }
  }
  return $ansi.GetString($bytes)
}

# Builds the decode candidates for a byte range - strict UTF-8, the system ANSI
# code page, and both UTF-16 orders - each with a plausibility score. UTF-16 is
# a candidate rather than a special case because UTF-16 without a BOM says
# nothing through NUL bytes when the text is pure CJK.
function Get-DecodeCandidates([byte[]]$bytes, $strict, $ansi) {
  $list = New-Object System.Collections.Generic.List[object]
  $utf8Text = $null
  try { $utf8Text = $strict.GetString($bytes) } catch { }
  if ($null -ne $utf8Text) {
    $list.Add(@{ Name = 'utf8'; Text = $utf8Text; Score = (Measure-TextPlausibility $utf8Text) })
  }
  $ansiText = $ansi.GetString($bytes)
  $list.Add(@{ Name = 'ansi'; Text = $ansiText; Score = (Measure-TextPlausibility $ansiText) })
  if ($bytes.Length -ge 2) {
    $even = $bytes.Length - ($bytes.Length % 2)
    $le = [System.Text.Encoding]::Unicode.GetString($bytes, 0, $even)
    $be = [System.Text.Encoding]::BigEndianUnicode.GetString($bytes, 0, $even)
    $list.Add(@{ Name = 'utf16le'; Text = $le; Score = (Measure-TextPlausibility $le) })
    $list.Add(@{ Name = 'utf16be'; Text = $be; Score = (Measure-TextPlausibility $be) })
  }
  return $list
}

# Decodes a raw byte stream into text by *detecting* the charset from the
# bytes, following the order the Python detectors use (chardet and
# charset-normalizer):
#
#   1. declared encoding first - a BOM states the charset outright, so nothing
#      is guessed.
#   2. detection - the range is decoded with every candidate charset (strict
#      UTF-8, the system ANSI code page, UTF-16 LE and BE) and the most
#      plausible result wins. Plausibility is what separates them: a genuine
#      GBK line reads as normal Chinese under ANSI and as replacement
#      characters under UTF-8, while a genuine UTF-8 line reads as normal
#      Chinese under UTF-8 and as mojibake under ANSI.
#
# Validity alone cannot decide this, because the charsets overlap: the GBK
# bytes of 一 (D2 BB) are also valid UTF-8, and so are the bytes of 专, 业,
# 丌, 丐. A rule of "valid UTF-8 therefore UTF-8" silently turns those
# characters into Cyrillic or Arabic letters.
#
# Two details keep the detection stable:
#   - a line only switches charset when the plausibility gap over the runner-up
#     is clear (>= 2 points); a near tie follows the stream verdict;
#   - the stream verdict is computed lazily over the whole stream, so it costs
#     nothing unless a line is actually ambiguous.
#
# A line whose UTF-8 form contains U+FFFD is kept as it is: the replacement
# character is something the producer actually emitted (it read a file with the
# wrong charset), not a symptom of our decoding, and the caller is warned about
# it separately.
function Convert-BytesToText([byte[]]$bytes) {
  if ($null -eq $bytes -or $bytes.Length -eq 0) { return '' }
  $strict = [System.Text.UTF8Encoding]::new($false, $true)
  $ansi = [System.Text.Encoding]::GetEncoding((Get-AnsiCodePage))

  # Tier 1: the producer declared its charset.
  if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    return $strict.GetString($bytes, 3, $bytes.Length - 3)
  }
  if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
    return [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
  }
  if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
    return [System.Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, $bytes.Length - 2)
  }

  # Tier 2: detect.
  $sb = [System.Text.StringBuilder]::new()
  $start = 0
  $streamCharset = $null
  for ($i = 0; $i -le $bytes.Length; $i++) {
    if ($i -lt $bytes.Length -and $bytes[$i] -ne 10) { continue }
    $len = $i - $start
    $seg = [byte[]]::new($len)
    if ($len -gt 0) { [Array]::Copy($bytes, $start, $seg, 0, $len) }
    $utf8Text = $null
    try { $utf8Text = $strict.GetString($seg) } catch { }
    if ($null -ne $utf8Text -and $utf8Text.IndexOf([char]0xFFFD) -ge 0) {
      # The producer emitted replacement characters - that is its output, not
      # our decoding, so it is passed through untouched.
      [void]$sb.Append($utf8Text)
    } elseif ($null -ne $utf8Text -and $utf8Text -notmatch '[^\x20-\x7E\t\r]') {
      # printable ASCII: identical under UTF-8 and ANSI, and far more sensible
      # than the UTF-16 reading
      [void]$sb.Append($utf8Text)
    } else {
      $ranked = @(Get-DecodeCandidates $seg $strict $ansi | Sort-Object -Property Score -Descending)
      if ($ranked[0].Score - $ranked[1].Score -ge 2.0) {
        [void]$sb.Append($ranked[0].Text)
      } else {
        if ($null -eq $streamCharset) {
          $streamCharset = @(Get-DecodeCandidates $bytes $strict $ansi | Sort-Object -Property Score -Descending)[0].Name
        }
        [void]$sb.Append((Convert-WithCharset $seg $streamCharset $strict $ansi))
      }
    }
    if ($i -lt $bytes.Length) { [void]$sb.Append("`n") }
    $start = $i + 1
  }
  return $sb.ToString()
}
# Splits decoded text into lines, dropping one trailing terminator so that a
# stream ending with a newline does not produce a phantom empty line.
function Split-Lines([string]$text) {
  if ([string]::IsNullOrEmpty($text)) { return @() }
  $t = [regex]::Replace($text, "`r?`n$", '')
  return @($t -split "`r?`n")
}

# Reads a local .ps1 as text. A BOM-less file that is not valid UTF-8 is almost
# always ANSI/GBK (Windows PowerShell 5.1's Set-Content writes ANSI by default),
# so fall back to the system's ANSI code page instead of mangling it. A leading
# BOM is stripped so the payload never carries U+FEFF into the remote script.
function Read-ScriptText([string]$path) {
  $bytes = [IO.File]::ReadAllBytes($path)
  $text = $null
  try {
    $text = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes)
  } catch {
    $cp = 936
    try { $cp = [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage } catch { }
    $text = [System.Text.Encoding]::GetEncoding($cp).GetString($bytes)
  }
  if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
  return $text
}

if ($ScriptFile -and $Script) { throw 'Use either -Script or -ScriptFile, not both.' }
if (-not $ScriptFile -and -not $Script) { throw 'Nothing to send: pass -Script or -ScriptFile.' }

if ($ScriptFile) {
  if (-not (Test-Path $ScriptFile)) { throw ('Not found: ' + $ScriptFile) }
  $text = Read-ScriptText $ScriptFile
} else {
  $text = $Script
}

# The options for any ssh-family client call.
$sshArgs = @('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15')
# The options for the ssh client itself, kept apart from $sshArgs because scp
# reads -T as "force a tty" and knows nothing about -n.
#   -T  the payload is a command, never a terminal session: ask for no
#       pseudo-terminal, so the remote's output stays raw bytes.
#   -n  stdin comes from NUL, so the client never waits on the console - the
#       symptom the upstream hang reports describe (Win32-OpenSSH #1334).
#   ServerAlive*  a peer that stops answering is given up on instead of
#       hanging the call forever.
$sshClientArgs = @('-T', '-n', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15', '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=4')
$remoteRunner = '$env:USERPROFILE\bin\rsh.ps1'
$marker = '__RSH_EXIT__='

# The remote's SSH default shell decides how a command line has to be spelled.
# Under PowerShell the runner is invoked with & and $env:USERPROFILE; under
# cmd.exe the same thing has to be spelled with an explicit pwsh and
# %USERPROFILE%. Detect what the target is actually configured for instead of
# assuming - the channel has to work with the current setting, whatever it is.
$script:RemoteShellKind = $null
function Get-RemoteShellKind {
  if ($null -ne $script:RemoteShellKind) { return $script:RemoteShellKind }
  # reg.exe is a plain Windows binary, so this probe runs the same way under
  # either default shell. Its output is locale-dependent, but the value it
  # prints contains the shell path, which is not.
  $raw = Invoke-SshRaw 'reg query "HKLM\SOFTWARE\OpenSSH" /v DefaultShell'
  $kind = 'cmd'
  foreach ($line in (Split-Lines (Convert-BytesToText $raw.Out))) {
    if ($line -match 'pwsh|powershell') { $kind = 'powershell'; break }
  }
  $script:RemoteShellKind = $kind
  return $kind
}

# Resolves the PowerShell executable that hosts the remote runner.
#
# rsh.ps1 is a PowerShell script: cmd.exe cannot run a .ps1 at all, so the
# command line always has to name a PowerShell. The executable is looked up on
# the target (registry first, PATH second) instead of being assumed, so the
# command does not depend on the session's PATH.
$script:RemotePowerShellExe = $null
function Get-RemotePowerShellExe {
  if ($null -ne $script:RemotePowerShellExe) { return $script:RemotePowerShellExe }
  # This probe only runs in the cmd.exe branch, so it is spelled for cmd.exe:
  # & is the command separator there, and where is where.exe.
  $raw = Invoke-SshRaw 'where pwsh 2>nul & reg query "HKLM\SOFTWARE\Microsoft\PowerShell\1\PowerShellEngine" /v PowerShellCore'
  $exe = ''
  foreach ($line in (Split-Lines (Convert-BytesToText $raw.Out))) {
    if ($line -match '(?i)([A-Za-z]:\\.*?pwsh\.exe)') { $exe = $Matches[1]; break }
  }
  if ($exe -eq '') { $exe = 'pwsh' }
  $script:RemotePowerShellExe = $exe
  return $exe
}

# The same executable, quoted the way cmd.exe expects it.
function Get-CmdPowerShellExe {
  $exe = Get-RemotePowerShellExe
  if ($exe -match '^[A-Za-z]:\\') { return ('"' + $exe + '"') }
  return $exe
}

# Builds the command that runs the remote runner with the payload.
#
# The runner is always hosted by a PowerShell executable. Under a PowerShell
# default shell the current process hosts it; under cmd.exe the executable has
# to be named explicitly.
function Get-RunnerCommand([string]$b64) {
  if ((Get-RemoteShellKind) -eq 'powershell') {
    return ('& (Get-Process -Id $PID).Path -NoProfile -ExecutionPolicy Bypass -File "' + $remoteRunner + '" -ScriptB64 ' + $b64)
  }
  return ((Get-CmdPowerShellExe) + ' -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\bin\rsh.ps1" -ScriptB64 ' + $b64)
}


# Builds the command that removes the copied-over script.
function Get-CleanupCommand {
  if ((Get-RemoteShellKind) -eq 'powershell') {
    return ('Remove-Item (Join-Path $env:USERPROFILE ''rshsend.ps1'') -Force -ErrorAction SilentlyContinue')
  }
  return ('cmd /c del /f /q "%USERPROFILE%\rshsend.ps1" >nul 2>&1')
}

# Quotes one argument for the Windows command line: wrap it in double quotes
# and escape the backslashes and quotes inside it.
function ConvertTo-ArgQuoted([string]$text) {
  $bs = [char]92
  $dq = [char]34
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append($dq)
  $run = 0
  foreach ($ch in $text.ToCharArray()) {
    if ($ch -eq $bs) { $run++; continue }
    if ($ch -eq $dq) {
      [void]$sb.Append($bs, ($run * 2 + 1))
      [void]$sb.Append($dq)
      $run = 0
      continue
    }
    if ($run -gt 0) { [void]$sb.Append($bs, $run); $run = 0 }
    [void]$sb.Append($ch)
  }
  if ($run -gt 0) { [void]$sb.Append($bs, ($run * 2)) }
  [void]$sb.Append($dq)
  return $sb.ToString()
}

# Runs ssh and returns its raw stdout/stderr bytes plus the exit code.
#
# The client's stdout and stderr go to files, never to a pipe. This is not a
# style choice: with a pipe the client on some machines finishes the protocol
# (channel freed, exit status received) and then never exits, so the caller
# waits forever. Measured 2026-11-03 on the paired peer - every pipe shape
# hung (3/3), every file shape exited in about 1.4 s - while on this machine
# all shapes were fine, so the shape that works everywhere is a file. The same
# failure is reported upstream: Win32-OpenSSH #1330, #1334 and #1427.
#
# The bytes are read straight off the files instead of through PowerShell's
# native command handling, which would decode them with the console code page
# and lose whatever is not representable in it.
function Invoke-SshRaw([string]$remoteCommand) {
  $sshExe = (Get-Command ssh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
  # The remote command is one argument and may contain spaces and quotes, so
  # the whole command line is built here and handed over as a single string -
  # that way the quoting survives exactly as built.
  $argLine = (($sshClientArgs + @($RemoteHost, (ConvertTo-ArgQuoted $remoteCommand))) -join ' ')
  $stamp = [Guid]::NewGuid().ToString('N')
  $outFile = Join-Path $env:TEMP ('rsh_out_' + $stamp + '.bin')
  $errFile = Join-Path $env:TEMP ('rsh_err_' + $stamp + '.bin')
  try {
    $proc = Start-Process -FilePath $sshExe -PassThru -NoNewWindow -RedirectStandardOutput $outFile -RedirectStandardError $errFile -ArgumentList $argLine
    $proc.WaitForExit()
    $outBytes = [byte[]]@()
    if (Test-Path -LiteralPath $outFile) { $outBytes = [IO.File]::ReadAllBytes($outFile) }
    $errBytes = [byte[]]@()
    if (Test-Path -LiteralPath $errFile) { $errBytes = [IO.File]::ReadAllBytes($errFile) }
    return @{ Out = $outBytes; Err = $errBytes; Exit = $proc.ExitCode }
  }
  finally {
    Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
  }
}

# Finds the runner's exit marker in the raw byte stream.
#
# The marker is searched for in the bytes, not in the decoded text: it is
# always ASCII, while the payload around it can be in any encoding. Looking
# for it after decoding would let the payload's charset corrupt the marker -
# a UTF-16 payload would decode the marker into CJK gibberish and the exit
# code would be lost.
#
# The marker is the last thing the remote runner prints, so only the tail of
# the stream is scanned.
function Find-ExitMarker([byte[]]$bytes) {
  $needle = [System.Text.Encoding]::ASCII.GetBytes('__RSH_EXIT__=')
  $n = $needle.Length
  $window = [Math]::Min(256, $bytes.Length)
  $from = $bytes.Length - $window
  for ($i = $bytes.Length - $n; $i -ge $from; $i--) {
    if ($i -lt 0) { break }
    $ok = $true
    for ($j = 0; $j -lt $n; $j++) {
      if ($bytes[$i + $j] -ne $needle[$j]) { $ok = $false; break }
    }
    if ($ok) {
      $pos = $i + $n
      $digits = ''
      while ($pos -lt $bytes.Length -and $bytes[$pos] -ge 0x30 -and $bytes[$pos] -le 0x39) {
        $digits += [char]$bytes[$pos]
        $pos++
      }
      $code = 0
      if ($digits.Length -gt 0) { [void][int]::TryParse($digits, [ref]$code) }
      return @{ Index = $i; Code = $code }
    }
  }
  return $null
}

# Runs the remote command, writes its output to the host, and returns the exit code.
# Output goes to the host (not the return value) so the caller can assign the
# return value without swallowing the script's stdout.
function Invoke-Remote([string]$remoteCommand) {
  $raw = Invoke-SshRaw $remoteCommand
  $outBytes = $raw.Out
  $real = $null

  # Strip the exit marker from the bytes before decoding anything.
  $marker = Find-ExitMarker $outBytes
  if ($null -ne $marker) {
    $real = $marker.Code
    if ($marker.Index -gt 0) {
      $body = [byte[]]::new($marker.Index)
      [Array]::Copy($outBytes, 0, $body, 0, $marker.Index)
      $outBytes = $body
    } else {
      $outBytes = [byte[]]::new(0)
    }
  }

  $outText = Convert-BytesToText $outBytes
  $errText = Convert-BytesToText $raw.Err

  $bodyLines = New-Object System.Collections.Generic.List[string]
  foreach ($line in (@(Split-Lines $outText) + @(Split-Lines $errText))) {
    $bodyLines.Add($line)
  }
  foreach ($line in $bodyLines) { Write-Host $line }

  # U+FFFD means bytes that fit neither encoding: the remote side read them
  # with the wrong code page (for example opening a GBK file as UTF-8) and
  # already dropped the original bytes, so nothing here can recover them.
  if ($outText.IndexOf([char]0xFFFD) -ge 0 -or $errText.IndexOf([char]0xFFFD) -ge 0) {
    Write-Host '[rsh] warning: output contains U+FFFD replacement characters - the remote side decoded bytes with the wrong encoding (for example reading a GBK file as UTF-8). Those bytes are already lost there; read the file explicitly with -Encoding ansi on the remote.'
  }

  if ($null -ne $real) { return $real }
  return $raw.Exit
}
$b64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new().GetBytes($text))

if ($b64.Length -lt 16000) {
  $code = Invoke-Remote (Get-RunnerCommand $b64)
  exit $code
}

# Large payload: scp it over, run it in place, then remove it.
$tmp = Join-Path $env:TEMP ('rshsend_' + [Guid]::NewGuid().ToString('N') + '.ps1')
# With a BOM: the copy is read by whatever PowerShell the target runs, and
# Windows PowerShell 5.1 only treats a .ps1 as UTF-8 when it carries one.
[IO.File]::WriteAllText($tmp, $text, (New-Object System.Text.UTF8Encoding($true)))
try {
  & scp @sshArgs $tmp ($RemoteHost + ':rshsend.ps1')
  if ($LASTEXITCODE) { exit $LASTEXITCODE }
  # The copy is run through the remote runner, exactly like the inline path,
  # so the exit code comes back through the marker. Running it directly
  # would depend on how the remote shell reports the exit status of a
  # nested process, and that differs between cmd.exe and PowerShell.
  # The launcher runs the copy in a child process and exits with that
  # process's code: a script invoked with & swallows its own exit code, so
  # calling it directly would report success whatever the payload did.
  $launcher = @(
    '$p = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList @(''-NoProfile'',''-ExecutionPolicy'',''Bypass'',''-File'',(Join-Path $env:USERPROFILE ''rshsend.ps1'')) -NoNewWindow -PassThru -Wait',
    'exit $p.ExitCode'
  ) -join "`r`n"
  $launcher = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($launcher))
  $code = Invoke-Remote (Get-RunnerCommand $launcher)
  exit $code
} finally {
  Remove-Item $tmp -Force -ErrorAction SilentlyContinue
  Invoke-SshRaw (Get-CleanupCommand) | Out-Null
}
