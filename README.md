# remote-win-exec

Run PowerShell commands and scripts on a **paired remote Windows machine** over a
pre-provisioned SSH channel, in **both directions**.

This is a MiniMax Code **skill** that ships the whole channel, not only the
calling rules: the local wrapper, the remote runner, the installer, a read-only
health check and two end-to-end regression suites.

| | |
| --- | --- |
| **Directions** | this machine → peer, and peer → this machine |
| **Transport** | plain SSH with public-key auth (Windows OpenSSH) |
| **Exit codes** | exact, carried as data (`__RSH_EXIT__=`) - never inferred from the SSH status bit |
| **Encoding** | UTF-8 / GBK / UTF-16 detected per line; U+FFFD is passed through instead of being smoothed away |
| **Shell** | the target's default shell (pwsh / Windows PowerShell 5.1 / cmd.exe) is detected and adapted to |
| **Platform** | Windows on both ends |

## Install (first pair)

Prerequisite: the two Windows machines already reach each other with public-key
SSH - OpenSSH Server installed, keys exchanged, `~/.ssh/config` written on both
sides. The installer does not create keys or services.

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "<skill-dir>scriptsinstall-channel.ps1" -RemoteHost '<peer-user>@<peer-alias>'
```

It renders the wrapper into `/.ssh/rsh.ps1`, deploys this skill directory to the peer
together with the runner, and probes the channel end to end. It is idempotent: a
second run reports `[same]` and changes nothing. `-Check` reports what is installed
without touching anything.

## Use

Once the channel is up, the skill settles the direction itself and tells the
agent which entry point to call. In conversation it triggers on requests such as
"在远端跑", "到那台远程机器看看", or "run it on the remote box".

## Three things worth knowing

1. **The SSH client's output must be a file, never a pipe.** With a pipe the
   client can finish the protocol (channel freed, exit status received) and then
   never exit, so the caller waits forever. Measured on the paired machines: pipe
   shapes hung 3/3 on the peer while the originating machine was fine on 8/8 - so
   "it worked here" is not evidence. Every SSH call in this package redirects to
   a file. Evidence and the upstream issue trail:
   [docs/ssh-client-behavior.md](docs/ssh-client-behavior.md).
2. **The exit code travels as data.** A remote PowerShell does not pass on a
   nested process's status (cmd.exe does, PowerShell does not), so the runner
   prints `__RSH_EXIT__=<code>` and the caller parses it out of the stream.
3. **The target's default shell is discovered, not assumed.** The wrapper asks
   the peer what it is configured for and adapts. Setting both sides to pwsh is
   recommended, not required.

## Package layout

```text
remote-win-exec/
├── .minimax-plugin/plugin.json     package manifest
├── icon.png
├── LICENSE
├── README.md                       this file
├── README.zh-CN.md
├── docs/                           OpenSSH setup, deployment, client behaviour
└── skills/remote-win-exec/         the skill itself
    ├── SKILL.md                    the rules the agent follows
    ├── references/                 environment snapshot, symptom table, charset notes
    └── scripts/                    wrapper, runner, installer, health check, regressions
```

## Regression

```powershell
# forward (this machine → peer): encodings, ambiguous bytes, stderr, exit codes, large payloads
pwsh -NoProfile -ExecutionPolicy Bypass -File ".scripts	est-forward.ps1" -RemoteHost '<peer-user>@<peer-alias>'

# reverse (peer → this machine): output, exit code, stderr
pwsh -NoProfile -ExecutionPolicy Bypass -File ".scripts	est-reverse.ps1" -RemoteHost '<peer-user>@<peer-alias>'

# read-only health check
pwsh -NoProfile -ExecutionPolicy Bypass -File ".scriptscheck-channel.ps1"
```

## Licence

MIT - see [LICENSE](LICENSE).
