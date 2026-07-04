# PokéParty Desloppify Report

Full review of `gen3.lua` (998 lines), `party-hud.lua` (1284 lines),
`wheel.lua` (268 lines), `Makefile`, `README.md`, `SETUP.md`, and
`sounds/`. No changes made — this is the read-only scan requested. Pick a
task below and I'll implement it.

---

## Critical

### 1. Copyrighted audio checked directly into the repo
**Where:** `sounds/` — `shot2.wav` (LMFAO "Shots"), `badge.wav` (Final
Fantasy victory fanfare), `danger2.wav` (Benny Hill theme), `important*.wav`
(John Cena, "Jesus Even Flow"), `faint3.wav` (Curb Your Enthusiasm theme),
and others pulled from YouTube via `yt-dlp` this session.
**Why it matters:** these are commercial, copyrighted works (songs, TV
themes, movie score cues), not licensed SFX. Checked into a git repo that's
already pushed to a public-capable GitHub remote. Fine for personal/private
use at a party; a real problem the moment this repo is public, forked, or
shared beyond the two machines it's meant for.
**Recommend:** decide the repo's actual visibility. If it's staying private,
document that explicitly (e.g. a note in README) so nobody flips it public
without noticing. If it might go public, move `sounds/` to `.gitignore` and
distribute the actual files out-of-band (a private share, not the repo).
**Safe now or wait:** wait — needs your call on repo visibility, not a
code fix.

### 2. Killing PIDs from a stale file with no identity check
**Where:** `party-hud.lua` `stopDangerMusic()` (~line 111) and the
`MGBA_PID` watchdog it spawns (~line 94) both do `kill $(cat pidfile)`
with nothing verifying the PID in that file is still *the same process*
that wrote it.
**Why it matters:** if mGBA crashes or is killed (`kill -9`) without
`stopDangerMusic`/the "stop" callback ever running, `/tmp/pokeparty_danger.pid`
is left containing a PID that's since exited. Linux recycles PIDs — the
next process to get that number could be *anything* on the system. Next
time `startDangerMusic`→eventual `stopDangerMusic` runs, it could send
`kill` to a total stranger process. Low probability in practice (short
window, single-user machine) but a real correctness gap, and exactly the
kind of thing that's invisible until it isn't.
**Recommend:** before killing, verify the PID's command line actually
looks like our own spawned loop (e.g. read `/proc/<pid>/cmdline` and check
it contains `paplay` and our `SOUND_DIR`) before sending the signal.
**Safe now or wait:** safe to fix now — small, isolated, easy to verify by
re-running the same tests already used to validate the watchdog earlier
tonight.

### 3. Binary audio bloat baked into git history
**Where:** `sounds/` is 83MB on disk; `.git/` is already 75MB after one
night of iterating on sound files (several were renamed/replaced multiple
times — `danger.wav`→`danger1.wav`, `badwheel.wav`→`badwheel1.wav`, etc. —
each rename/replace keeps the old blob in history too).
**Why it matters:** git never forgets a committed blob short of history
rewriting. Every future round of "try a new sound, doesn't work, try
another" permanently grows the repo. Clone/fetch time and disk usage will
keep climbing, and it's not something a later cleanup pass can easily fix
without rewriting published history (disruptive, especially with two
machines already using this remote).
**Recommend:** decide now, before it gets worse: either (a) move `sounds/`
out of git entirely (sync via the same out-of-band channel as #1), or (b)
accept the growth as a known cost of this project. If (a), do it before
many more sound-iteration rounds — rewriting history later gets more
painful the longer it's put off.
**Safe now or wait:** wait — this is a repo-structure decision, not a code
change; also interacts directly with #1.

---

## Medium

### 4. Several ROM addresses are unverified guesses, not confirmed facts
**Where:** `gen3.lua` — `AXVE`/`AXPE` (Ruby/Sapphire) `STAGES` list, badge
graphics address, and badge hues all currently just alias Emerald's
verified values with a comment saying so. `enemyParty` is only set for
`BPEE`; FireRed/LeafGreen/Ruby/Sapphire get `nil` and silently skip the new
enemy-defeat detection.
**Why it matters:** these degrade gracefully (nil-checks throughout mean
no crash), but anyone playing RS or FRLG/RS tonight gets a real feature gap
without any indication why — the danger-music-outlives-combat fix simply
doesn't apply outside Emerald.
**Recommend:** already tracked in project memory backlog; the same live
memory-probe technique proven tonight (encode player name + TID, search
`/proc/PID/mem`) is fast to repeat next time one of those ROMs is running.
No code change needed until then.
**Safe now or wait:** wait — needs a live session on those specific games,
can't verify offline.

### 5. `party-hud.lua` has grown into one large multi-concern file
**Where:** the whole file — canvas drawing, save-persistence/rollback
logic, RAM-diff event detection, audio playback infrastructure (`playSound`,
danger-music start/stop/watchdog), and wheel integration are all in one
1284-line file with no internal module boundaries.
**Why it matters:** each piece individually is well-commented and
readable, but the file as a whole is a lot to hold in your head at once,
and it'll only keep growing as more features land (tonight alone added
~150 lines of audio infrastructure into it). Future changes risk touching
unrelated logic by accident just from proximity.
**Recommend:** split the audio playback machinery (`playSound`,
`startDangerMusic`, `stopDangerMusic`, `MGBA_PID`, `SOUND_*` constants —
roughly lines 17-114) into its own `audio.lua` module, `dofile`'d the same
way `gen3.lua`/`wheel.lua` already are. It's the most self-contained chunk
(only talks to the rest of the file through `playSound(name)` and the two
start/stop functions) and the newest/least-tested code, so isolating it
now is cheapest before more logic accretes around it.
**Safe now or wait:** safe now, but do it as its own isolated change (pure
move, no behavior change) so it's easy to verify nothing broke.

### 6. Duplicated "numbered-variant scan" logic
**Where:** `party-hud.lua` — the `while true do ... io.open(name%d.wav) ...`
loop appears twice, nearly identically: once in `playSound()` (~line 39),
once in `startDangerMusic()` (~line 86).
**Why it matters:** two copies of the same logic drift apart over time —
already slightly different (one takes a `name`, one is hardcoded to
`"danger"`). A future change to the variant convention (e.g. supporting
`name01.wav` for double-digit counts) means remembering to fix it twice.
**Recommend:** extract a shared `countVariants(name)` helper both call.
**Safe now or wait:** safe now — small, mechanical, easy to verify (same
launch-test used all session).

### 7. Hardcoded `/tmp` paths with no per-instance uniqueness
**Where:** `party-hud.lua` — `/tmp/pokeparty_mgba_pid.txt`,
`/tmp/pokeparty_danger.pid`, both fixed strings.
**Why it matters:** fine for the single-instance, single-user use case
this was built for. But if two mGBA+HUD instances ever run at once on the
same machine (testing two ROMs side by side, or a shared machine with
multiple users), they'd silently stomp each other's PID files and
danger-music watchdog state.
**Recommend:** suffix with the HUD's own PID or a random token generated
once at load. Low priority unless multi-instance use is ever actually
planned.
**Safe now or wait:** safe now, but low value until multi-instance is a
real scenario — fine to leave.

### 8. Docs have drifted behind the code
**Where:** `SETUP.md`'s env var table (missing `POKEPARTY_SOUND`,
`POKEPARTY_SFX_VOLUME`, `POKEPARTY_BADGE_COLORS`, `POKEPARTY_CANDY_KEY`,
`POKEPARTY_CANDY_PAD`); `README.md`'s "Files" section (missing `wheel.lua`,
`Makefile`, `SETUP.md`, `mgba-patches/`, `sounds/`) and the drunklocke
rules table (missing the Revive counter / wheel interactions, and the
manual-hotkey-correction feature, which are documented separately further
down but not in that summary table).
**Why it matters:** not misleading, just incomplete — someone skimming
just the table/file-list would miss real features.
**Recommend:** pass over both files, fill the gaps.
**Safe now or wait:** safe now — pure documentation, zero code risk.

### 9. Multi-mon trainer battle danger-music case is verified data-wise but not play-tested end-to-end
**Where:** `party-hud.lua`'s enemy-team-defeated detection, `gen3.lua`'s
`readEnemyParty`.
**Why it matters:** confirmed live tonight that `gEnemyParty` correctly
shows both mons in a real 2-mon trainer battle (GULPIN + SMEARGLE), and the
logic change (check the whole party, not just one mon) is sound. But the
actual *end-to-end trigger* — beating GULPIN, confirming danger music
does NOT stop, then beating SMEARGLE and confirming it DOES — was never
observed live; the session moved on before that fight concluded.
**Recommend:** next time you're in a multi-mon trainer fight with the
danger music active, watch for this specifically.
**Safe now or wait:** wait — needs a live play-test, not a code change.

---

## Nice to have

### 10. `spin.wav` is a dead, unused asset
**Where:** `sounds/spin.wav`.
**Why it matters:** superseded by the tick-based ratchet sound earlier
tonight, kept deliberately "in case you want to layer it back in as
ambience." Harmless, but it's the one sound file with genuinely zero code
path pointing at it.
**Recommend:** either wire it in (e.g. low-volume loop under the ticks) or
remove it. Purely a judgment call, no urgency.
**Safe now or wait:** safe now, trivial either way.

### 11. `danger2.wav` is far bigger than it needs to be
**Where:** `sounds/danger2.wav` — 48MB (the full 4:32 Benny Hill theme).
**Why it matters:** it's a looping backdrop track; nothing about how it's
used needs more than maybe 30-60s of loop-friendly audio. This single file
is over half the entire `sounds/` directory's size, and directly feeds
into repo-bloat item #3.
**Recommend:** trim to a shorter loop-friendly segment (same `ffmpeg`
technique used on every other sound tonight — find a segment that loops
reasonably cleanly, cut to it).
**Safe now or wait:** safe now — low effort, meaningfully shrinks the
biggest single contributor to repo bloat.

### 12. Silent `pcall` failures give no diagnostic trail
**Where:** throughout `gen3.lua` — nearly every RAM read is wrapped in
`pcall(function() ... end)` with the failure path just returning nil/false,
no logging of *why*.
**Why it matters:** reasonable defensive default (a bad ROM-hack address
shouldn't crash the HUD), but when something actually breaks on a new ROM
hack or game version, there's no trail to diagnose from — just "the badge
row is empty" with no clue which read failed or why.
**Recommend:** when `DEBUG_LOG` is set, have failed `pcall`s log the
error string once (dedup like the top-level `onFrame` handler already
does with `lastError`) rather than swallowing silently.
**Safe now or wait:** safe now, but genuinely optional — only pays off the
next time something breaks on a new ROM.

### 13. Minor state-init inconsistency
**Where:** `party-hud.lua` — `prevHP`/`prevSpecies`/`prevEnemyAlive` are
declared in the initial `local state = {...}` table; other per-run fields
(`dsTid`, `dsKey`, `stage`, `stageBeaten`, etc.) only ever get set inside
`detectGame()`.
**Why it matters:** purely cosmetic — `detectGame()` runs once at load
before anything else touches `state`, so there's no actual bug. Just a
small inconsistency in where fields "live" that could confuse a future
reader trying to find where something is initialized.
**Recommend:** either move everything into the initial table (with `nil`
placeholders) or move everything into `detectGame()` — pick one pattern.
**Safe now or wait:** safe now, purely cosmetic, zero risk.

### 14. No automated tests
**Where:** the whole project.
**Why it matters:** understandable given this is fundamentally a
live-hardware/emulator-state project — most of tonight's real bugs
(revive-sound mistag, shot1.wav silence, danger-music outliving combat)
were only catchable by actual play-testing, not unit tests. Worth naming
explicitly as an accepted gap rather than an accidental one, so it doesn't
read as an oversight later.
**Recommend:** no action — just flagging it as a conscious tradeoff, not
a to-do.
**Safe now or wait:** N/A.

---

## Cleanup backlog (pick one)

| # | Item | Priority |
|---|---|---|
| 1 | Copyrighted audio in the repo — decide repo visibility | Critical |
| 2 | `kill $(cat pidfile)` has no identity check on stale/recycled PIDs | Critical |
| 3 | Binary audio bloating git history — decide before it gets worse | Critical |
| 4 | RS/FRLG unverified ROM addresses (enemyParty, badges, stages) | Medium |
| 5 | Split audio machinery out of `party-hud.lua` into `audio.lua` | Medium |
| 6 | De-duplicate the numbered-variant-scan loop | Medium |
| 7 | Namespace `/tmp/pokeparty_*` paths per-instance | Medium |
| 8 | Update `SETUP.md`/`README.md` env-var and file lists | Medium |
| 9 | Play-test multi-mon trainer battle danger-music end-to-end | Medium |
| 10 | `spin.wav` unused — wire in or remove | Nice-to-have |
| 11 | Trim `danger2.wav` down from 48MB | Nice-to-have |
| 12 | Log `pcall` failures under `DEBUG_LOG` | Nice-to-have |
| 13 | Consistent `state` field initialization pattern | Nice-to-have |
| 14 | (No action) — no automated tests, accepted tradeoff | N/A |

Tell me a number and I'll get started.
