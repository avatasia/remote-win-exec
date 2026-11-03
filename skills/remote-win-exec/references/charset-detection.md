# Charset detection — how the wrapper decides

Mechanism behind the encoding behaviour described in SKILL.md. Read it when you
need to know *why* the wrapper picked a charset, or when a line decodes wrongly
and you want to know whether the detector or the producer was at fault.


Same order the Python detectors use (`chardet` / `charset-normalizer`):

1. **Declared encoding wins.** A BOM states the charset outright, so nothing is
   guessed: a UTF-8 BOM is stripped, UTF-16 LE/BE are decoded as such.
2. **Otherwise every candidate is tried and the most plausible one wins.** Each
   line is decoded as UTF-8, as ANSI (936) and as UTF-16 LE and BE, and each
   result is scored by how much it looks like real text: ASCII, ordinary
   punctuation and **common** Chinese characters score positive; a hanzi that
   is *not* a common one scores negative, because the classic mojibake
   signature (rare ideographs, the CP936 euro sign U+20AC, private-use
   characters, control characters) is made of exactly those. Counting
   characters is not enough: a GBK reading of UTF-8 Chinese yields *more*
   characters (3 bytes become 1.5 hanzi), so the wrong reading can out-score
   the right one. A line only switches charset when the gap to the runner-up
   is clear (>= 2 points); a near tie follows a verdict computed over the
   whole stream.
3. **U+FFFD is passed through untouched**, and the wrapper prints a
   `[rsh] warning:` line. The replacement character is something the *producer*
   emitted (it read a file with the wrong charset), not a symptom of our
   decoding, so it must not be smoothed away.

Why validity alone is not enough: the charsets overlap. The GBK bytes of **一**
(`D2 BB`) are also valid UTF-8, and so are the bytes of 专, 业, 丌, 丐 — a rule of
`valid UTF-8 therefore UTF-8` turns those characters into Cyrillic or Arabic
letters. Measured 2026-11-03: under that rule a GBK file containing 一 came back
as `ӻ`.

The opposite error is just as common and was measured the same day: scoring by
character *count* instead of character *commonness* mangled 4 of 10 realistic
Chinese lines (`提交信息：更新依赖版本` came back as `鎻愪氦淇℃伅...`), because the
GBK reading of their UTF-8 bytes produced 1.5x more hanzi and won the vote.
Scoring by common-character frequency fixed all 10.

The exit marker `__RSH_EXIT__=<code>` is stripped from the **raw bytes**, before
any decoding: it is always ASCII, while the payload around it can be in any
encoding, so looking for it after decoding would let a UTF-16 payload corrupt
it and lose the exit code.

Verified 2026-11-03 on the fixed channel — 32 scenarios, all passing: 8
byte-level unit fixtures (ASCII with CRLF, UTF-8 Chinese, GBK Chinese, GBK
ambiguous characters, UTF-16 LE, UTF-16 LE with ASCII, UTF-8 emoji, a mixed
UTF-8 + GBK stream) and 23 end-to-end runs (Chinese inline; exit codes 0 / 7 /
33; payload files in UTF-8 with and without BOM, GBK and ASCII; a remote program
writing raw GBK bytes; a stream mixing UTF-8 and GBK lines; a remote PowerShell
5.1 payload (ANSI stdout); UTF-16 output; a UTF-8 BOM stream; a 3000-line
payload over `scp`; remote stderr; and a 936 console, where the output bytes
came back as GBK and decoded correctly).

Re-verified on 2026-11-03 after the shell adaptation was added: the same matrix
(UTF-8 / GBK / UTF-16 / raw-GBK output, remote stderr, non-zero exit code)
passed with the target's `DefaultShell` set to each of `pwsh`, `cmd.exe` and
`powershell.exe` (Windows PowerShell 5.1) — 5 of 5 in all three. The large-payload
(`scp`) path was checked in all three as well: it used to report the wrong exit
code under a PowerShell default shell (1 instead of the payload's), because it
ran the copied script directly instead of through the runner's marker; it now
reports the payload's code everywhere. The target was set back to pwsh
afterwards.

Same day, after the charset scoring was changed to count only *common* Chinese
characters: a 10-line matrix of realistic Chinese output went from 6/10 to
10/10 correct, and the GBK cases (raw GBK bytes, a 936 console, ASCII mixed with
GBK Chinese) still decode as GBK.

Known limit: the common-character list is finite, so a line built only from
*uncommon* Chinese characters can still be read as the other charset. When in
doubt, read the value with an explicit encoding on the remote (next section)
instead of relying on detection.
