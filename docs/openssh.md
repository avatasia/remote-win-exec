# OpenSSH 部署（Windows ↔ Windows）

这是通道的**前置条件**：两台 Windows 机器互相免密 ssh。脚本与 skill 的部署见
[install.md](install.md)。

下面的默认值来自一对真实机器的实测（2026-11-03，OpenSSH for Windows 9.5p2）。

## 0. 实测现状

| 项 | 本机 | 对端 |
| --- | --- | --- |
| ssh 客户端 | OpenSSH_for_Windows_9.5p2 | 同 |
| sshd 服务 | Running / Automatic | 同 |
| 防火墙 | 入站 `OpenSSH Server (sshd)` 允许 TCP 22 | `OpenSSH SSH Server (sshd)` |
| sshd_config 生效行 | `PubkeyAuthentication yes`、`AuthorizedKeysFile .ssh/authorized_keys`、`Subsystem sftp` | 同 |
| 管理员密钥文件 `C:\ProgramData\ssh\administrators_authorized_keys` | 不存在 | 同 |
| sshd 默认 shell | `HKLM\SOFTWARE\OpenSSH\DefaultShell` = pwsh | 同 |

## 1. 装 OpenSSH（客户端 + 服务端）

Windows 10/11 自带客户端；服务端是可选功能，**要管理员**：

```powershell
# 客户端
Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0
# 服务端
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
```

装完确认服务在跑且开机自启：

```powershell
Get-Service sshd | Select-Object Status, StartType
Set-Service sshd -StartupType Automatic
Start-Service sshd
```

⚠️ `Get-WindowsCapability` 同样需要管理员。非提权会话里它会直接报
`The requested operation requires elevation` —— 那不代表没装，用 `Get-Service sshd` 判断。

## 2. 放行端口

```powershell
New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' `
  -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
```

装服务端时系统通常自动建好这条规则；查：
`Get-NetFirewallRule | Where-Object DisplayName -match 'OpenSSH'`。

## 3. 生成密钥对

每台机器给自己生成一对，**私钥不外传**：

```powershell
ssh-keygen -t ed25519 -f "$env:USERPROFILE\.ssh\<key-file>" -C "pair-key"
```

- 要多把钥匙就多起几个文件名（如 `<key-file>`）。
- 通道要求免密，`ssh-keygen` 问 passphrase 时**留空回车**。

## 4. 交换公钥

把**本机**的 `.pub` 内容追加到**对端**用户的 `authorized_keys`（一行一个）：

```powershell
Get-Content "$env:USERPROFILE\.ssh\<key-file>.pub"
```

在对端机器上把它贴进 `C:\Users\<对端用户>\.ssh\authorized_keys`。

⚠️ **管理员账户的坑**：OpenSSH for Windows 对管理员账户默认改读
`C:\ProgramData\ssh\administrators_authorized_keys`（且要求只允许 SYSTEM/Administrators 写）。
本配对的 `sshd_config` 显式写了 `AuthorizedKeysFile .ssh/authorized_keys`，**覆盖了那个默认**，
所以 `~/.ssh/authorized_keys` 就够用（两端也都没有那个管理员密钥文件）。

## 5. 写 ssh config（两端各一份）

```sshconfig
# 本机 ~/.ssh/config
Host <peer-alias> <peer-ip>
  User <peer-user>
  PreferredAuthentications publickey
  IdentityFile C:\Users\<本机用户>\.ssh\<key-file>
  IdentitiesOnly yes
```

- `IdentitiesOnly yes` 别省：否则 ssh 会把 agent 里所有钥匙挨个试，日志会被淹。
- 对端机器上的 `~/.ssh/config` 反过来写一条指向本机的。
- `IdentityFile` 用**绝对路径**（Windows 下 `~/.ssh/x` 也能用，但绝对路径在计划任务里更稳）。

## 6. 验证免密

```powershell
ssh -o BatchMode=yes -o ConnectTimeout=15 <peer-alias> "hostname"
```

`BatchMode=yes` 让它不弹密码提示、失败直接报错 —— 自动化里必须加。

## 7. sshd 默认 shell（可选，推荐）

```powershell
Set-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -Value 'C:\Program Files\PowerShell\7\pwsh.exe' -Type String
```

- **需要管理员**，且是机器级设置：影响这台机器上**所有** SSH 会话（交互会话、计划任务里的 ssh 都算）。
- 该值**按连接读取**：改完下一次连接就用新 shell，**不需要重启 sshd**。
- 设成 pwsh 是**推荐不是前提** —— 通道的 wrapper 会探测目标当前设置并自适应
  （pwsh / Windows PowerShell 5.1 / cmd.exe 都实测过）。

## 8. 控制台编码（可选，默认不装）

系统 ANSI 码页保持 936 不动（改它会影响别的程序）。**通道本身不需要这一节**：远端 runner 在启动
载荷前已经 `chcp 65001`，所以走通道的输出本来就是 UTF-8。

这一节只关系到**交互式 shell**（人坐在终端前敲命令，或手工起的程序）：那种场景下控制台码页
还是系统的 ANSI 码页（936），中文会显示成乱码。

**默认不加。** 只有交互式 shell 里确实出现中文乱码时，才按下面加（加在需要用的那一侧）：

| 场景 | 文件 |
| --- | --- |
| PowerShell 7，当前用户当前主机 | `$PROFILE.CurrentUserCurrentHost` |
| PowerShell 7，当前用户所有主机 | `$PROFILE.CurrentUserAllHosts` |
| Windows PowerShell 5.1 | 另一套 profile 路径，5.1 与 7 各一份 |

加进去的内容（两行）：

```powershell
chcp 65001 > $null
$OutputEncoding = [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
```

也可以让 skill 的脚本代劳（它会先备份原文件，重复跑不会加第二遍）：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "<skill-dir>\scripts\set-utf8-profile.ps1" -Apply
```

改完新开一个交互式 shell，`chcp` 应打印 65001；已经开着的 shell 仍是旧码页。

## 9. 排查

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| `Permission denied (publickey)` | 公钥没进对端 / 账号不对 / 缺 `IdentitiesOnly` | 查对端 `~/.ssh/authorized_keys`；`ssh -v` 看它试了哪把钥匙 |
| `Host key verification failed` | 对端主机密钥变了 | 删掉本地 `known_hosts` 里**那一条**再连（别整文件删） |
| 连上了但命令像没执行 | 远端默认 shell 的引号规则不同 | 见 [install.md](install.md) 的「退出码与引号」 |
| 找不到 `sshd` 服务 | 服务端功能没装 | 第 1 节 |
| 端口通但 ssh 连不上 | 防火墙没放行 | 第 2 节 |
