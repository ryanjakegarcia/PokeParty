-- party-hud.lua — PokéParty HUD for mGBA (requires mGBA 0.11+ scripting canvas API)
-- Launch: mgba-qt --script /path/to/party-hud.lua yourgame.gba
--
-- Docks a live party panel beside the game screen, plus full-width top/
-- bottom strips: nickname, level, HP bar, status, badges, level cap (next
-- boss's highest-level mon, read from the ROM), and a persistent faint
-- counter.
--
-- Scripting API lifetime rules (learned the hard way):
--  * method return values (canvas:newLayer, image.newPainter) are strong refs
--  * member accesses (layer.image) are weakrefs that die at the NEXT API
--    call — never store them in a local across calls, always access inline

local gen3 = dofile(script.dir .. "/gen3.lua")
local wheel = dofile(script.dir .. "/wheel.lua")

local FONT_PATH = "/usr/share/fonts/truetype/dejavu/DejaVuSansCondensed.ttf"
local DEBUG_LOG = os.getenv("POKEPARTY_DEBUG") -- set to a dir path to enable

-- cheats: pressing the hotkey tops the items pocket up to this many Rare
-- Candies (0 = disable). Override with POKEPARTY_CANDY=n.
local CHEAT_RARE_CANDIES = tonumber(os.getenv("POKEPARTY_CANDY") or "99")
-- keyboard hotkey (single character; Qt reports letters as uppercase)
local CANDY_KEY = (os.getenv("POKEPARTY_CANDY_KEY") or "c"):upper():byte()
-- gamepad button number; find yours by pressing buttons with POKEPARTY_DEBUG
-- set and reading the log, then export POKEPARTY_CANDY_PAD=<number>
local CANDY_PAD = tonumber(os.getenv("POKEPARTY_CANDY_PAD") or "")

-- drunklocke hotkeys (uppercase codepoints, see key handler)
local KEY_RIVAL = ("r"):upper():byte()     -- rival beaten = 1 shot (manual)
local KEY_IMPORTANT = ("i"):upper():byte() -- toggle lead mon "important"
local KEY_WHEEL = ("w"):upper():byte()     -- spin the wheel manually

-- manual counter correction, for bugs or new house-rules mid-run: left key
-- of each pair = -1, right key = +1. Punctuation row, doesn't collide with
-- anything above and reads consistently left=down/right=up.
local KEY_DRINK_DOWN  = ("["):byte()
local KEY_DRINK_UP    = ("]"):byte()
local KEY_SHOT_DOWN   = (";"):byte()
local KEY_SHOT_UP     = ("'"):byte()
local KEY_REVIVE_DOWN = (","):byte()
local KEY_REVIVE_UP   = ("."):byte()

local function log(msg)
	console:log("PokéParty: " .. msg)
	if DEBUG_LOG then
		local f = io.open(DEBUG_LOG .. "/pokeparty.log", "a")
		if f then
			f:write(os.date("%H:%M:%S "), msg, "\n")
			f:close()
		end
	end
end
wheel.log = log -- route wheel.lua's own log lines through the same file

-- Canvas coordinates are GBA screen pixels (240x160); the canvas grows to
-- fit layers, and mGBA scales the whole canvas to the window. The side
-- panel docks at 130x160 logical units right of the game; top/bottom strips
-- span the full combined width (game + panel) and sit OUTSIDE the game's
-- 0..160 vertical range (negative y above, >160 below) — mGBA's canvas
-- bounding box is just the union of every layer's position, so this is the
-- same technique as the side panel, just vertical. Backing images are
-- HUD_SCALE× larger (our patched newLayer upscale arg) for hi-res text.
-- NOTE (OpenGL display): overlays composite through an FBO sized
-- frame×videoScale, so set Settings→Enhancements→High-resolution scale to
-- HUD_SCALE as well or the extra pixels get averaged away.
local PANEL_W = 130
local PANEL_H = 160
local HUD_SCALE = math.max(1, math.min(8, tonumber(os.getenv("POKEPARTY_HUD_SCALE") or "4")))
local S = HUD_SCALE

-- top/bottom strip height in logical px, 0 disables them. Default 24
-- eliminates letterboxing exactly at 1080p fullscreen (canvas becomes
-- 370x208, matching 1920x1080's 16:9 aspect) — the common case for TV/
-- projector setups. Tune per-machine with POKEPARTY_STRIP_H if your
-- display's aspect differs (e.g. 16:10 laptops want ~35).
local STRIP_H = math.max(0, tonumber(os.getenv("POKEPARTY_STRIP_H") or "24"))
local STRIP_W = 240 + PANEL_W -- full combined width (game + side panel)

-- how long a flash/event banner holds before fading, in real (wall-clock)
-- seconds — deliberately NOT emulated frames, which run 2-4x faster than
-- real time under fast-forward and would make popups blip past too quick
-- for anyone to read. Uses os.time(), NOT os.clock(): os.clock() measures
-- CPU time (time actually spent executing), which runs slower than real
-- time whenever the process idles between frames — made popups hang around
-- LONGER than intended, the opposite bug. os.time() has only whole-second
-- resolution but is genuine wall-clock, correct regardless of CPU load or
-- emulation speed. Longer than a quick solo-play glance needs — this is
-- read by a room full of people over HDMI, not just the player at the
-- keyboard.
local FLASH_HOLD_SECONDS = 5

-- alignment constants (mgba-util/image.h)
local TL = 0x11 -- top|left
local TR = 0x13 -- top|right
local TC = 0x12 -- top|center
local VL = 0x21 -- vcenter|left
local VC = 0x22 -- vcenter|center
local VR = 0x23 -- vcenter|right

local C = {
	bg       = 0xFF14181D,
	rowbg    = 0x22FFFFFF,
	line     = 0x30FFFFFF,
	text     = 0xFFECEFF4,
	dim      = 0xFF97A3B0,
	accent   = 0xFFF5C542,
	hpGreen  = 0xFF41C463,
	hpYellow = 0xFFF5C542,
	hpRed    = 0xFFE5484D,
	hpBack   = 0xFF2A3138,
	badgeOn  = 0xFFF5C542,
	badgeOff = 0xFF3A424B,
	catchBg  = 0xFFF08030,
	warnBg   = 0xFFC03028,
}

local TYPE_COLORS = {
	[0]=0xFFA8A878,0xFFC03028,0xFFA890F0,0xFFA040A0,0xFFE0C068,0xFFB8A038,
	0xFFA8B820,0xFF705898,0xFFB8B8D0,0xFF68A090,0xFFF08030,0xFF6890F0,
	0xFF78C850,0xFFF8D030,0xFFF85888,0xFF98D8D8,0xFF7038F8,0xFF705848,
}

-- badge color mode: "color" = stylized per-badge-type hue (not screen-
-- accurate — Gen3 only ever renders every badge in plain silver, see
-- gen3.badgeIconImage — but far easier to tell apart at a glance); "silver"
-- = the real in-game monochrome medal look. Override with
-- POKEPARTY_BADGE_COLORS=silver.
local BADGE_COLOR_MODE = (os.getenv("POKEPARTY_BADGE_COLORS") or "color"):lower()

-- BPRE (Kanto: Boulder/Cascade/Thunder/Rainbow/Soul/Marsh/Volcano/Earth)
-- sampled directly from the user's reference art (Downloads/hoenn2.png,
-- despite the filename — it's actually Kanto). Order matches gym progression.
local BADGE_HUES = {
	BPRE = { -- Boulder(gray/tan, not gold - corrected per user), Cascade, Thunder, Rainbow, Soul, Marsh, Volcano, Earth
		0xFFB8AE8C, 0xFF4A7FA8, 0xFFD4AF37, 0xFFF0603A,
		0xFF7A7B7E, 0xFF4F9195, 0xFFEC4066, 0xFF7FC6ED,
	},
}
BADGE_HUES.BPGE = BADGE_HUES.BPRE
-- Hoenn: Stone/Knuckle/Dynamo/Heat/Balance/Feather/Mind/Rain — sampled
-- directly from Bulbapedia's badge reference chart (user screenshot).
BADGE_HUES.BPEE = {
	0xFFCBC7AD, 0xFFFFAC59, 0xFFFCD659, 0xFFEF7374,
	0xFFC1C2C1, 0xFFADD2F5, 0xFFF584A8, 0xFF74ACF5,
}
BADGE_HUES.AXVE = BADGE_HUES.BPEE
BADGE_HUES.AXPE = BADGE_HUES.BPEE

-- earned badges show the hue at full strength; not-yet-earned render
-- blacked-out (not just dimmed) so obtaining one reads as a clear reveal
local function dimColor(hex, factor)
	local r = math.floor(((hex >> 16) & 0xFF) * factor)
	local g = math.floor(((hex >> 8) & 0xFF) * factor)
	local b = math.floor((hex & 0xFF) * factor)
	return 0xFF000000 | (r << 16) | (g << 8) | b
end

local COND_COLORS = {
	FNT = 0xFFE5484D, SLP = 0xFF8A93A0, PSN = 0xFFA040A0, TOX = 0xFF7C2E8C,
	BRN = 0xFFF08030, FRZ = 0xFF6BC7E0, PAR = 0xFFF5C542,
}

local state = {
	game = nil,       -- detected game info, nil = none/unsupported
	scanned = false,  -- ROM tables located
	layer = nil,      -- canvas layer (strong ref, safe to cache)
	topLayer = nil,
	bottomLayer = nil,
	frame = 0,
	party = {},
	stats = nil,
	prevHP = {},      -- "personality_otId" -> hp
	prevSpecies = {}, -- "personality_otId" -> species, for evolution detection
	lastSig = nil,    -- redraw only when content changes
}

local bucket = storage:getBucket("PokePartymGBA")

-- ------------------------------------------------------------------------
-- persistent run state (drinks/shots/cap/catch/faints/important marks)
-- ------------------------------------------------------------------------
-- All save-progress tracking lives in ONE table (state.ds) committed to
-- disk ONLY when the game itself writes a real save (the "savedataUpdated"
-- callback — Gen3 only touches flash/SRAM when the player actually saves,
-- famously NOT for things like PC deposits). Between real saves, state.ds
-- updates in memory instantly (HUD stays responsive) but isn't written to
-- disk. If the game's own progress (caught/trainers/badges) is ever seen to
-- REGRESS — reload without saving, in-game soft reset, or an mGBA
-- savestate load — the whole table rolls back to state.dsCommitted, the
-- last values that made it to a real save. This intentionally treats
-- drinks/shots/cap/catch/faints/marks as one atomic unit: none of them can
-- be independently "more saved" than the others.
--
-- ROM-identity caches (species/stats/icon tables, boss levels, SaveBlock
-- pointer relocation — all in gen3.lua, keyed by ROM checksum) are a
-- different category: facts about the ROM file, not about save progress,
-- correctly unaffected by any of this and shared across every save on that
-- ROM.

-- flat, storage-safe snapshot of the fields that matter (no nested tables —
-- mGBA's storage returns saved tables as userdata wrappers that support
-- direct field access but not reliable iteration, so `important` is kept
-- as a comma-joined string, not a nested set)
local function cloneDS(ds)
	return {
		drinks = ds.drinks, shots = ds.shots,
		levelCapDelta = ds.levelCapDelta, extraCatch = ds.extraCatch,
		caught = ds.caught, trainers = ds.trainers, badges = ds.badges,
		faints = ds.faints, revives = ds.revives, important = ds.important,
	}
end

local function parseImportant(str)
	local set = {}
	if type(str) == "string" then
		for k in str:gmatch("[^,]+") do set[k] = true end
	end
	return set
end

local function stringifyImportant(set)
	local keys = {}
	for k in pairs(set) do keys[#keys + 1] = k end
	return table.concat(keys, ",")
end

-- writes state.ds to disk if anything changed since the last commit;
-- called only from the savedataUpdated callback (real in-game saves)
local function commitDS()
	if not state.dsDirty or not state.dsKey or not state.ds then return end
	bucket[state.dsKey] = state.ds
	state.dsCommitted = cloneDS(state.ds)
	state.dsDirty = false
	log(string.format("counters committed: D:%d S:%d cap+%d catch+%d FNT:%d REV:%d",
		state.ds.drinks, state.ds.shots, state.ds.levelCapDelta,
		state.ds.extraCatch, state.ds.faints, state.ds.revives))
end

-- loads the unified per-save blob, migrating the old three-key scheme
-- (ds2_/faints_/imp_) once if present. Returns loaded, key, isFresh.
local function loadOrMigrateDS(game, tid)
	local newKey = "state2_" .. game.code .. "_" .. tid
	local found = nil
	pcall(function()
		local v = bucket[newKey]
		if v and v.drinks ~= nil then
			found = {
				drinks = v.drinks, shots = v.shots or 0,
				levelCapDelta = v.levelCapDelta or 0, extraCatch = v.extraCatch or 0,
				caught = v.caught or 0, trainers = v.trainers or 0, badges = v.badges or 0,
				faints = v.faints or 0, revives = v.revives or 0,
				important = v.important or "",
			}
		end
	end)
	if found then return found, newKey, false end

	local migrated = nil
	pcall(function()
		local v = bucket["ds2_" .. game.code .. "_" .. tid]
		if v and v.drinks ~= nil then
			migrated = {
				drinks = v.drinks, shots = v.shots or 0,
				levelCapDelta = v.levelCapDelta or 0, extraCatch = v.extraCatch or 0,
				caught = v.caught or 0, trainers = v.trainers or 0, badges = v.badges or 0,
				faints = tonumber(bucket["faints_" .. game.code .. "_" .. tid]) or 0,
				revives = 0, important = "",
			}
			local iv = bucket["imp_" .. game.code .. "_" .. tid]
			if type(iv) == "string" then migrated.important = iv end
		end
	end)
	if migrated then
		log("migrated legacy counters to unified save format")
		bucket[newKey] = migrated -- one-time: re-encoding already-saved data, not a phantom event
		return migrated, newKey, false
	end

	return nil, newKey, true
end

-- ------------------------------------------------------------------------
-- data refresh
-- ------------------------------------------------------------------------
local function detectGame()
	state.game = gen3.detect()
	state.scanned = false
	state.party = {}
	state.stats = nil
	state.prevHP = {}
	state.prevSpecies = {}
	state.pendingEvoCredits = 0
	state.rawStable = nil -- {tid,caught,trainers,badges}, for the 2-tick stability gate
	state.lastSig = nil
	state.ptrScanTick = nil
	state.flash = nil
	state.icons = {}      -- species -> icon image (strong refs, cacheable)
	state.iconsReady = false
	state.iconsTried = false
	state.badgeIcons = {} -- badge index -> mask image (strong refs, cacheable)
	state.badgesReady = false
	state.badgesTried = false
	state.ds = nil          -- {drinks, shots, levelCapDelta, extraCatch, caught, trainers, badges, faints, important}
	state.dsCommitted = nil -- last values written to disk; rollback target
	state.dsDirty = false
	state.dsWasRegressed = false
	state.dsKey = nil
	state.dsTid = nil
	state.importantSet = nil -- parsed from state.ds.important, "personality_otId" -> true
	state.stage = nil      -- current gen3.currentStage() result
	state.stageBeaten = -1 -- trainer-beaten count last time stage was resolved
	if state.game then
		log("detected " .. state.game.name .. " (" .. state.game.code .. ")")
	else
		log("no supported Gen 3 game detected")
	end
end

local function flash(msg)
	state.flash = { text = msg, expiresAt = os.time() + FLASH_HOLD_SECONDS }
	state.lastSig = nil -- force redraw
end

local function toggleImportant()
	local mon = state.party[1]
	if not mon or not state.importantSet or not state.ds then return end
	local key = mon.personality .. "_" .. mon.otId
	local name = mon.nickname ~= "" and mon.nickname or mon.speciesName
	if state.importantSet[key] then
		state.importantSet[key] = nil
		flash(name .. " unmarked")
	else
		state.importantSet[key] = true
		flash("★ " .. name .. " IS IMPORTANT")
	end
	state.ds.important = stringifyImportant(state.importantSet)
	state.dsDirty = true
end

local function trackFaints()
	local seen = {}
	for _, mon in ipairs(state.party) do
		local key = mon.personality .. "_" .. mon.otId
		seen[key] = true
		local prev = state.prevHP[key]
		if prev and prev > 0 and mon.hp == 0 and state.ds then
			state.ds.faints = state.ds.faints + 1
			if state.importantSet and state.importantSet[key] then
				state.ds.shots = state.ds.shots + 2
				flash("IMPORTANT FAINT! 2 SHOTS!")
			else
				state.ds.shots = state.ds.shots + 1
				flash("FAINT! TAKE A SHOT!")
			end
			state.dsDirty = true
		end
		state.prevHP[key] = mon.hp
	end
	for key in pairs(state.prevHP) do
		if not seen[key] then state.prevHP[key] = nil end
	end
end

-- Gen3 marks a species "owned" in the Pokédex on EVOLUTION too, not just on
-- catching one — the dex-owned popcount we use to detect catches can't
-- natively tell the two apart (this isn't a bug in our reading: the games'
-- own Trainer Card "caught" stat is computed the exact same way and has
-- the identical quirk). Evolution keeps the same individual (personality+
-- otId unchanged, only species changes); a real catch always introduces a
-- personality+otId never seen before. Counting species changes on already-
-- known party members each tick lets the catch-diff below subtract out
-- exactly the dex-bump evolution caused, leaving only real catches.
local function countEvolutions()
	local n = 0
	local seen = {}
	for _, mon in ipairs(state.party) do
		local key = mon.personality .. "_" .. mon.otId
		seen[key] = true
		local prevSpecies = state.prevSpecies[key]
		if prevSpecies and prevSpecies ~= mon.species then
			n = n + 1
		end
		state.prevSpecies[key] = mon.species
	end
	for key in pairs(state.prevSpecies) do
		if not seen[key] then state.prevSpecies[key] = nil end
	end
	return n
end

local function refresh()
	local game = state.game
	if not game then return end
	if not state.scanned then
		state.scanned = gen3.locateTables(game, bucket)
		if state.scanned then
			log(string.format("ROM tables — names @%08X stats @%s",
				game.namesTable, game.statsTable and string.format("%08X", game.statsTable) or "n/a"))
		end
	end
	if not state.iconsReady and not state.iconsTried then
		state.iconsTried = true -- full-ROM scan; attempt only once per game
		state.iconsReady = gen3.locateIconTables(game, bucket)
		if state.iconsReady then
			log(string.format("icon table @%08X (%d entries)", game.iconTable, game.iconCount))
		else
			log("icon table not found — sprites disabled")
		end
	end
	if not state.badgesReady and not state.badgesTried then
		state.badgesTried = true
		state.badgesReady = gen3.locateBadgeIcons(game)
		log(state.badgesReady and "badge graphics decoded"
			or "badge graphics not found — falling back to plain squares")
	end
	state.party = gen3.readParty(game)
	-- must run every refresh (not gated behind saveReady) so prevSpecies
	-- stays in sync and the first tick after a save loads doesn't get
	-- misread as a pile of simultaneous "evolutions"
	-- accumulate into a persistent pool rather than consuming same-tick:
	-- the species field can change (detected here) on an earlier tick than
	-- the dex-owned/caught counter actually reflects it (evolution
	-- animation spans several ticks before the Pokédex registration
	-- settles), so a same-tick "evolutions - n" subtraction can miss and
	-- wrongly count the evolution as a real catch (observed live: evolving
	-- Ivysaur both flashed CAUGHT! and consumed an x2-catch charge)
	state.pendingEvoCredits = (state.pendingEvoCredits or 0) + countEvolutions()
	state.stats = gen3.readTrainerStats(game)
	-- rebuilt hacks move the SaveBlock pointers: party reads fine but stats
	-- don't. Locate the pointers by matching the party's OT id in IWRAM.
	if not state.stats and #state.party > 0 then
		state.ptrScanTick = (state.ptrScanTick or 0) + 1
		if state.ptrScanTick % 6 == 1 and gen3.findSavePtrs(game, state.party, bucket) then
			log(string.format("save pointers relocated — sb1ptr @%08X", game.sb1))
			state.stats = gen3.readTrainerStats(game)
		end
	end
	-- During boot/intro the save block is zeroed (tid 0, all counters 0);
	-- initializing or diffing against that phantom state fires bogus events
	-- when the real save loads. Only track once a real save (tid != 0) is up.
	--
	-- FireRed/LeafGreen additionally play a "recap" narration right after
	-- Continue, which transiently misreads caught/trainers/badges (some
	-- scratch buffer or repointing happening to generate the narration
	-- text, before settling on the real save) — observed live: baseline
	-- correctly set at D:10, then jumped to D:14 with zero real gameplay
	-- during the recap. Guard against ANY such transient blip generically:
	-- don't trust a stats snapshot for baselining or diffing until the
	-- exact same values have been read on two consecutive ticks. Costs one
	-- tick (~0.3s) of latency on a genuine change; filters single-tick
	-- blips entirely regardless of what causes them.
	local statsStable = false
	if state.stats then
		local r = state.rawStable
		if r and r.tid == state.stats.tid and r.caught == state.stats.caught
			and r.trainers == state.stats.trainers and r.badges == state.stats.badges then
			statsStable = true
		else
			state.rawStable = {
				tid = state.stats.tid, caught = state.stats.caught,
				trainers = state.stats.trainers, badges = state.stats.badges,
			}
		end
	end
	-- re-key everything if the user switches saves mid-session
	local saveReady = state.stats and state.stats.tid ~= 0 and statsStable
	if saveReady and state.dsTid ~= state.stats.tid then
		state.dsTid = state.stats.tid
		local loaded, key, isFresh = loadOrMigrateDS(game, state.stats.tid)
		state.dsKey = key
		if loaded then
			state.ds = loaded
		else
			-- baseline current progress so history doesn't count as new events
			state.ds = {
				drinks = 0, shots = 0, levelCapDelta = 0, extraCatch = 0,
				caught = state.stats.caught, trainers = state.stats.trainers,
				badges = state.stats.badges, faints = 0, revives = 0, important = "",
			}
		end
		state.importantSet = parseImportant(state.ds.important)
		state.dsCommitted = cloneDS(state.ds)
		state.dsDirty = false
		state.dsWasRegressed = false
		log(string.format("counters ready: D:%d S:%d cap+%d catch+%d FNT:%d REV:%d",
			state.ds.drinks, state.ds.shots, state.ds.levelCapDelta,
			state.ds.extraCatch, state.ds.faints, state.ds.revives))
	end
	-- event detection by diffing save counters
	if saveReady and state.ds then
		local ds = state.ds
		local regressed = state.stats.caught < ds.caught
			or state.stats.trainers < ds.trainers
			or state.stats.badges < ds.badges
		if regressed then
			-- game state rewound (reload without saving, soft reset, or a
			-- savestate load): discard anything not yet committed to a real
			-- save and restore the last point that was
			state.ds = cloneDS(state.dsCommitted)
			-- the committed snapshot itself can still be stale — e.g. it was
			-- captured moments before an earlier unsaved-reload, or migrated
			-- from pre-fix data that was already desynced (this happened:
			-- migrated caught=8 but the live save is genuinely at caught=6).
			-- Never let a tracking baseline sit above what's true right now,
			-- or "regressed" would stay true forever with nothing to fix it.
			local ds2 = state.ds
			if state.stats.caught < ds2.caught then ds2.caught = state.stats.caught; state.dsDirty = true end
			if state.stats.trainers < ds2.trainers then ds2.trainers = state.stats.trainers; state.dsDirty = true end
			if state.stats.badges < ds2.badges then ds2.badges = state.stats.badges; state.dsDirty = true end
			state.importantSet = parseImportant(state.ds.important)
			if not state.dsWasRegressed then
				flash("RUN REWOUND — RESTORED LAST SAVE")
				log("stat regression detected, rolled back to last committed counters")
			end
			state.dsWasRegressed = true
		else
			state.dsWasRegressed = false
			if state.stats.caught > ds.caught then
				local n = state.stats.caught - ds.caught
				ds.caught = state.stats.caught
				-- baseline moved even if it turns out to be pure evolution
				-- (below) — mark dirty now so it still reaches disk on the
				-- next real save, instead of silently drifting from the
				-- committed snapshot until some other event happens to
				-- trigger a commit
				state.dsDirty = true
				-- evolution also marks the evolved species "owned" — subtract
				-- out however many of this tick's dex-owned bumps came from
				-- evolutions, not real catches. Drawn from the accumulated
				-- pool (see above), not a same-tick count.
				local evoCredit = math.min(n, state.pendingEvoCredits or 0)
				state.pendingEvoCredits = (state.pendingEvoCredits or 0) - evoCredit
				local realCatches = math.max(0, n - evoCredit)
				if realCatches > 0 then
					ds.drinks = ds.drinks + realCatches
					-- x2 catch: bonus is consumed by the very next catch(es)
					-- after it was granted, regardless of which route it
					-- happens on (no reliable way to bind it to a specific
					-- route from save data — self-enforced by the player,
					-- same as the base 1-per-route rule)
					if ds.extraCatch > 0 then
						local used = math.min(realCatches, ds.extraCatch)
						ds.extraCatch = ds.extraCatch - used
						flash("CAUGHT! DRINK! (x2 catch used)")
					else
						flash("CAUGHT! DRINK!")
					end
				end
			end
			if state.stats.trainers > ds.trainers then
				local n = state.stats.trainers - ds.trainers
				ds.trainers = state.stats.trainers
				-- "Beat Gym/E4 = 1 Shot" REPLACES the generic "Beat a
				-- Trainer = Drink" for that specific fight, it doesn't stack
				-- with it — a gym/E4 boss is also a regular trainer (their
				-- flag is part of this same trainers-beaten count), so
				-- exclude exactly one of this tick's newly-beaten trainers
				-- from the drink count when the currently-tracked stage
				-- (state.stage — still the PRE-defeat value here; its own
				-- recompute runs later below) is a gym/E4 stage and is now
				-- confirmed beaten. Any OTHER trainers beaten in the same
				-- tick still count normally.
				local stageKey = state.stage and state.stage.key
				local isBoss = stageKey and (stageKey:match("^gym") or stageKey:match("^e4"))
					and gen3.isTrainerBeaten(game, state.stage.id)
				local drinkCount = isBoss and (n - 1) or n
				if drinkCount > 0 then
					ds.drinks = ds.drinks + drinkCount
					flash("TRAINER DOWN! DRINK!")
				end
				-- gym leaders get their shot from the badges-diff check
				-- below (badges only increment for gyms) — E4 members grant
				-- no badge, so their shot has to be added right here
				if isBoss and stageKey:match("^e4") then
					ds.shots = ds.shots + 1
					flash("ELITE FOUR MEMBER DOWN! SHOT!")
				end
				state.dsDirty = true
			end
			if state.stats.badges > ds.badges then
				local n = state.stats.badges - ds.badges
				ds.shots = ds.shots + n
				ds.badges = state.stats.badges
				flash("GYM BEATEN! SHOT + WHEEL!")
				state.dsDirty = true
				wheel.spin()
			end
		end
	end
	trackFaints()
	-- level cap: re-resolve the current stage only when trainer-beaten
	-- progress has moved (each resolution can cost a full-ROM name scan
	-- the first time; gen3 caches it, but avoid re-checking 13 flags+scan
	-- every refresh tick regardless)
	if saveReady and state.stats.trainers ~= state.stageBeaten then
		state.stageBeaten = state.stats.trainers
		state.stage = gen3.currentStage(game, bucket)
		if state.stage then
			log(string.format("next stage: %s max L%d", state.stage.label, state.stage.maxLevel))
		else
			log("all stages cleared")
		end
	end
end

-- ------------------------------------------------------------------------
-- drawing
-- ------------------------------------------------------------------------
-- helpers take logical (GBA-pixel) coordinates and scale to the hi-res
-- backing image
local function rect(p, x, y, w, h, color)
	p:setFill(true)
	p:setFillColor(color)
	p:setStrokeWidth(0)
	p:drawRectangle(x * S, y * S, w * S, h * S)
end

local function text(p, str, x, y, size, color, align)
	p:setFontSize(size * S)
	p:setFill(true)
	p:setFillColor(color)
	p:setStrokeWidth(0)
	p:drawText(str, x * S, y * S, align or TL)
end

-- outlined text for drawing on top of colored fills (HP bar numbers)
local function barText(p, str, x, y, size, color, align)
	p:setFontSize(size * S)
	p:setFill(true)
	p:setFillColor(color)
	p:setStrokeWidth(math.max(1, S - 1))
	p:setStrokeColor(0xE0101418)
	p:drawText(str, x * S, y * S, align)
	p:setStrokeWidth(0)
end

local function hpColor(hp, maxHP)
	if maxHP == 0 then return C.hpBack end
	local r = hp / maxHP
	if r > 0.5 then return C.hpGreen end
	if r > 0.2 then return C.hpYellow end
	return C.hpRed
end

-- draws a badge/icon mask tinted with `color` (drawMask multiplies the
-- painter's fill color against the mask's alpha, so the mask itself is
-- just solid-white ink on transparent — see gen3.badgeIconImage)
local function mask(p, img, x, y, color)
	p:setFill(true)
	p:setFillColor(color)
	p:drawMask(img, x * S, y * S)
end

-- cached badge icon mask (image objects are method returns → strong)
local function getBadgeIcon(index, px)
	if not state.badgesReady then return nil end
	local icon = state.badgeIcons[index]
	if icon == nil then
		icon = gen3.badgeIconImage(state.game, index, px * S) or false
		state.badgeIcons[index] = icon
	end
	return icon or nil
end

-- cached 16x16 icon for a mon (image objects are method returns → strong)
local function getIcon(mon)
	if not state.iconsReady then return nil end
	local species = mon.isEgg and gen3.SPECIES_EGG or mon.species
	local icon = state.icons[species]
	if icon == nil then
		icon = gen3.monIconImage(state.game, species, 16 * S) or false
		state.icons[species] = icon
	end
	return icon or nil
end

-- one party row: 20px tall
local function drawMonRow(p, x, y, w, mon)
	rect(p, x, y, w, 19, C.rowbg)
	local stripe = mon.type1 and TYPE_COLORS[mon.type1] or C.badgeOff
	rect(p, x, y, 2, 19, stripe)

	local textX = x + 5
	local icon = getIcon(mon)
	if icon then
		-- member access chained immediately into the draw call (weakref rule)
		state.layer.image:drawImage(icon, (x + 4) * S, (y + 1) * S)
		textX = x + 22
	end

	local name = mon.nickname ~= "" and mon.nickname or mon.speciesName
	local impKey = mon.personality .. "_" .. mon.otId
	if state.importantSet and state.importantSet[impKey] then
		name = "★" .. name
	end

	-- hard ceiling on name length; utf8.offset keeps the multibyte ★ intact
	local charCount = utf8.len(name) or #name
	if charCount > 11 then
		local byteOffset = utf8.offset(name, 10)
		if byteOffset then
			name = string.sub(name, 1, byteOffset - 1) .. ".."
		else
			name = string.sub(name, 1, 9) .. ".."
		end
	end
	text(p, name, textX, y + 1, 7, C.text)

	-- level flows after the name (right column belongs to HP/status; text
	-- at size 8 descends past y+9, so stacking there overlaps). Measure the
	-- real rendered width — the font is proportional, estimates collide.
	-- textBoxSize returns FreeType 26.6 fixed-point: pixels × 64.
	local box = p:textBoxSize(name)
	local levelX = textX + box.width // (64 * S) + 4
	text(p, "L" .. mon.level, levelX, y + 1, 7, C.accent)


	-- fat HP bar spanning the row, with the numbers embedded in it:
	-- outlined text stays readable over both the fill and the trough,
	-- and 3-digit HP never collides with anything
	local barX = textX
	local barW = w - (textX - x) - 3
	local barY, barH = y + 11, 7
	rect(p, barX, barY, barW, barH, C.hpBack)
	if mon.maxHP > 0 and mon.hp > 0 then
		local fill = math.max(1, math.floor(barW * mon.hp / mon.maxHP))
		rect(p, barX, barY, fill, barH, hpColor(mon.hp, mon.maxHP))
	end
	local midY = barY + barH // 2
	barText(p, mon.hp .. "/" .. mon.maxHP, barX + barW // 2, midY, 6, 0xFFFFFFFF, VC)
	if mon.cond then
		barText(p, mon.cond, barX + barW - 2, midY, 6, COND_COLORS[mon.cond] or C.dim, VR)
	end
end

-- top strip: full-width event banner. Blank except for the ~4.5s window
-- after something notable happens — kept simple and unmissable for a room
-- of spectators, not crowded with anything ambient.
local function drawTopStrip()
	if not state.topLayer then return end
	local p = image.newPainter(state.topLayer.image)
	p:loadFont(FONT_PATH)
	p:setBlend(false)
	local active = state.flash and state.flash.expiresAt > os.time()
	local bg = C.bg
	if active then
		bg = state.dsWasRegressed and C.warnBg or C.accent
	end
	rect(p, 0, 0, STRIP_W, STRIP_H, bg)
	p:setBlend(true)
	if active then
		local fg = state.dsWasRegressed and 0xFFECEFF4 or 0xFF10141D
		text(p, state.flash.text, STRIP_W // 2, STRIP_H // 2, 13, fg, VC)
	elseif state.game then
		text(p, state.game.name:upper(), STRIP_W // 2, STRIP_H // 2, 13, C.text, VC)
		if state.stats then
			text(p, string.format("ID %05d", state.stats.tid), STRIP_W - 10, STRIP_H // 2, 11, C.dim, VR)
		end
	end
	state.topLayer:update()
	canvas:update()
	if DEBUG_LOG then state.topLayer.image:save(DEBUG_LOG .. "/strip_top.png", "PNG") end
end

-- bottom strip: full-width always-on status bar (cap/drinks/shots/faints),
-- with the x2-catch badge appended when active. Replaces the cramped
-- single row that used to live in the side panel header.
local function drawBottomStrip()
	if not state.bottomLayer then return end
	local p = image.newPainter(state.bottomLayer.image)
	p:loadFont(FONT_PATH)
	p:setBlend(false)
	rect(p, 0, 0, STRIP_W, STRIP_H, C.bg)
	p:setBlend(true)
	if not state.stats then
		text(p, "Waiting for save…", STRIP_W // 2, STRIP_H // 2, 10, C.dim, VC)
		state.bottomLayer:update()
		canvas:update()
		return
	end
	local midY = STRIP_H // 2

	-- left and right zones are drawn first and MEASURED (textBoxSize is
	-- FreeType 26.6 fixed-point: px × 64, see mgba-lua-api-gotchas), so the
	-- center zone can be constrained to whatever gap is actually left
	-- between them — fixed pixel anchors overlapped once the right zone's
	-- content grew (x2-catch suffix pushed its left edge into the center
	-- text's territory)
	local capText = "CAP --"
	if state.stage then
		local delta = (state.ds and state.ds.levelCapDelta) or 0
		capText = string.format("CAP %d %s", state.stage.maxLevel + delta, state.stage.label)
	end
	text(p, capText, 10, midY, 11, C.dim, VL)
	p:setFontSize(11 * S)
	local leftEdge = 10 + p:textBoxSize(capText).width // (64 * S)

	local rightText = "FNT " .. ((state.ds and state.ds.faints) or 0)
	if state.ds and state.ds.extraCatch > 0 then
		rightText = rightText .. "   ×2 CATCH"
		if state.ds.extraCatch > 1 then rightText = rightText .. " x" .. state.ds.extraCatch end
	end
	text(p, rightText, STRIP_W - 10, midY, 11, C.dim, VR)
	p:setFontSize(11 * S)
	local rightEdge = STRIP_W - 10 - p:textBoxSize(rightText).width // (64 * S)

	if state.ds then
		local centerText = string.format("D:%d   S:%d   R:%d", state.ds.drinks, state.ds.shots, state.ds.revives)
		local gap = math.max(0, rightEdge - leftEdge)
		-- shrink from 13 down to 9 if the natural size wouldn't fit the
		-- available gap; below 9 just let it clip rather than go illegible
		local size = 13
		p:setFontSize(size * S)
		local w = p:textBoxSize(centerText).width // (64 * S)
		while w > gap - 12 and size > 9 do
			size = size - 1
			p:setFontSize(size * S)
			w = p:textBoxSize(centerText).width // (64 * S)
		end
		text(p, centerText, (leftEdge + rightEdge) // 2, midY, size, C.accent, VC)
	end
	state.bottomLayer:update()
	canvas:update()
	if DEBUG_LOG then state.bottomLayer.image:save(DEBUG_LOG .. "/strip_bottom.png", "PNG") end
end

local function draw()
	if not state.layer then return end
	local p = image.newPainter(state.layer.image)
	p:loadFont(FONT_PATH)
	p:setBlend(false)
	rect(p, 0, 0, PANEL_W, PANEL_H, C.bg)
	p:setBlend(true)

	local w = PANEL_W

	if not state.game then
		text(p, "PokéParty HUD", 5, 4, 9, C.text)
		text(p, "No supported game.", 5, 20, 8, C.dim)
		text(p, "Gen 3 (US) only.", 5, 31, 8, C.dim)
		state.layer:update()
		canvas:update()
		drawTopStrip()
		drawBottomStrip()
		return
	end

	-- header: badges only now — game name moved to the top strip, trainer
	-- id dropped (level cap / drinks / shots / faints live full-width in
	-- the bottom strip)
	if state.stats then
		local iconPx = 13
		local pitch = (w - 8) / 8
		for i = 0, 7 do
			local earned = i < state.stats.badges
			local icon = getBadgeIcon(i, iconPx)
			local color
			local hues = BADGE_HUES[state.game.code]
			if icon and BADGE_COLOR_MODE == "color" and hues then
				color = earned and hues[i + 1] or dimColor(hues[i + 1], 0.08)
			else
				color = earned and C.badgeOn or C.badgeOff
			end
			local x = 4 + i * pitch
			if icon then
				mask(p, icon, x, 4, color)
			else
				rect(p, x, 8, iconPx, 6, color)
			end
		end
	else
		text(p, "Waiting for save…", 5, 8, 8, C.dim)
	end
	rect(p, 3, 21, w - 6, 1, C.line)

	-- party rows
	local y = 23
	for _, mon in ipairs(state.party) do
		drawMonRow(p, 3, y, w - 6, mon)
		y = y + 20
	end
	if #state.party == 0 and state.stats then
		text(p, "Party empty", 5, y + 2, 8, C.dim)
	end

	-- footer: cheat hint only (flash and x2-catch moved to the strips)
	if CHEAT_RARE_CANDIES > 0 and state.stats then
		rect(p, 3, PANEL_H - 11, w - 6, 10, C.hpBack)
		rect(p, 3, PANEL_H - 11, 2, 10, C.accent)
		text(p, "[" .. string.char(CANDY_KEY) .. "] RARE CANDY x" .. CHEAT_RARE_CANDIES,
			w // 2, PANEL_H - 11, 7, C.text, TC)
	end

	state.layer:update()
	canvas:update()
	drawTopStrip()
	drawBottomStrip()

	if DEBUG_LOG then
		state.layer.image:save(DEBUG_LOG .. "/panel.png", "PNG")
	end
end

-- cheat trigger: top up rare candies on demand (hotkey / pad button)
local function giveCandies()
	if CHEAT_RARE_CANDIES <= 0 or not state.game or not state.stats then return end
	local res, err = gen3.giveItem(state.game, gen3.ITEM_RARE_CANDY, CHEAT_RARE_CANDIES)
	local msg
	if res then
		msg = "RARE CANDY x" .. CHEAT_RARE_CANDIES
		log("cheat: rare candies " .. res)
	elseif err then
		msg = err
		log("cheat: " .. err)
	else
		msg = "candies already full"
	end
	flash(msg)
end

local function flashActive()
	return state.flash and state.flash.expiresAt > os.time()
end

-- signature of displayed data; redraw only on change
local function signature()
	local parts = { flashActive() and state.flash.text or "F0" }
	if state.ds then
		parts[#parts + 1] = state.ds.drinks
		parts[#parts + 1] = state.ds.shots
		parts[#parts + 1] = state.ds.levelCapDelta
		parts[#parts + 1] = state.ds.extraCatch
		parts[#parts + 1] = state.ds.faints
		parts[#parts + 1] = state.ds.revives
	end
	if state.stage then
		parts[#parts + 1] = state.stage.label
		parts[#parts + 1] = state.stage.maxLevel
	end
	if state.stats then
		parts[#parts + 1] = state.stats.badges
		parts[#parts + 1] = state.stats.caught
		parts[#parts + 1] = state.stats.seen
		parts[#parts + 1] = state.stats.tid
	end
	for _, m in ipairs(state.party) do
		parts[#parts + 1] = string.format("%d:%d:%d:%d:%d:%s:%s",
			m.species, m.level, m.hp, m.maxHP, m.personality, m.nickname, m.cond or "")
	end
	return table.concat(parts, "|")
end

-- ------------------------------------------------------------------------
-- wiring
-- ------------------------------------------------------------------------
-- layers must be created at script load scope
if canvas then
	-- 3-arg newLayer is our mGBA patch; fall back for unpatched builds
	local function newLayer(w, h)
		local ok, layer = pcall(function() return canvas:newLayer(w, h, HUD_SCALE) end)
		if not ok or not layer then
			layer = canvas:newLayer(w, h)
		end
		return layer
	end

	state.layer = newLayer(PANEL_W, PANEL_H)
	if state.layer then
		-- actual granted upscale (1 on an unpatched mGBA build)
		S = state.layer.image.width // PANEL_W
		state.layer:setPosition(canvas:screenWidth(), 0)
	end
	if STRIP_H > 0 then
		state.topLayer = newLayer(STRIP_W, STRIP_H)
		if state.topLayer then state.topLayer:setPosition(0, -STRIP_H) end
		state.bottomLayer = newLayer(STRIP_W, STRIP_H)
		if state.bottomLayer then state.bottomLayer:setPosition(0, canvas:screenHeight()) end
	end
	log(string.format("canvas %dx%d screen %dx%d hud-scale %d strip-h %d",
		canvas:width(), canvas:height(), canvas:screenWidth(), canvas:screenHeight(), S, STRIP_H))
	-- wheel layer created last so it stacks above everything else
	wheel.init(S)
else
	log("no canvas available — launch mGBA with --script and a ROM")
end

local function onFrame()
	state.frame = state.frame + 1
	-- wheel animates every frame; resolves to a segment exactly once
	local seg = wheel.tick()
	if seg then
		local msg = "WHEEL: " .. seg.label:gsub("\n", " ")
		if state.ds then
			state.ds.drinks = state.ds.drinks + (seg.drinks or 0)
			state.ds.shots = state.ds.shots + (seg.shots or 0)
			if seg.cap then
				state.ds.levelCapDelta = state.ds.levelCapDelta + seg.cap
				msg = msg .. string.format(" (cap %+d)", seg.cap)
			end
			if seg.catch then
				state.ds.extraCatch = state.ds.extraCatch + seg.catch
				msg = msg .. string.format(" (+%d catch)", seg.catch)
			end
			if seg.revive then
				state.ds.revives = state.ds.revives + seg.revive
			end
			state.dsDirty = true
		end
		flash(msg)
		log(msg)
	end
	if state.frame % 20 ~= 0 then return end
	if not state.layer then return end
	if not state.game then
		if state.frame % 120 == 0 then detectGame() end
		if not state.game and state.lastSig ~= "nogame" then
			state.lastSig = "nogame"
			draw()
		end
		return
	end
	refresh()
	local sig = signature()
	if sig ~= state.lastSig then
		state.lastSig = sig
		draw()
	end
	if DEBUG_LOG and state.frame % 300 == 0 then
		log(string.format("geom: canvas %dx%d screen %dx%d panel@%d,%d img %dx%d",
			canvas:width(), canvas:height(), canvas:screenWidth(), canvas:screenHeight(),
			state.layer.x, state.layer.y, state.layer.image.width, state.layer.image.height))
	end
end

local lastError = nil
callbacks:add("frame", function()
	local ok, err = pcall(onFrame)
	if not ok and tostring(err) ~= lastError then
		lastError = tostring(err)
		log("error: " .. lastError)
	end
end)
callbacks:add("reset", detectGame)
-- fires once, ~15 frames (~0.25s) after the game's own save-memory writes
-- settle — i.e. exactly when a real in-game save completes. This (not
-- every-tick eager writes) is what makes counters correctly NOT survive an
-- unsaved reload.
callbacks:add("savedataUpdated", function() pcall(commitDS) end)
callbacks:add("stop", function()
	pcall(commitDS) -- best-effort: catch a save that landed just before close
	state.game = nil
	state.lastSig = nil
end)

-- cheat hotkeys: keyboard (default "c") and optional gamepad button.
-- INPUT_STATE: 0=up 1=down 2=held — trigger on down only.
callbacks:add("key", function(ev)
	if DEBUG_LOG then log("key " .. tostring(ev.key) .. " state " .. tostring(ev.state)) end
	-- normalize letters to uppercase (Qt keycodes are uppercase ASCII)
	local k = ev.key
	if k >= 0x61 and k <= 0x7A then k = k - 32 end
	if ev.state ~= 1 then return end
	if k == CANDY_KEY then
		pcall(giveCandies)
	elseif k == KEY_RIVAL and state.ds then
		state.ds.shots = state.ds.shots + 1
		state.dsDirty = true
		flash("RIVAL BEATEN! SHOT!")
	elseif k == KEY_IMPORTANT then
		pcall(toggleImportant)
	elseif k == KEY_WHEEL then
		pcall(wheel.spin)
	elseif state.ds and (k == KEY_DRINK_DOWN or k == KEY_DRINK_UP
			or k == KEY_SHOT_DOWN or k == KEY_SHOT_UP
			or k == KEY_REVIVE_DOWN or k == KEY_REVIVE_UP) then
		local ds = state.ds
		if k == KEY_DRINK_UP then
			ds.drinks = ds.drinks + 1
			flash("DRINK +1 (MANUAL)")
		elseif k == KEY_DRINK_DOWN then
			ds.drinks = math.max(0, ds.drinks - 1)
			flash("DRINK -1 (MANUAL)")
		elseif k == KEY_SHOT_UP then
			ds.shots = ds.shots + 1
			flash("SHOT +1 (MANUAL)")
		elseif k == KEY_SHOT_DOWN then
			ds.shots = math.max(0, ds.shots - 1)
			flash("SHOT -1 (MANUAL)")
		elseif k == KEY_REVIVE_UP then
			ds.revives = ds.revives + 1
			flash("REVIVE +1 (MANUAL)")
		elseif k == KEY_REVIVE_DOWN then
			ds.revives = math.max(0, ds.revives - 1)
			flash("REVIVE -1 (MANUAL)")
		end
		state.dsDirty = true
	end
end)
callbacks:add("gamepadButton", function(ev)
	if ev.state == 1 then
		if DEBUG_LOG then log("gamepad button " .. tostring(ev.button)) end
		if CANDY_PAD and ev.button == CANDY_PAD then
			pcall(giveCandies)
		end
	end
end)

detectGame()
log("HUD loaded")
