# ssh 客户端的退出行为：公开资料与本机实测

这份文档回答一个问题：**脚本化的 ssh 调用，客户端的输出该接到哪里。**
结论先行，证据在后：公开 issue 的绕法、本机两台机器的对照实验、以及被评估
过但没选的方案，都记在这里，方便下次不用重新踩。

最后更新：2026-11-03。代码版本：Win32-OpenSSH 9.5p2（两端同一个构建，
可执行文件 1,256,448 B）。

## 结论

1. **ssh 客户端的 stdout 和 stderr 必须接到文件，不能接管道。** 两个方向都是。
   这是本仓全部 ssh 调用的统一形态。
2. **`-T`（不要 pty）和 `-n`（stdin 走 NUL）是配套保险，不能替代第 1 条。**
   实测：给管道形态加上 `-T -o StdinNull=yes` 之后照样挂（对端 3/3）。
3. **退出码必须走数据（`__RSH_EXIT__=` 标记），不能信 ssh 的状态位。**
   这是本仓自己的结论，公开资料不涉及这一层。
4. **`ServerAliveInterval` / `ServerAliveCountMax`** 让对端失联时客户端自己放弃，
   而不是让调用方永远等下去。

## 一、本机实测（2026-11-03）

两台配对的 Windows 机器，六种客户端 stdio 形态，同一条远程命令
（`ssh <peer> 'Write-Output hi'`），每种跑若干次。

| 形态 | 客户端的 stdout 接到哪 | 发起端 | 对端 |
| --- | --- | --- | --- |
| A | PowerShell 原生捕获 `$o = & ssh ...` | 8/8 正常（1.2 s） | **3/3 挂起** |
| A2 | 原生捕获 + `2>&1` 合并 stderr | 8/8 正常 | **3/3 挂起** |
| B | `ProcessStartInfo.RedirectStandardOutput`（匿名管道） | 8/8 正常 | **3/3 挂起** |
| C | `Start-Process -RedirectStandardOutput <文件>` | 8/8 正常 | 3/3 正常（1.4 s） |
| D | C + `-T` + `-o StdinNull=yes` | 8/8 正常 | 3/3 正常（1.35 s） |
| E | B + `-T` + `-o StdinNull=yes` | 8/8 正常 | **3/3 挂起** |

读数怎么解释：

- **与目标机无关**：对端连回发起端、连第三台机器，都复现。
- **与 ssh 版本无关**：两端是同一个可执行文件的同一个构建。
- **与 stdin 无关**：E 形态已经把 stdin 从 NUL 摘掉、也不要 pty，照挂。
  ⇒ 决定因素是**客户端 stdout 的形态**。
- **与机器有关**：发起端 48 次全过，对端 12 次全挂。所以正确的说法不是
  「管道必挂」，而是「**在会复现的客户端环境下管道会挂**」。
- **嵌套是触发条件**：对端那轮实验是**在 ssh 会话里再起一个 ssh 客户端**
  跑出来的——这正是通道两个方向的实际形态（本机的 wrapper 通过对端的
  sshd 跑在对端，对端的 reverse-run 也是在 ssh 会话里回连本机）。

### 口径修正（本仓此前写得过头了）

本仓此前写的是「ssh 客户端输出走 .NET 管道会挂死」。实测更准确的说法是：

> **管道形态在部分客户端环境下会挂死；文件重定向在所有观测到的环境下都正常。**

规则不变（还是用文件），但依据从「管道必挂」变成「文件在所有环境下都安全」。
这条修正同样重要：反过来说，**在发起端用管道跑通过，不能证明管道形态是安全的**——
它只证明那台机器不触发。

## 二、公开资料

同一族故障在 Win32-OpenSSH 的 issue 里有完整记录。它们互相引用，可以当成
一条线索链读：

### #1330 — 最早的记录

<https://github.com/PowerShell/Win32-OpenSSH/issues/1330>
2019-01-24 开，2019-06-23 关，标签 `Issue-Bug` / `Area-Terminal`。

维护者 manojampalam 的第一条回复：

> Underlying issue is the same discussed in #856.
> The IO on /dev/null (specified via -n) is somehow getting hung when NUL is explicitly redirected.
> Following would still work
>
>     ssh -n -T user@server ls > stdout.txt 2> stderr.txt
>
> I've put a workaround for the issue and you should have it in next release.

要点：**官方给的绕法就是重定向到文件**，而且当时就指出根因在 #856。
2020-11、2024-02、2025-02 仍有人回报在 7.7p1 / 8.x / 9.5p1 上复现——
这个 issue 关了，但现象没消失。

### #1334 — 偶发挂起，等键盘输入

<https://github.com/PowerShell/Win32-OpenSSH/issues/1334>（仍开）

2025-02-06 的实测报告（OpenSSH_for_Windows_9.5p1，Win10 22H2）：

> SSH command from cmd.exe to a direct-network connected client (latency < 1 msec)
> Executing a command like `ssh user@server some_remote_command` hangs ~25-50%
> waiting for keyboard input. Pressing enter finishes the command.
> Increasing the time that the command takes resolves the hang.
> It appears that the faster that the command executes, the more likely the hang will occur.
>
> As a workaround (which seems to be working), I've added the StdinNull=yes option.
> `ssh -o StdinNull=yes user@server some_remote_command`

要点：**命令越快越容易挂**；加 `-v` 就不挂（那是掩盖，不是修复）；按回车能救
（无人值守不可用）；`StdinNull=yes` 是社区里在用的绕法。

2019 年 alexv1n 给出了挂点位置：`syncio_close()` → `WaitForSingleObject`，
并指出 `ssh user@server -- echo -n "" <NUL` **100% 挂**。

### #1338 — 定位到 win32 兼容层

<https://github.com/PowerShell/Win32-OpenSSH/issues/1338>（已关）

NoMoreFood 的补丁挂在 `contrib/win32/win32compat/termio.c`：

    if (pio->read_details.pending) {
        /* Terminate the read thread at the below situations:
        1. For console - the read thread is blocked by the while loop on raw mode
        2. Function ReadFile on Win7 machine dees not return when no content to read in non-interactive mode. */
        if (FILETYPE(pio) == FILE_TYPE_CHAR && (IsWin7OrLess() || in_raw_mode))
            TerminateThread(pio->read_overlapped.hEvent, 0);
        else
            WaitForSingleObject(pio->read_overlapped.hEvent, INFINITE);
    }

要点：**等一个永远不来的 overlapped 事件**。补丁 2019-03 由报告者确认修复。

### #1427 — 异步写 STDERR 挂起（本仓做法的直接佐证）

<https://github.com/PowerShell/Win32-OpenSSH/issues/1427>（仍开）

2026-08-05 的回复给出最小复现，形态与本机实测**逐字对应**：

    # HANGS: STDERR captured via PowerShell pipe
    $out = ssh -o BatchMode=yes user@host -p 22112 'echo hi' 2>&1

    # WORKS: STDERR redirected to a real file
    $p = Start-Process ssh -ArgumentList '-o','BatchMode=yes','user@host','-p','22112','echo','hi' `
         -RedirectStandardOutput out.txt -RedirectStandardError err.txt -NoNewWindow -PassThru -Wait
    # -> exits cleanly

并总结了这一族的状态：

> Related: #1330 (closed via workaround, still reproduces), #856, #1748, #1470, #1334 —
> this whole family of "redirected-stdio hang" is still open in practice on current builds.

要点：**当前构建上这一族仍然是活的**；推荐的绕法就是本仓现在用的形态。

### #856 — 上游根因贴

<https://github.com/PowerShell/Win32-OpenSSH/issues/856>（已关，标题 *GetConsoleMode error*）
#1330 指向的「同一个根因」。维护者给出的建议之一是加 `-n`。

## 三、微软文档

<https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh-server-configuration>
（页面标注 `ms.date: 08/05/2025`）

- 默认 shell 配在注册表：
  > You can configure the default ssh shell in the Windows registry by adding the full
  > path to the shell executable to `HKEY_LOCAL_MACHINE\SOFTWARE\OpenSSH` in the
  > string value `DefaultShell`.
  > … (Setting this path doesn't apply to OpenSSH Client.)
- 有一条容易被误读的重启说明：
  > OpenSSH Server (sshd) reads the configuration file when the service starts.
  > Any changes to the configuration file require the service to be restarted.

**这条说的是 `sshd_config` 文件，不是注册表里的 `DefaultShell`。**
本仓的口径是「DefaultShell 按连接读取，改完下一次连接就生效，不用重启 sshd」，
与该文档**不冲突**（文档没对注册表值下结论）。不过要说清证据强度：本仓这条是
**间接实测**（2026-11-03 把对端切到 cmd.exe 后，按新 shell 拼的载荷一次跑通——
若 sshd 仍用旧 shell，cmd.exe 拼法就会失败），不是直接观测；要直接观测得改对端
注册表，那是机器级写操作，本仓不碰。

## 四、评估过但没选的方案

| 方案 | 为什么没选 |
| --- | --- |
| `plink`（PuTTY） | #1334 里有人从它换走（因为它从不死），但同一批回复也列了它的代价：没有 `StrictHostKeyChecking` 的等价物、要 `-batch`、不认默认私钥路径、依赖 pageant、输出编码另说。为一个已解决的问题引入新依赖不划算 |
| WSL 里的 OpenSSH | 能绕开 win32 兼容层，但要另装 WSL、另建一套 key、另一套路径语义。对「一对 Windows 机器」这个场景是净增成本 |
| 加 `-v` | #1334 明确说加了就不挂——那是掩盖不是修复 |
| 挂起时按回车 | 无人值守不可用 |
| 交互式 `~\.` 断连 | 只能救当前这一次会话，不解决脚本调用 |
| 给 ssh.exe 换二进制 / 打补丁 | 那是上游 win32 兼容层的问题；改别人机器上的系统二进制不在本仓范围内 |

## 五、本仓据此采用的规则与落点

| 规则 | 落在哪 |
| --- | --- |
| ssh 客户端的 stdout/stderr 必须是文件 | `skills/remote-win-exec/scripts/rsh-wrapper.ps1`（`Invoke-SshRaw`）、`skills/remote-win-exec/scripts/install-channel.ps1`（`Invoke-SshCapture`）、`skills/remote-win-exec/scripts/reverse-run.ps1`、`skills/remote-win-exec/scripts/check-channel.ps1` |
| `-T`（不要 pty）、`-n`（stdin 走 NUL） | 同上四处 |
| `ServerAliveInterval=15` / `ServerAliveCountMax=4` | wrapper 与安装器（reverse-run 另有 30 秒硬超时，不需要） |
| 退出码只认 `__RSH_EXIT__=` 标记 | runner（`scripts/rsh-runner.ps1`）写、wrapper 剥 |
| 调用方永远不要用管道接 ssh 的输出 | `skills/remote-win-exec/references/troubleshooting.md` 的对应条目 |

## 六、复现命令

形态对照矩阵（本机与对端各跑一遍，脚本是临时的）：

    # 本机：6 种形态各 8 次
    pwsh -NoProfile -ExecutionPolicy Bypass -File rsh-stdio-matrix.ps1 -Target <peer-alias> -Iterations 8

    # 对端：同样的脚本，Target 换成本机，Iterations=3
    #   对端那轮是嵌套在 ssh 会话里跑的，所以先把它丢到对端后台起，
    #   再取回结果文件——否则前台的等待会被本机的超时先砍掉。

回归（改动 ssh 客户端形态后必跑）：

    pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-forward.ps1 -RemoteHost '<peer-user>@<peer-alias>'
    pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-reverse.ps1 -RemoteHost '<peer-user>@<peer-alias>'
    pwsh -NoProfile -ExecutionPolicy Bypass -File "<skill-dir>\scripts\check-channel.ps1"

## 七、参考链接

| 来源 | 链接 | 用途 |
| --- | --- | --- |
| Win32-OpenSSH #1330 | <https://github.com/PowerShell/Win32-OpenSSH/issues/1330> | 最早的记录；官方绕法=重定向到文件 |
| Win32-OpenSSH #1334 | <https://github.com/PowerShell/Win32-OpenSSH/issues/1334> | 偶发挂起；`StdinNull=yes` 绕法；命令越快越容易挂 |
| Win32-OpenSSH #1338 | <https://github.com/PowerShell/Win32-OpenSSH/issues/1338> | 定位到 win32 兼容层的 `syncio_close()` |
| Win32-OpenSSH #1427 | <https://github.com/PowerShell/Win32-OpenSSH/issues/1427> | 异步写 stderr 挂起；文件重定向的最小复现与绕法 |
| Win32-OpenSSH #856 | <https://github.com/PowerShell/Win32-OpenSSH/issues/856> | #1330 指向的上游根因贴 |
| Microsoft Learn：OpenSSH Server 配置 | <https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh-server-configuration> | `DefaultShell` 的位置；`sshd_config` 改动要重启服务 |
