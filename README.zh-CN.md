# remote-win-exec

在**配对的另一台 Windows 机器**上执行 PowerShell 命令与脚本，**双向**可用，通道是已经
建好的 SSH。

这是一个 MiniMax Code **skill**，且它带上的是**整套通道**而不只是调用规则：本机 wrapper、
对端 runner、一键安装器、只读体检脚本，以及两个端到端回归套件。

| | |
| --- | --- |
| **方向** | 本机 → 对端、对端 → 本机 |
| **传输** | 公钥 SSH（Windows OpenSSH） |
| **退出码** | 精确值，当作数据回传（`__RSH_EXIT__=`），绝不靠 ssh 状态位猜 |
| **编码** | 逐行判定 UTF-8 / GBK / UTF-16；U+FFFD 原样透传，不做平滑 |
| **Shell** | 探测对端当前默认 shell（pwsh / Windows PowerShell 5.1 / cmd.exe）并自适应 |
| **平台** | 两端都是 Windows |

## 安装（第一对机器）

前置：两台 Windows 已能免密 SSH 互通 —— 装好 OpenSSH 服务端、交换公钥、两端写好
`/.ssh/config`。安装器**不**负责建 key 或开服务。

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "<skill-dir>scriptsinstall-channel.ps1" -RemoteHost '<peer-user>@<peer-alias>'
```

它把 wrapper 渲染到 `/.ssh/rsh.ps1`，把 skill 目录连同 runner 部署到对端，最后跑一个探针
载荷验证通道。全程幂等：再跑一次只报 `[same]`。`-Check` 只看现状、不改任何东西。

## 怎么用

通道起来之后，skill 自己判断站在哪一侧，并告诉 agent 该调哪个入口。日常对话里说
「在远端跑」「到那台远程机器看看」「run it on the remote box」就会触发。

## 三件值得知道的事

1. **ssh 客户端的输出只能是文件，不能是管道。** 走管道时客户端可能把协议跑完
   （channel 释放、退出码到手）却**不退出**，调用方永远等下去。在配对的两台机器上实测：
   管道形态在对端 3/3 挂起，发起端 8/8 正常 —— 所以「我这台跑通了」不构成证据。本包内
   全部 ssh 调用一律重定向到文件。证据与上游 issue 出处见
   [docs/ssh-client-behavior.md](docs/ssh-client-behavior.md)。
2. **退出码走数据。** 远端 PowerShell 不转述嵌套进程的退出码（cmd.exe 转述，PowerShell 固定
   回 1），所以 runner 打印 `__RSH_EXIT__=<code>`，调用方从流里解析。
3. **对端默认 shell 是探测出来的，不是假设的。** wrapper 会问对端当前配置成什么，再按实际
   拼命令。两端都设成 pwsh 是**建议**，不是前提。

## 包结构

```text
remote-win-exec/
├── .minimax-plugin/plugin.json     包清单
├── icon.png
├── LICENSE
├── README.md                       英文版（本文件结构对应 README.zh-CN.md）
├── README.zh-CN.md
├── docs/                           OpenSSH 前置、通道部署、客户端退出行为
└── skills/remote-win-exec/         skill 本体
    ├── SKILL.md                    agent 遵循的规则
    ├── references/                 环境快照、症状表、判码说明
    └── scripts/                    wrapper、runner、安装器、体检、回归
```

## 回归

```powershell
# 正向（本机 → 对端）：编码、歧义字节、stderr、退出码、大载荷
pwsh -NoProfile -ExecutionPolicy Bypass -File ".scripts	est-forward.ps1" -RemoteHost '<peer-user>@<peer-alias>'

# 反向（对端 → 本机）：输出、退出码、stderr
pwsh -NoProfile -ExecutionPolicy Bypass -File ".scripts	est-reverse.ps1" -RemoteHost '<peer-user>@<peer-alias>'

# 只读体检
pwsh -NoProfile -ExecutionPolicy Bypass -File ".scriptscheck-channel.ps1"
```

## 许可

MIT，见 [LICENSE](LICENSE)。
