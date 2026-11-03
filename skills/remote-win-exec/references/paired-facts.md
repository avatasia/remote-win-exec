# Paired machine facts

Measured state of the machine that hosts the runner
(`$env:USERPROFILE\bin\rsh.ps1`) — i.e. the peer of whichever side you are on.
On the peer side, read "remote" as "this machine".

**These values drift.** Each row carries the date it was measured. Re-read
anything you depend on before using it; the "re-measure" column is the command.

| Fact | Measured value | On | Re-measure with |
| --- | --- | --- | --- |
| SSH default shell, both machines | `C:\Program Files\PowerShell\7\pwsh.exe` (pwsh 7.6.9) | 2026-11-03 | `ssh <remote-host> reg query HKLM\SOFTWARE\OpenSSH /v DefaultShell` |
| System ANSI code page | 936 | 2026-11-03 | `chcp` in a cmd shell — `[Text.Encoding]::Default` under .NET Core returns utf-8 and is **not** the ACP |
| Console code page (interactive) | 65001 | 2026-11-03 | `chcp` |
| Remote account privileges | in the local `Administrators` group, so SSH sessions are elevated | 2026-11-03 | `ssh <remote-host> "net localgroup Administrators"` |
| Disk headroom | the data volume was low | 2026-11-03 | `ssh <remote-host> "Get-PSDrive -PSProvider FileSystem"` |
| Repos under `<projects-dir>` | 5 `.git` directories but only 4 real repos — `<projects-dir>\.git` is a skeleton (no HEAD / config / index), so `git -C <projects-dir>` fails | 2026-11-03 | see below |
| Repos with no git remote | at least one (`git remote -v` empty) — never plan a push there | 2026-11-03 | `git -C <repo> remote -v` |
| Working tree of the active repo | clean except one untracked directory | 2026-11-03 | `git -C <repo> status --short` |

Counting the real repos (the root `.git` skeleton is not a repo):

```powershell
Get-ChildItem <projects-dir> -Directory -Force |
  Where-Object { Test-Path (Join-Path $_.FullName '.git') } |
  ForEach-Object { "$($_.Name): $(git -C $_.FullName rev-parse --is-inside-work-tree 2>&1)" }
```

Only the first row matters to the channel itself: the wrapper asks the target
for its default shell on every run and adapts, so nothing here is a
precondition. The rest is context that saves a round trip.

## If the default shell has to change

Changing `HKLM\SOFTWARE\OpenSSH\DefaultShell` is a **machine-level write**,
not a channel setting:

- it changes the shell of **every** SSH session on that machine — interactive
  ones and scheduled jobs included;
- it is read **per connection**, so it takes effect on the next connection and
  needs no `sshd` restart;
- it needs an elevated session on the target;
- aligning both machines is a convenience, not a requirement — the channel
  works with pwsh, Windows PowerShell 5.1 or cmd.exe on either side.

Do not change it from this skill: it is outside the channel's scope. Report the
current value and the blast radius, and let the user decide.
