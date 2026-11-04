# Troubleshooting — symptom → probe → action

Each entry gives the symptom, the probe that **decides** between the candidate
causes, and the action. Run the probe before acting: the action for the wrong
cause makes things worse.

Machine-readable health is a separate class — run
`scripts/check-channel.ps1` first (it covers "is the channel up"). This file
covers "the channel is up but the result is wrong".

## Output empty, or the exit code looks wrong

| Probe | Result | Action |
| --- | --- | --- |
| `pwsh -NoProfile -ExecutionPolicy Bypass -File $env:USERPROFILE\.ssh\rsh.ps1 -Script 'Write-Output "ping"'` | prints `ping` | the channel is fine, the payload is the problem. Check how it was sent: `-Script` for one-liners, `-ScriptFile` for anything containing `$`, quotes or multiple lines |
| | prints nothing | the channel is broken — run `scripts/check-channel.ps1` |

## Exit code is 1 but the payload should return something else

Only a command that runs **directly in the remote shell** reports its status
through ssh. Measured 2026-11-03:

| Remote command | target default shell = pwsh | = cmd.exe |
| --- | --- | --- |
| `exit 7` | 7 | 7 |
| `cmd /c exit 7` | 1 | 7 |
| `pwsh -NoProfile -Command "exit 7"` | 1 | 7 |

PowerShell does not pass on a nested process's status (always 1); cmd.exe
does. Through the wrapper this never happens — the exit code travels in the
runner's `__RSH_EXIT__=` marker and is exact on every shell.

**Action**: never trust the ssh status bit for a nested command. Send the code
as data (`__RSH_EXIT__=<code>`) or go through the wrapper.

## Garbled output (`鏂板細...`, `鎻愪氦...`)

| Probe | Result | Action |
| --- | --- | --- |
| look for a `[rsh] warning:` line in the output | present | the **remote** decoded it wrongly — usually `Get-Content` without `-Encoding` on a GBK file. The bytes are already lost there: re-read on the remote with `-Encoding ansi` |
| | absent | the wrapper's detection picked the wrong charset — read the value on the remote with an explicit encoding (`Get-Content -Encoding ansi`, `[IO.File]::ReadAllText($f, [Text.Encoding]::GetEncoding(936))`), or carry it home as base64 (Recipe A/B in SKILL.md) |

Known limit: the detector votes on **common** Chinese characters, so a line
built only from uncommon characters can still be misread. An explicit encoding
always beats detection.

## Garbled text in an **interactive** shell (the channel itself is fine)

The symptom above is about the channel's output. This one is about a terminal the
user is sitting at: the channel passes Chinese through correctly, but their own
console still uses the system ANSI code page (936 on a Chinese Windows).

| Probe | Result | Action |
| --- | --- | --- |
| `chcp` in the affected terminal | prints a code page other than 65001 | the console is not UTF-8. **Optional** fix: add the two UTF-8 lines to that shell's PowerShell profile — `scripts/set-utf8-profile.ps1 -Apply` (it backs the file up first), or edit the profile by hand. Tell the user first: it changes what every new shell starts with, and the channel does not need it |
| | prints 65001 | the console is already UTF-8; the cause is elsewhere — use the table above |

## `Permission denied (publickey)`

| Probe | Result | Action |
| --- | --- | --- |
| `ssh <remote-host> "hostname"` | fails | the SSH layer itself is wrong (key not in `authorized_keys`, wrong `IdentityFile`) — setup, not this skill. Report it; do not regenerate keys mid-task |
| | succeeds | the key works, so the failure is inside the channel — run `scripts/check-channel.ps1` |

## ssh hangs asking to confirm the host key

A machine that has no `known_hosts` entry for the peer asks "are you sure?"
and waits on stdin — a scripted call blocks forever instead of failing.

| Probe | Result | Action |
| --- | --- | --- |
| `ssh <peer> "hostname"` (interactive) | asks to confirm | the host key is unknown to this machine. Accepting it is a **trust decision for the user**, not something a script should do on its own: report it, let the user confirm once, and the key lands in `known_hosts` |

The health check never triggers that prompt: it passes
`-o StrictHostKeyChecking=yes`, so an unknown key fails immediately.

## `Host key verification failed`

The peer's host key is not in `known_hosts`. Setup, not this skill: report
it. Do not run `ssh-keyscan` and feed it in without the user's decision.

## The target's default shell changed and commands look wrong

```powershell
ssh <remote-host> reg query HKLM\SOFTWARE\OpenSSH /v DefaultShell
```

Read per connection, so a change takes effect on the next run with no `sshd`
restart. The wrapper adapts (pwsh / Windows PowerShell 5.1 / cmd.exe all work),
so nothing has to change on this side — but `& $env:USERPROFILE`-style payloads
and `%USERPROFILE%` expansions differ per shell, so check what the payload
assumes. The current measured value and the blast radius of changing it are in
`references/paired-facts.md`.

## The ssh client finishes the command but never exits

Measured 2026-11-03: the client completes the SSH protocol — it logs
`channel 0: free` and `Exit status 0` — and then the ssh **process never
exits**, so the caller waits forever. The server side is clean: no session
process is left behind and the exit status arrived, so the stall is in the
client's teardown.

| Probe | Result | Action |
| --- | --- | --- |
| capture the output in PowerShell (@$out = & ssh ...`) | hangs | the client's stdout is a pipe. Redirect it to a file: `Start-Process -RedirectStandardOutput <file> -RedirectStandardError <file>` |
| redirect the output to a file | exits in ~1 s with the right output and exit code | the file redirection is the fix — keep using it |
| `ssh -v ...` | the log stops at `client_input_channel_req: channel 0 rtype exit-status reply 0` | the protocol is done; only the teardown is stuck |

**Which machine it happens on decides whether you believe it.** On the paired
pair the pipe shapes hung on 3/3 runs on the peer and were fine on 8/8 on the
originating machine; the file shape behaved on both. The peer's runs happened
**inside an ssh session** — a nested ssh client, which is what both directions
of this channel actually are. So "it worked on my machine" is not evidence
that a pipe is safe: use a file for every ssh call, in both directions.

It is not about the remote machine either: the same call reproduced against an
unrelated target, and both machines run the identical ssh.exe build
(1,256,448 B, 9.5p2). What decides it is the client's own stdio.

The same failure is reported upstream (Win32-OpenSSH #1330, #1334, #1427),
and the workaround those threads recommend is exactly the file redirection.

`-T` (no pseudo-terminal) and `-n` (stdin from NUL) are belt-and-braces,
not a substitute: with the pipe shape they still hang (3/3 on the peer). The
file redirection is what does the work.

Never capture ssh's output through a pipe. `reverse-run.ps1`,
`check-channel.ps1` and the wrapper's own ssh call all redirect to files for
this reason.

## A remote probe that never comes back

The local side waits for the remote command, and a long remote batch (many
probes, a parameter matrix) can outlast that wait. The local call is then cut
at its timeout and you get **no output at all** — which looks like the remote
died, while the remote may have finished or still be running.

| Probe | Result | Action |
| --- | --- | --- |
| ask the remote whether its result file exists (a second, short call) | the file is there with content | the remote finished and the local wait was cut. Fetch the file — do not re-run the batch |
| | no file, and the remote process is still running | the remote is slow: let it finish, then fetch |
| | no file and no process | the remote never started: send the script again |

Deliver the script, have the remote start it in the background
(`Start-Process ... -RedirectStandardOutput <file>`), and fetch the result file in a
separate call. The remote script should carry its own timeout and clean up
after itself, or it leaves orphans behind.

## The health check on the peer side reports several candidates

| Probe | Result | Action |
| --- | --- | --- |
| `check-channel.ps1` on the peer prints `WARN|ssh-config|several config entries qualify` | the peer's `~/.ssh/config` has more than one entry carrying both `User` and `IdentityFile` | not a defect: the check refuses to guess which host is the pair. Re-run with `-RemoteHost <user>@<alias>` |

## A remote payload fails on a null service property

| Probe | Result | Action |
| --- | --- | --- |
| the payload raises `You cannot call a method on a null-valued expression` on a service property | inside an SSH session `Get-Service` returns the service but its `StartTime` is null | read the service with `Get-CimInstance Win32_Service -Filter "Name='<name>'"` and use `State` / `StartMode`; never call a method on `StartTime` |

## `2>nul` leaves a real file named `nul` on the peer

| Probe | Result | Action |
| --- | --- | --- |
| a zero-byte file called `nul` appears in the peer's home or temp directory | the payload used `2>nul` while the peer's default shell is PowerShell, which does not know `nul` as the null device | in PowerShell write `2>$null` (or `2>&1` to merge it into stdout); `2>nul` is only correct under cmd.exe |

Removing it needs the `\\?\` form of the path (`\\?\C:\Users\<user>\nul`) — the plain path resolves to the
device name — and goes through the recoverable trash flow.

## Measuring an exit code through a truncated pipe loses the code

| Probe | Result | Action |
| --- | --- | --- |
| `$LASTEXITCODE` is empty after a call whose output was piped into `Select-Object -First N` | the pipe was closed early, which killed the upstream process | collect the whole output into a variable first, then read `$LASTEXITCODE` |

## The payload is too large

Not a failure mode: the wrapper switches to `scp` by itself above 16,000
base64 characters and reports the exit code through the same marker. Use
`-ScriptFile` and let it happen.

## A hand-copied .ps1 comes back garbled on Windows PowerShell 5.1

A script copied to the remote must carry a UTF-8 BOM, or PS 5.1 reads it as
ANSI. The wrapper writes the BOM itself; hand-copied scripts need it.

## The local shell is cmd.exe

Call the wrapper with the cmd form:

```cmd
pwsh -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\.ssh\rsh.ps1" -ScriptFile "D:\path\probe.ps1"
```

A quoted one-liner through two shells still loses its quoting — prefer
`-ScriptFile`, or `pwsh -EncodedCommand` for a remote one-liner.

## Already handled — do not work around these

- **Large payloads**: the wrapper switches to `scp` above 16,000 base64
  characters on its own.
- **Exit codes**: they travel in the runner's `__RSH_EXIT__=` marker, so they
  are exact whatever the target's default shell is.
- **Charset**: the wrapper detects UTF-8 / ANSI(936) / UTF-16 and passes
  U+FFFD through instead of smoothing it away.
- **Temp files**: the wrapper deletes its own payload file and the remote
  `rshsend.ps1`. Files you create yourself go through the recoverable trash
  flow (`$env:USERPROFILE\.minimax\bin\mavis-trash.cmd`), never a permanent
  delete command.
