---
name: remote-win-exec
description: |
  Run PowerShell commands and scripts on the paired remote Windows host over the
  already-provisioned bidirectional SSH channel. Installed on both machines of the
  pair, and it settles the direction before acting (one side holds the wrapper,
  the other uses plain SSH). Use this skill when the user says "在远端跑", "远端执行",
  "到那台远程机器看看", "在远程 Windows 上执行", "run it on the remote box", or asks
  to inspect / build / run anything on the paired remote Windows host instead of on
  this machine. Also use it when the channel misbehaves — empty output, a wrong
  exit code, garbled text, publickey errors — it ships a read-only health check
  and a symptom table. Do NOT use it for work that must run on this machine, for a
  Linux host, for driving the remote desktop GUI, or for installing and repairing
  the channel itself (that is setup, not use).
---

# Remote Windows Exec

`<remote-host>` is already reachable from this machine over SSH with public-key auth, and a
script runner is deployed on both ends. This skill is about **calling that channel
correctly** — not about rebuilding keys, config, or the runner.

### Placeholders in this skill

Concrete host, account, key, path and repository names are masked so this file can
be shared. Resolve them at runtime rather than hard-coding them:

| Placeholder | Where the real value lives |
| --- | --- |
| `<remote-host>` / `<remote-user>` | the `Host` entry in the local `~/.ssh/config` (it also pins the key path) — present on both machines |
| `<local-host>` / `<local-user>` | this machine's alias, as seen from the remote's `~/.ssh/config` |
| `$env:USERPROFILE\.ssh\rsh.ps1` | the local wrapper to invoke |
| `$env:USERPROFILE\bin\rsh.ps1` | the remote runner, relative to the remote user's profile |
| `<projects-dir>` | where the remote keeps its repositories |

## Setup — first run on a pair

This skill ships the whole channel, not just the calling rules: `scripts/` holds the
local wrapper, the remote runner, the installer and the two regression suites.
Until the channel is deployed on the pair, nothing in this skill can run, so
deploy it first:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "<skill-dir>\scripts\install-channel.ps1" -RemoteHost '<remote-user>@<remote-host>'
```

`<skill-dir>` is the directory this `SKILL.md` lives in. The installer renders the wrapper into
`~/.ssh/rsh.ps1`, deploys this skill directory to the peer together with the runner, and
then probes the channel end to end. It is idempotent: running it again reports
`[same]` and changes nothing. `-Check` reports what is installed on
both sides - it reads the peer's hashes - and changes nothing.

The installer does **not** create SSH keys or the `sshd` service — the two machines
must already reach each other with public-key auth. Everything else the skill
needs is in this directory.

## Preflight — which side of the channel am I on?

This skill is installed on **both** machines, so settle the direction before
running anything. Do not assume which side you are on.

1. **Does the wrapper exist here?** `$env:USERPROFILE\.ssh\rsh.ps1`
   - **Yes** → this machine is the *originating* side: it holds the wrapper that
     ships payloads to the peer. Follow *Procedure* below.
   - **No, and no `bin\rsh.ps1` either** → the channel was never deployed on
     this pair. Go to *Setup* first.
   - **No** → this machine is the *peer* side: there is no wrapper here. (The
     `bin\rsh.ps1` that does exist is the **runner** the other side calls — it
     takes `-ScriptB64` and is not a client.) Run commands with plain
     `ssh <remote-host> "<cmd>"` and take the exit code from ssh itself: a bare
     ssh command's status comes back intact (verified 0 / 1 / 2 / 7 / 33 / 42 /
     255), because nothing is nested behind a runner.
2. **Resolve `<remote-host>`** from the local `~/.ssh/config`: the `Host` entry
   whose `User` / `IdentityFile` / `HostName` describe the paired machine. Both
   machines' configs carry such an entry, so this resolves from either side.
   On the originating side the peer alias is also the wrapper's default
   (`-RemoteHost <remote-user>@<remote-host>`), so step 1 usually needs nothing.

## Inputs to collect

- **Target host**: the peer of this machine — `<remote-host>` (= user `<remote-user>` @
  `<remote-ip>`), resolved from the local `~/.ssh/config` as described in
  *Preflight*. Only ask if the user names a different peer.
- **Payload**: the PowerShell to run remotely. If it is more than a one-liner, write it
  to a local temp `.ps1` and send it with `-ScriptFile` — see Procedure step 1.
- **Direction**: local → remote is the normal case. Remote → local is plain `ssh` and
  needs no runner (see *Reverse direction*).

## Procedure

1. **Choose the transport.**

   | Need | Use |
   | --- | --- |
   | Multi-line script, or a payload with `$` / nested quotes | local temp `.ps1` + `-ScriptFile '<path>'` |
   | One command, ASCII output, exit code not needed | `ssh <remote-host> "<cmd>"` |
   | One command that must return a reliable exit code | `-Script '<text>'` |

   Reason for `-ScriptFile`: the wrapper base64-encodes the payload and passes it on a
   command line. Windows caps a command line at ~32 KB and nested quoting breaks well
   before that — a payload with `$`, backticks, or double quotes gets mangled if inlined.
   The wrapper itself switches to `scp` above 16,000 base64 chars, so a large
   `-ScriptFile` is safe without you doing anything.

   Reason bare `ssh` is not the default for scripted work: it cannot report a spawned
   script's exit code (step 3). For a one-off ASCII read it is simpler.

2. **Invoke the local wrapper** for anything scripted:

   ```powershell
   pwsh -NoProfile -ExecutionPolicy Bypass -File $env:USERPROFILE\.ssh\rsh.ps1 -Script 'Write-Output "ping"'
   ```

   `-RemoteHost <remote-user>@<remote-host>` is the default; pass it only for a different peer.
   Equivalent: `powershell -NoProfile -ExecutionPolicy Bypass -File <same path>` — both
   were exercised.

3. **Take the exit code from the wrapper's own exit status**, not by parsing stdout.
   The wrapper already strips the remote `__RSH_EXIT__=<code>` line and exits with that
   code, so the exit status of the command in step 2 **is** the remote script's exit code.
   Reason: `sshd` runs the remote command through the target's configured default
   shell (cmd.exe unless `DefaultShell` says otherwise), whose status comes from
   the outermost process — and the outermost process is the runner's `pwsh`, which
   prints the payload's code in a marker line and then exits 0 by itself. Measured: a
   payload that exited 33 arrived at ssh as 0, while a bare `ssh <remote-host> "exit 33"` came
   back as 33. The marker is the only reliable channel for a spawned script.

   A bare `ssh <remote-host> "<cmd>"` also returns its exit code intact (verified
   0 / 1 / 2 / 7 / 33 / 42 / 255) — nothing is nested behind a runner on that path,
   as long as the command runs directly in the remote shell. Nesting a PowerShell
   changes that: see *Running from the peer side* for the measured numbers.

4. **Report the result**: what ran, the remote exit code, and the remote output
   verbatim. Quote output instead of paraphrasing it — callers usually need the raw
   values (sizes, versions, paths).

5. **Do not rebuild the channel.** Keys, `~/.ssh/config` on both ends, `known_hosts`,
   and both `rsh.ps1` copies are in place and verified. If SSH itself fails with
   `Permission denied (publickey)` or `Host key verification failed`, report that as a
   channel problem — do not regenerate keys or re-run `ssh-keyscan` mid-task.

## Which shell the remote command is written for

The wrapper does not assume a shell. Before each run it asks the target what its
SSH default shell is and spells the remote command for the shell that is actually
in effect.

`rsh.ps1` is a **PowerShell script**, so it always needs a PowerShell to host it -
cmd.exe cannot run a `.ps1` at all. That is why the cmd.exe form names a
PowerShell explicitly instead of calling the script:

| Target `DefaultShell` | How the runner is invoked |
| --- | --- |
| pwsh, or Windows PowerShell (`powershell.exe`) | `& (Get-Process -Id $PID).Path -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\bin\rsh.ps1" -ScriptB64 <payload>` |
| cmd.exe | `"<pwsh path on the target>" -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\bin\rsh.ps1" -ScriptB64 <payload>` |

- The cmd.exe form resolves the PowerShell executable **on the target** (registry
  `PowerShellCore`, then `where pwsh`), so it does not depend on the session's
  PATH.
- The payload still runs as a PowerShell script, so nothing changes for whoever
  writes it: it is PowerShell under every default shell.
- The exit code always comes back through the runner's `__RSH_EXIT__` marker -
  including the large-payload (`scp`) path, which runs the copied script in a
  child process for exactly that reason. A script invoked with `&` swallows its
  own exit code, and the remote shell's rules for reporting a nested process's
  status differ between cmd.exe and PowerShell, so neither can be trusted to
  carry it.

The two spellings are not interchangeable: the PowerShell form (`&`, `$env:`) is a
syntax error under cmd.exe, and the cmd form's `%USERPROFILE%` is not expanded by
PowerShell - it would be taken literally and the runner would not be found. The
probe costs one extra round trip per wrapper process and is cached for the life of
that process.

### Checking the target's default shell yourself

The wrapper does this on every run, so you rarely need to. To look it up
directly:

```powershell
ssh <remote-host> 'reg query "HKLM\SOFTWARE\OpenSSH" /v DefaultShell'
```

The value is read **per connection**, so changing it on the target takes effect on
the next connection - no `sshd` restart involved.

### If the local shell is cmd.exe

Every command in this skill is written in PowerShell syntax. When you drive the
wrapper from cmd.exe, use the cmd form:

```cmd
pwsh -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\.ssh\rsh.ps1" -ScriptFile "D:\path\probe.ps1"
```

`%USERPROFILE%` instead of `$env:USERPROFILE`, double quotes instead of single
quotes, no PowerShell operators. The payload file itself is unaffected - it is
PowerShell either way.

## Text encoding — the one thing that bites

**As of 2026-11-03 the channel is UTF-8 end-to-end *and* detects the charset of
the remote's output instead of mangling it.** Three layers cooperate:

| Layer | Role |
| --- | --- |
| Remote runner `$env:USERPROFILE\bin\rsh.ps1` | runs `chcp 65001` before launching the payload, so a PowerShell payload writes UTF-8 |
| Both machines' PowerShell profiles | `chcp 65001` plus UTF-8 `$OutputEncoding` / `[Console]::OutputEncoding`, so interactive shells are UTF-8 too (the remote user's profile is on a non-system drive) |
| Local wrapper `$env:USERPROFILE\.ssh\rsh.ps1` | reads ssh's stdout as **raw bytes** and **detects** the charset: declared encoding first (BOM), then a plausibility vote between UTF-8, the ANSI code page (936) and both UTF-16 orders |

The wrapper reads the pipe's `BaseStream` directly instead of letting the shell
decode it. PowerShell would decode a native command's stdout with the console
code page, turning a remote GBK byte into U+FFFD before any fix was possible.

### How the detection works

Short version: a declared encoding (BOM) wins; otherwise each candidate
(UTF-8, ANSI 936, UTF-16 LE/BE) is decoded and scored on how much it looks
like real text — ASCII and **common** Chinese characters score positive, rare
ideographs and control characters score negative — and a line only switches
charset when the gap to the runner-up is clear. The scoring rules, the
mojibake signatures they were built against, and the measurements behind them
are in `references/charset-detection.md`.

### Reading a non-UTF-8 file on the remote — the one case the channel cannot fix

The damage happens before the bytes travel: PowerShell 7 reads a GBK file as UTF-8
by default, so the remote already holds U+FFFD and no local decoder can recover
bytes that no longer exist. Read the file explicitly:

```powershell
Get-Content $file -Encoding ansi                                    # PowerShell 7
[IO.File]::ReadAllText($file, [Text.Encoding]::GetEncoding(936))     # exact
```

`Get-Content $file` with no `-Encoding` on a GBK file is the usual mistake, and
the usual cause of the `[rsh] warning:` line.

### Fallback routes (rarely needed now)

If a program still comes back garbled, keep the bytes out of PowerShell entirely
and carry them home as base64:

```powershell
# Recipe A — native cmd redirection, then read the raw bytes
$tmp = Join-Path $env:TEMP ('gb_' + [Guid]::NewGuid().ToString('N') + '.txt')
cmd.exe /c "git --no-pager -C D:\path\repo log -1 --pretty=oneline > $tmp"
$b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($tmp))
Remove-Item $tmp -Force
Write-Output $b64
```

```powershell
# Recipe B — .NET Process, read stdout as UTF-8
$psi = [Diagnostics.ProcessStartInfo]::new()
$psi.FileName = 'git'
$psi.Arguments = '--no-pager -C D:\path\repo log -1 --pretty=oneline'
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.StandardOutputEncoding = [Text.Encoding]::UTF8
$p = [Diagnostics.Process]::Start($psi)
$text = $p.StandardOutput.ReadToEnd()
$p.WaitForExit()
Write-Output ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text)))
```

Decode the base64 locally as UTF-8. A third verified route is
`git cat-file commit HEAD`, which writes the raw commit object.

These routes were cross-checked against each other on 2026-11-03 and returned
identical text (`<中文提交标题>`). Recipe A when the program writes
bytes to stdout; Recipe B when you want the text directly.

If you only need ASCII, plain `Write-Output` is fine. For a one-off non-ASCII read,
bare `ssh <remote-host> "git -C ... log -1"` is simpler — its bytes go straight through the ssh
pipe and never touch a PowerShell string.

## Paired machine facts

The peer's measured state — default shell, code pages, disk headroom, repo
layout — lives in `references/paired-facts.md`, each row stamped with the date
it was measured and the command that re-measures it. **It drifts**: re-read
whatever you depend on before using it.

One of those facts shapes how you write a payload, and the channel enforces it
by itself:

- **The remote shell is whatever the target is currently set to — the wrapper adapts
  to it.** The channel does not require pwsh: before each run the wrapper asks the
  target what its SSH default shell is and spells the remote command for the shell
  that is actually in effect (pwsh, Windows PowerShell 5.1 and cmd.exe are all
  supported). The value is read per connection, so a change on the target is
  picked up by the next run — no `sshd` restart involved.

Changing the target's default shell is a machine-level write, not a channel
setting: it changes the shell of every SSH session on that machine. It is not
this skill's job — `references/paired-facts.md` carries the measured value and
the blast radius.

## Reverse direction (peer → originating)

From the peer side, commands run back to the originating machine over plain
SSH: there is no script runner on the originating side for that direction, and
the peer's own `bin\rsh.ps1` is the runner the originating side calls, not a
client.

Call the shipped runner instead of invoking `ssh` yourself — it already applies
the two rules that make this direction work:

``powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "<skill-dir>\scripts\reverse-run.ps1" -Command 'Get-Date'
``

- **The ssh client's stdout must be a file, not a .NET pipe.** With a pipe the
  client completes the SSH protocol (channel freed, exit status received) and
  then never exits, so the caller's PowerShell capture (@$out = & ssh ...`)
  hangs forever. Measured 2026-11-03: it reproduced against any target, while
  the same command with the output redirected to a file exited in about a
  second. `reverse-run.ps1` redirects to a temp file and reads that.
- **The rule covers every ssh call, in both directions.** On the paired pair
  the pipe shapes hung on 3/3 runs on the peer and were fine on 8/8 on the
  originating machine, so "it worked here" is not evidence that a pipe is
  safe. The file shape behaved on both. The peer's runs happened inside an
  ssh session - a nested ssh client, which is what both directions of this
  channel actually are. See `references/troubleshooting.md`.
- **The exit code travels in a marker.** The remote shell does not pass on a
  nested PowerShell's status (cmd.exe does, PowerShell does not), so the runner
  prints `__RSH_EXIT__=<code>` and exits with that code.

Only a command that runs directly in the remote shell (@exit 7`, `hostname`) may
be trusted to report its status through ssh — but that is exactly the path that
hangs on the peer side, so use the marker instead.

`<local-host>` / `<local-user>` — this machine's alias as seen from the remote's
`~/.ssh/config`. The runner resolves it from the config entry whose
`HostName` is one of this machine's addresses; pass
`-RemoteHost <user>@<alias>` when that does not match.

The peer must already trust the originating machine's host key: without a
`known_hosts` entry, ssh asks "are you sure?" and a scripted call blocks on the
prompt. Confirming a host key is a trust decision for the user — report it
rather than auto-accepting it from a script.

## Output contract

- The remote script's stdout/stderr, unmodified, plus its exit code.
- If the script produced no output, say so explicitly rather than reporting a blank
  success — an encoding failure and a genuinely empty run look identical from here.

## Diagnosis — which layer owns the problem

Four layers. Check them in this order, and do not re-derive a layer that
already owns the check.

| Layer | Who decides | Where it lives |
| --- | --- | --- |
| Install-time facts (sshd up, key exchange, file SHAs) | the installer, at install time | repo `scripts/install-channel.ps1` — setup, not this skill |
| Runtime health (role, peer reachability, runner/skill present, probe) | `scripts/check-channel.ps1`, read-only | this skill's `scripts/` |
| Known pitfalls (garbled text, lost exit code, quoting, large payloads) | you, using the table | `references/troubleshooting.md` |
| What to do about it (retry, switch transport, report, stop) | you | this section |

### 1. Run the read-only check first

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "<skill-dir>\scripts\check-channel.ps1"
```

It prints one `OK|WARN|FAIL|<check>|<detail>|<action>` line per check, ends
with `CHECK_SUMMARY ok=.. warn=.. fail=..`, and exits 0 (all OK) / 1 (a FAIL) /
2 (warnings only). It changes nothing on either machine. Run it before a long
payload when you are unsure the channel is up, and again after a failure — it
separates "the channel is broken" from "the payload was wrong".

It takes the peer from the wrapper's own destination. On the peer side (no
wrapper here) it may report several config candidates rather than guessing —
pass `-RemoteHost <user>@<alias>` in that case.

### 2. Match the symptom

`references/troubleshooting.md` gives, for each symptom, the probe that decides
the cause and the action for it: empty output, a wrong exit code, garbled text,
publickey errors, quoting through two shells, oversized payloads, an ssh
client that finishes but never exits, a remote probe that never comes back, a
null service property on the peer, a leftover `nul` file, and an exit code lost
to a truncated pipe.

### 3. Decide

- **The check passes, the payload misbehaves** → the payload is the problem.
  Fix the payload; do not rebuild the channel.
- **The check reports a FAIL** → it names the missing piece and the repair.
  Installing or repairing the channel is a setup action, not something this
  skill does on its own: report it and let the user decide.
- **Two probes disagree** (ssh works, the channel does not) → the remote side
  is the suspect: the runner is missing or stale, or the target's default
  shell changed.

### 4. Already handled by the harness — do not work around these

- **Large payloads**: the wrapper switches to `scp` by itself above 16,000
  base64 characters; you never chunk anything yourself.
- **Exit codes**: they travel in the runner's `__RSH_EXIT__=` marker, so the
  payload's code is exact whatever the target's default shell is. (A payload
  invoked with `&` on the remote would swallow its own code — the wrapper
  spawns a child process for exactly that reason.)
- **Charset**: the wrapper detects UTF-8 / ANSI(936) / UTF-16 and passes
  U+FFFD through instead of smoothing it away.
- **Temp files**: the wrapper deletes its own payload file and the remote
  `rshsend.ps1`. Files you create yourself go through the recoverable trash
  flow (`$env:USERPROFILE\.minimax\bin\mavis-trash.cmd`), never a permanent
  delete command.

## Windows (win32) platform notes

- Invoke the wrapper as `pwsh -NoProfile -ExecutionPolicy Bypass -File <path>`.
  The commands in this skill are PowerShell syntax; from cmd.exe use the form
  in *If the local shell is cmd.exe*.
- Prefer `-ScriptFile` over `-Script` for anything multi-line. Single-quoted
  one-liners survive the trip; multi-line payloads and `$` do not.
- The payload runs on the remote with `-NoProfile`, so it does not see profile-defined
  aliases, functions, or `$env:PATH` additions from the remote user's profile. Use
  absolute paths and `Join-Path`.
- The remote payload is a PowerShell script, not a cmd batch file — use cmd syntax only
  if you deliberately invoke `cmd /c` inside it (which is also how you get native byte
  redirection, see *Text encoding*).

## Examples

Input: "看看 <remote-host> 上 `<projects-dir>` 有哪些 git 仓库"

   ```powershell
   pwsh -NoProfile -ExecutionPolicy Bypass -File $env:USERPROFILE\.ssh\rsh.ps1 -Script 'Get-ChildItem <projects-dir> -Directory | Where-Object { Test-Path (Join-Path $_.FullName ".git") } | Select-Object -ExpandProperty Name'
   ```

Result: the repo names on stdout, exit code 0. This one-liner skips hidden items, so the root `.git` skeleton does not
appear; add `-Force` and you must then exclude `<projects-dir>\.git` explicitly.

Input: "在 <remote-host> 上把 <repo-a> 的当前分支和最后一次提交打出来"

Write a local temp `probe.ps1` with the git calls, then:

   ```powershell
   pwsh -NoProfile -ExecutionPolicy Bypass -File $env:USERPROFILE\.ssh\rsh.ps1 -ScriptFile '<temp>\probe.ps1'
   ```

Chinese commit subjects come back correctly through the wrapper (verified
2026-11-03). If one specific program still garbles, use Recipe A or B from
*Text encoding*.
