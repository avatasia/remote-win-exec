# 通道部署（脚本 + skill）

前置条件见 [openssh.md](openssh.md)：两台机器已经能免密 ssh 互通。

## 一条命令

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "<skill-dir>\scripts\install-channel.ps1" -RemoteHost '<peer-user>@<peer-alias>'
```

它做四件事，每件都幂等（再跑一次只会报 `[same]`）：

1. 把 skill 目录里的 `scripts\rsh-wrapper.ps1` 渲染后写到本机 `$env:USERPROFILE\.ssh\rsh.ps1`
   （模板里的 `<remote-user>@<remote-host>` 换成你给的 `<peer-user>@<peer-alias>`；
   换不掉的话脚本自带的守卫会直接抛错，不会拿占位符去连）。
2. 把 skill 目录 **整个**复制到本机
   `$env:USERPROFILE\.minimax\skills\remote-win-exec\`（`SKILL.md` + `references\` + `scripts\`，
   少一个都会让 skill 里的链接指向不存在的文件）。
3. 把 skill 目录里的 `scripts\rsh-runner.ps1` 用 scp 送到对端 `bin/rsh.ps1`，并把同一个 skill 目录部署到对端的
   `~/.minimax/skills/remote-win-exec/`（逐文件回读 SHA）。
4. 跑一个探针载荷验证通道：远端回显主机名 + 中文，退出码必须是 0，否则报错退出。

常用参数：

| 参数 | 作用 |
| --- | --- |
| `-Check` | 只报告装了什么、哪里不一致，不改任何东西 |
| `-SetDefaultShell` | 顺带把对端 sshd 默认 shell 设成 pwsh（需要在对端有提权会话） |

## 手动部署（不想跑脚本时）

```powershell
# <skill-dir> = skill 目录（本 SKILL.md 所在目录）
$skill = '<skill-dir>'

# 本机 wrapper：先改掉占位符
$t = [IO.File]::ReadAllText("$skill\scripts\rsh-wrapper.ps1")
$t = $t.Replace('<remote-user>@<remote-host>', '<peer-user>@<peer-alias>')
Copy-Item "$skill\scripts\rsh-wrapper.ps1" "$env:USERPROFILE\.ssh\rsh.ps1" -Force

# 本机 skill
New-Item -ItemType Directory -Path "$env:USERPROFILE\.minimax\skills\remote-win-exec" -Force | Out-Null
Copy-Item "$skill\SKILL.md" "$env:USERPROFILE\.minimax\skills\remote-win-exec\SKILL.md" -Force

# 对端 runner（scp 的相对路径相对对端用户家目录）
scp "$skill\scripts\rsh-runner.ps1" '<peer-user>@<peer-alias>:bin/rsh.ps1'
```

对端的 skill 目录用同样的 base64 载荷法投递（见 `install-channel.ps1` 第 3 节）。

## 退出码与引号（最容易踩的地方）

退出码能不能拿回来，取决于命令**是不是直接跑在远端 shell 里**：

| 远端命令 | 默认 shell = pwsh | 默认 shell = cmd.exe |
| --- | --- | --- |
| `exit 7` | 7 | 7 |
| `cmd /c exit 7` | 1 | 7 |
| `pwsh -NoProfile -Command "exit 7"` | 1 | 7 |
| `pwsh -NoProfile -EncodedCommand <b64>` | 1 | 7 |

**cmd.exe 会转述嵌套进程的退出码，PowerShell 不会（固定回 1）。** 所以：

- 走 wrapper（本机侧）：退出码永远通过 runner 的 `__RSH_EXIT__=` 标记回传，与远端 shell 无关。
- 走裸 ssh（对端侧）：只有**直接跑在远端 shell 里**的命令能靠状态位拿码；
  要跑 PowerShell 语义就把退出码当**数据**传：

  ```powershell
  $cmd = '$ProgressPreference=''SilentlyContinue''; [Console]::OutputEncoding=[System.Text.UTF8Encoding]::new(); Write-Output ''peer-中文-ok''; $code=7; Write-Output (''__RSH_EXIT__='' + $code); exit $code'
  $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
  # ⚠️ ssh 的输出必须重定向到文件，不能写成 $out = ssh ...（会挂死，见 ssh-client-behavior.md）
  $outFile = Join-Path $env:TEMP 'rsh_out.txt'
  $p = Start-Process ssh -NoNewWindow -Wait -RedirectStandardOutput $outFile -RedirectStandardError ($outFile + '.e') -ArgumentList @('<peer-alias>','pwsh','-NoProfile','-EncodedCommand',$enc)
  $out = Get-Content -LiteralPath $outFile
  $code = 0
  foreach ($line in @($out)) { if ($line -match '^__RSH_EXIT__=(\d+)$') { $code = [int]$Matches[1] } }
  ```

## 引号

- 一条命令要穿过**两层 shell**（本机 + 远端）时，嵌套引号必被吃掉。
- 发 PowerShell 用 **EncodedCommand**（载荷里一个引号都没有）。
- 远端默认 shell 是 cmd.exe 时，`%USERPROFILE%` 才会展开；PowerShell 里是 `$env:USERPROFILE`。
- 本机 shell 也是 cmd.exe 时，调用 wrapper 要写成：

  ```cmd
  pwsh -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\.ssh\rsh.ps1" -ScriptFile "D:\path\probe.ps1"
  ```

## 编码

通道对远端输出做**判码**而不是假定 UTF-8：

- 远端 runner 先 `chcp 65001`，PowerShell 载荷写出的就是 UTF-8 字节。
- 但原生程序（git.exe 之类）写管道时用的是 ANSI 码页（936）⇒ GBK 字节，
  所以判码要同时支持两种。
- 判码按**常用字**打分，不是按字符个数：GBK 读 UTF-8 会得到更多汉字
  （3 字节变 1.5 个字），按个数打分会让错的那个赢。
- 用 `Get-Content -Encoding ansi` 或 `[IO.File]::ReadAllText($f, [Text.Encoding]::GetEncoding(936))`
  明确指定编码读文件，比任何猜测都可靠。

## 改目标默认 shell（可选，建议）

通道**不要求** pwsh：wrapper 每次运行前都问一次目标当前的默认 shell，并按实际值拼命令
（pwsh / Windows PowerShell 5.1 / cmd.exe 三种都实测通过）。把两端设成 pwsh 只是少一层引号、
控制台码页更可预期。

```powershell
# 在对端跑，需要对端有提权会话
Set-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -Value 'C:\Program Files\PowerShell\7\pwsh.exe'

# 验证（按连接读取，改完下一次连接就生效，不用重启 sshd）
reg query "HKLM\SOFTWARE\OpenSSH" /v DefaultShell
```

blast radius：该机器**所有** SSH 会话都换成这个 shell —— 交互式的、定时任务都算。
这是机器级写操作，不属于通道本身；两端对齐是建议，不是前提。

## 回归

改动通道任一侧（wrapper / runner / skill 脚本 / ssh 调用形态）后跑：

```powershell
# 正向（本机 → 对端）：编码、歧义字节、stderr、退出码、大载荷
pwsh -NoProfile -ExecutionPolicy Bypass -File "<skill-dir>\scripts\test-forward.ps1" -RemoteHost '<peer-user>@<peer-alias>'

# 反向（对端 → 本机）：输出、退出码、stderr
pwsh -NoProfile -ExecutionPolicy Bypass -File "<skill-dir>\scripts\test-reverse.ps1" -RemoteHost '<peer-user>@<peer-alias>'

# 只读体检（两端都跑；对端有多个 ssh 候选时要带 -RemoteHost）
pwsh -NoProfile -ExecutionPolicy Bypass -File "<skill-dir>\scripts\check-channel.ps1"
```

## 装期诊断

装不上或装完不工作时，按这张表定位：

| 症状 | 判据 | 动作 |
| --- | --- | --- |
| `ssh` 连不上 | `ssh <peer> "hostname"` | OpenSSH 层：看 [openssh.md](openssh.md)（sshd 服务、防火墙、公钥、known_hosts） |
| `Permission denied (publickey)` | `ssh -v <peer> "hostname"` 里实际用了哪把 key | key 没进对端的 `authorized_keys`，或 `~/.ssh/config` 的 `IdentityFile` 指错 |
| 安装器报 wrapper 渲染后仍有占位符 | 传进去的 `-RemoteHost` 里还带 `<remote-user>` | 参数写成 `user@host`，占位符由安装器替换 |
| 对端装完仍报错 | 对端 `bin/rsh.ps1` 的 SHA 与本机仓里的不一致 | 重跑安装器；它会逐文件回读 SHA 并把不一致报出来 |
| 两端 skill 内容不同 | `check-channel.ps1` 的 `peer-skill` 行 | 同样重跑安装器——它按文件比对并覆盖 |
| 探针过不了（`HOST=...` 没回来） | 手动跑 `ssh <peer> "cmd /c echo RSH_OK"` | 先排除 SSH 层，再看对端 `bin/rsh.ps1` 是否在位 |
| 远端默认 shell 不对 | `reg query "HKLM\SOFTWARE\OpenSSH" /v DefaultShell` | 见上一节；不影响通道可用性，只影响命令怎么写 |
| 对端体检报 `several config entries qualify` | 对端 `~/.ssh/config` 有多条带 `User` + `IdentityFile` 的条目 | 体检不替用户猜哪台是配对机；带 `-RemoteHost <user>@<alias>` 再跑 |

装完跑一次只读体检（不改任何东西）：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "<skill-dir>\scripts\check-channel.ps1"
```
