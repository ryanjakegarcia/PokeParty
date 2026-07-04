-- audio.lua — PokéParty sound effects (drink/shot/badge/wheel cues, low-HP
-- danger music). Split out of party-hud.lua once this grew past a few
-- one-off shell calls into real start/stop/watchdog machinery.
--
-- mGBA's scripting API has no audio hooks at all (checked — console/
-- storage/image/socket/input/stdlib/canvas is the complete list of script
-- modules), but the full stdlib IS loaded (luaL_openlibs), so os.execute/
-- io.popen work same as vanilla Lua. Everything here shells out to paplay,
-- backgrounded (trailing &) so the shell returns immediately — verified
-- this returns in ~0ms, doesn't stall the frame callback.

local audio = {}
-- callers may override this (party-hud.lua points it at its own log() so
-- audio messages also land in POKEPARTY_DEBUG's log file)
audio.log = function(msg) console:log("PokéParty: " .. msg) end

-- `script` (used to build script.dir-relative paths) is only bound in the
-- entry chunk's own scope, not propagated into files loaded via nested
-- dofile() — confirmed the hard way, this module errored with "attempt to
-- index a nil value (global 'script')" on load until fixed. gen3.lua and
-- wheel.lua never hit this because neither references script.dir from
-- inside itself; party-hud.lua always resolves paths in its OWN scope
-- before calling dofile(). Same fix here: caller passes the sound
-- directory in explicitly via audio.init() instead of computing it here.
local SOUND_DIR = nil

local SOUND_ENABLED = (os.getenv("POKEPARTY_SOUND") or "1") ~= "0"
-- paplay --volume is 0-65536 (65536 = 100%). Default lowered to 55% after
-- live feedback that 80% still peaked too hot. Override with
-- POKEPARTY_SFX_VOLUME=n (0-100); live-adjustable via mouse scroll wheel
-- (see party-hud.lua's mouseWheel callback and audio.setVolumePercent
-- below) on top of whatever this starts at.
local volumePercent = math.max(0, math.min(100, tonumber(os.getenv("POKEPARTY_SFX_VOLUME") or "55")))

local function volumeUnits()
	return math.floor(65536 * volumePercent / 100)
end

function audio.getVolumePercent()
	return volumePercent
end

function audio.setVolumePercent(pct)
	volumePercent = math.max(0, math.min(100, pct))
end

-- must be called once by the caller right after dofile(), passing the
-- sound directory resolved in the CALLER's own scope (see SOUND_DIR
-- comment above for why this can't just be script.dir here).
function audio.init(soundDir)
	SOUND_DIR = soundDir
end

-- our own PID as mGBA's Lua interpreter sees it: os.execute forks a shell
-- DIRECTLY off the mgba-qt process, so that shell's $PPID at the moment of
-- spawn is mgba-qt's own PID. Used two ways below: (1) as a watchdog
-- target so the danger-music loop notices mGBA closing at all, since
-- mGBA's scripting "stop" callback maps to the GBA's hardware STOP *CPU
-- instruction*, not the application quitting — there's no script-level
-- "app is closing" hook to rely on; (2) to namespace our own temp files so
-- two concurrent mGBA+HUD instances can't collide on the same paths.
-- os.tmpname() (not a fixed filename) avoids a race between two instances
-- bootstrapping at the same moment.
local function readOwnPid()
	local tmpfile = os.tmpname()
	pcall(os.execute, string.format('echo $PPID > "%s"', tmpfile))
	local pid
	local f = io.open(tmpfile, "r")
	if f then
		pid = tonumber(f:read("*l"))
		f:close()
	end
	os.remove(tmpfile)
	return pid
end
local MGBA_PID = readOwnPid()
local DANGER_PID_FILE = string.format("/tmp/pokeparty_danger_%s.pid", tostring(MGBA_PID or "unknown"))

-- if numbered variants exist (name1.wav, name2.wav, ...) returns how many;
-- 0 means only plain name.wav (or nothing) exists. Shared by playSound and
-- startDangerMusic — used to be duplicated between them.
local function countVariants(name)
	local variants = 0
	while true do
		local f = io.open(string.format("%s/%s%d.wav", SOUND_DIR, name, variants + 1), "rb")
		if not f then break end
		f:close()
		variants = variants + 1
	end
	return variants
end

-- picks a variant at random if numbered ones exist, otherwise falls back
-- to plain name.wav. Lets an event get more takes later just by dropping
-- in more numbered files — no call-site changes needed. Cost is a few
-- io.open probes per event, only happens on actual gameplay events (not
-- per-frame), negligible.
local function pickVariant(name)
	local variants = countVariants(name)
	return variants > 0 and (name .. tostring(math.random(variants))) or name
end

function audio.playSound(name)
	if not SOUND_ENABLED then return end
	local file = pickVariant(name)
	pcall(os.execute, string.format('paplay --volume=%d "%s/%s.wav" >/dev/null 2>&1 &', volumeUnits(), SOUND_DIR, file))
end

-- low-HP danger music: needs to LOOP for as long as a mon stays critical
-- and be stoppable the moment it isn't — paplay alone is fire-and-forget
-- with no handle back to it, so this backgrounds a small shell loop instead
-- and captures its PID (via $!) to a file, which stopDangerMusic() kills.
-- ALSO runs a watchdog in the same backgrounded shell that polls once a
-- second whether mGBA (MGBA_PID) is still alive, killing the loop and any
-- in-flight paplay the moment it isn't — found live that closing mGBA
-- didn't stop the music otherwise, since nothing was watching for that at
-- all (see MGBA_PID comment above). Bounded to ~1s worst-case latency
-- instead of however long the current danger track's playthrough had left.
-- pkill -f matches against the FULL command line of every process,
-- including whatever shell is currently running the pkill call itself —
-- the pattern being searched for is always going to also be literally
-- present in the invoking `sh -c '...pkill -f PATTERN...'` command line.
-- Found this the hard way: it self-terminates the shell mid-script before
-- later cleanup commands run (a real, previously-undetected bug — earlier
-- testing only checked for leaked processes, never the leftover pidfile
-- this causes). Safe version: list matching PIDs via pgrep, explicitly
-- skip our own ($$), kill the rest.
local function killMatchingExceptSelf(pattern)
	return string.format(
		'for p in $(pgrep -f "%s" 2>/dev/null); do [ "$p" != "$$" ] && kill "$p" 2>/dev/null; done',
		pattern)
end

local dangerPlaying = false
function audio.startDangerMusic()
	if not SOUND_ENABLED or dangerPlaying then return end
	dangerPlaying = true
	-- pick one danger track at random for this whole critical spell
	local track = pickVariant("danger")
	-- volume is baked into this shell script string at loop-start time —
	-- scrolling to adjust volume WHILE a danger loop is already running
	-- won't retroactively affect it (the loop just keeps re-running paplay
	-- with whatever value it started with), only the NEXT critical spell
	-- picks up a changed volume. Fixing that would need the loop to
	-- re-read a live value each iteration (e.g. from a file) — more
	-- complexity than justified today.
	local watchdog = MGBA_PID and string.format(
		'; (while kill -0 %d 2>/dev/null; do sleep 1; done; kill "$LOOPPID" 2>/dev/null; %s) &',
		MGBA_PID, killMatchingExceptSelf(string.format("%s/%s.wav", SOUND_DIR, track))) or ''
	pcall(os.execute, string.format(
		'sh -c \'while true; do paplay --volume=%d "%s/%s.wav" >/dev/null 2>&1; done & LOOPPID=$!; echo $LOOPPID > "%s"%s\' >/dev/null 2>&1 &',
		volumeUnits(), SOUND_DIR, track, DANGER_PID_FILE, watchdog))
end

function audio.stopDangerMusic()
	if not dangerPlaying then return end
	dangerPlaying = false
	-- kill the spawner loop (stops FUTURE plays) AND the currently-playing
	-- paplay child directly (danger tracks run tens of seconds to minutes —
	-- without this, whatever instance is already mid-playback when the
	-- danger clears would keep audibly running long after the loop itself
	-- is dead). Matches on SOUND_DIR/danger (prefix, catches whichever
	-- numbered track this spell happened to pick) via killMatchingExceptSelf
	-- (see its comment — plain `pkill -f` here would self-terminate this
	-- very shell before reaching `rm -f` below, which is exactly what
	-- happened when first tested against a real leftover pidfile).
	--
	-- The PID-file kill is identity-checked first: if mGBA (or this whole
	-- machine) sat idle long enough between a crash and the next launch,
	-- /proc PIDs can get recycled by an unrelated process. Checking that
	-- the PID's own cmdline actually contains "paplay" before signaling it
	-- avoids ever killing a stranger process that happened to inherit a
	-- stale PID number.
	pcall(os.execute, string.format(
		'PID=$(cat "%s" 2>/dev/null); ' ..
		'if [ -n "$PID" ] && grep -qa "paplay" "/proc/$PID/cmdline" 2>/dev/null; then kill "$PID" 2>/dev/null; fi; ' ..
		'%s; rm -f "%s"',
		DANGER_PID_FILE, killMatchingExceptSelf(SOUND_DIR .. "/danger"), DANGER_PID_FILE))
end

return audio
