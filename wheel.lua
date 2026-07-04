-- wheel.lua — spinning bonus/punishment wheel overlay for drunklocke runs
-- Static pre-rendered disc + spinning arrow (rotating a bitmap per frame is
-- too slow in Lua; a spinning pointer reads the same and costs 3 draw calls).
--
-- Usage:
--   local wheel = dofile(script.dir .. "/wheel.lua")
--   wheel.init(S)              -- once at load scope (creates canvas layer)
--   wheel.spin()               -- kick off a spin
--   wheel.tick()               -- every frame; returns landed segment once,
--                              -- at the moment the spin resolves
--   wheel.active               -- true while visible

local wheel = { active = false }
-- callers may override this (e.g. party-hud.lua points it at its own
-- log() so wheel messages also land in POKEPARTY_DEBUG's log file)
wheel.log = function(msg) console:log("PokéParty: " .. msg) end

-- edit freely: label lines, wedge color, and optional counter effects.
-- `catch` is EXTRA charges granted on top of the normal nuzlocke 1-per-route
-- catch (so catch=1 is what "x2 CATCH" means: 2 total, 1 bonus) — not a
-- multiplier, party-hud.lua adds it directly to state.ds.extraCatch.
-- `good = true` marks a segment as a positive outcome (party-hud.lua plays
-- a celebration sound combo on landing); everything else is neutral/
-- punishment and gets no result sound for now.
wheel.SEGMENTS = {
	{ label = "SHOT!",          color = 0xFFE5484D, shots  = 1 },
	{ label = "REVIVE!", 		color = 0xFF41C463, revive = 1, good = true },
	{ label = "DRINK\nx2",      color = 0xFFF5C542, drinks = 2 },
	{ label = "+2 LVL\nCAP",    color = 0xFF6890F0, cap    = 2, good = true },
	{ label = "x2 CATCH", 		color = 0xFFF08030, catch  = 1, good = true },
	{ label = "THICK\nWATER",   color = 0xFF7C2E8C, good = true },
	{ label = "FINISH\nDRINK",  color = 0xFFA8B820, drinks = 1 },
	{ label = "KILL ★",      	color = 0xFF6BC7E0, drinks = 1 },
}

local SIZE = 140            -- logical (GBA px) square, centered over game
local S = 1                 -- hi-res factor, set in init
local state = {
	layer = nil,
	disc = nil,             -- pre-rendered wheel image (strong ref)
	angle = 0,
	vel = 0,
	phase = "idle",         -- idle | spinning | showing
	result = nil,
	holdUntil = 0,          -- os.time()-based; result banner display duration
	frame = 0,              -- draw-throttle counter only, NOT used for timing
	-- tick() is driven by the "frame" callback = once per EMULATED frame,
	-- which runs 2-4x faster than real time under fast-forward. mGBA's Lua
	-- sandbox has no sub-second wall clock (os.clock() is CPU time, drifts
	-- when the process idles between frames — see party-hud.lua's flash
	-- timing fix; os.time() is real but only 1-second resolution, too
	-- coarse for smooth spin physics). So: self-calibrate by measuring how
	-- many ticks actually land within each real second, then scale the
	-- per-tick decay so the TOTAL decay applied per real second stays
	-- constant regardless of how many ticks that took — the spin settles
	-- in ~the same real-world time at 1x or 4x speed.
	tickSecMark = os.time(),
	ticksThisSec = 0,
	measuredRate = 60, -- ticks/sec, updated continuously; 60 = 1x default
}
-- decay tuned at the original 60-ticks/sec baseline (0.985/tick), expressed
-- as "how much velocity survives after one real second" (≈0.404) —
-- reapplied at whatever rate ticks actually happen at, so total decay per
-- real second stays constant regardless of tick rate.
local DECAY_PER_SECOND = 0.985 ^ 60

local function px(v) return math.floor(v * S) end

local function prerenderDisc()
	local D = SIZE * S
	local img = image.new(D, D)
	local p = image.newPainter(img)
	p:loadFont("/usr/share/fonts/truetype/dejavu/DejaVuSansCondensed.ttf")
	local cx, cy = D // 2, D // 2
	local r = D // 2 - 2 * S
	local n = #wheel.SEGMENTS
	-- fill wedges with fine radial lines (no arc/polygon API)
	p:setBlend(false)
	p:setFill(true)
	local steps = 1440
	p:setStrokeWidth(math.max(3, S * 2))
	for i = 0, steps - 1 do
		local a = i * 2 * math.pi / steps
		local seg = (i * n // steps) + 1
		p:setStrokeColor(wheel.SEGMENTS[seg].color)
		p:drawLine(cx, cy, cx + math.floor(math.cos(a) * r), cy + math.floor(math.sin(a) * r))
	end
	-- wedge borders
	p:setStrokeColor(0xFF14181D)
	p:setStrokeWidth(math.max(2, S))
	for i = 0, n - 1 do
		local a = i * 2 * math.pi / n
		p:drawLine(cx, cy, cx + math.floor(math.cos(a) * r), cy + math.floor(math.sin(a) * r))
	end
	-- rim
	p:setFill(false)
	p:setStrokeColor(0xFFECEFF4)
	p:setStrokeWidth(math.max(2, S))
	p:drawCircle(cx - r, cy - r, r * 2)
	-- labels at wedge midpoints
	p:setBlend(true)
	p:setFill(true)
	p:setStrokeWidth(0)
	p:setFontSize(7 * S)
	for i = 1, n do
		local a = (i - 0.5) * 2 * math.pi / n
		local lx = cx + math.floor(math.cos(a) * r * 0.62)
		local ly = cy + math.floor(math.sin(a) * r * 0.62)
		local lines = {}
		for line in wheel.SEGMENTS[i].label:gmatch("[^\n]+") do lines[#lines + 1] = line end
		local lh = 8 * S
		local y0 = ly - (#lines * lh) // 2
		p:setFillColor(0xFF10141D)
		for j, line in ipairs(lines) do
			p:drawText(line, lx, y0 + (j - 1) * lh, 0x12) -- top|center
		end
	end
	return img
end

local function clearLayer()
	local p = image.newPainter(state.layer.image)
	p:setBlend(false)
	p:setFill(true)
	p:setFillColor(0x00000000)
	p:setStrokeWidth(0)
	p:drawRectangle(0, 0, SIZE * S, SIZE * S)
	state.layer:update()
	canvas:update()
end

local function draw()
	local D = SIZE * S
	local cx, cy = D // 2, D // 2
	local r = D // 2 - 2 * S
	-- disc blit (opaque wheel over transparent corners handled by drawImage)
	local p = image.newPainter(state.layer.image)
	p:setBlend(false)
	p:setFill(true)
	p:setFillColor(0x00000000)
	p:setStrokeWidth(0)
	p:drawRectangle(0, 0, D, D)
	state.layer.image:drawImage(state.disc, 0, 0)
	-- arrow
	p:setBlend(true)
	local ax = math.cos(state.angle)
	local ay = math.sin(state.angle)
	p:setStrokeColor(0xFF14181D)
	p:setStrokeWidth(math.max(4, S * 2 + 2))
	p:drawLine(cx, cy, cx + math.floor(ax * r * 0.82), cy + math.floor(ay * r * 0.82))
	p:setStrokeColor(0xFFECEFF4)
	p:setStrokeWidth(math.max(2, S))
	p:drawLine(cx, cy, cx + math.floor(ax * r * 0.8), cy + math.floor(ay * r * 0.8))
	-- hub
	p:setFill(true)
	p:setStrokeWidth(0)
	p:setFillColor(0xFFECEFF4)
	p:drawCircle(cx - 4 * S, cy - 4 * S, 8 * S)
	-- result banner
	if state.phase == "showing" and state.result then
		local seg = wheel.SEGMENTS[state.result]
		local bw, bh = 96 * S, 16 * S
		p:setFillColor(0xF014181D)
		p:drawRectangle(cx - bw // 2, D - bh - 2 * S, bw, bh)
		p:setFillColor(seg.color)
		p:drawRectangle(cx - bw // 2, D - bh - 2 * S, 2 * S, bh)
		p:setFontSize(9 * S)
		p:setFillColor(0xFFECEFF4)
		p:drawText(seg.label:gsub("\n", " "), cx, D - bh, 0x12) -- top|center
	end
	state.layer:update()
	canvas:update()
end

function wheel.init(scale)
	S = scale or 1
	state.layer = canvas:newLayer(SIZE, SIZE, S)
	if not state.layer then return false end
	local x = (canvas:screenWidth() - SIZE) // 2
	local y = (canvas:screenHeight() - SIZE) // 2
	state.layer:setPosition(math.max(0, x), math.max(0, y))
	-- no canvas:update() here: pushing layer dims at load can race the
	-- frontend's videoScale application (fresh layer images start blank)
	math.randomseed(os.time())
	return true
end

function wheel.spin()
	if not state.layer or state.phase == "spinning" then return end
	if not state.disc then
		state.disc = prerenderDisc()
	end
	wheel.log(string.format("wheel spin start, measured rate %d ticks/sec", state.measuredRate))
	state.phase = "spinning"
	wheel.active = true
	state.angle = math.random() * 2 * math.pi
	state.vel = 0.45 + math.random() * 0.25
	state.result = nil
	state.prevSegIdx = nil
end

-- call every frame; returns the landed segment table exactly once
function wheel.tick()
	if not state.layer then return nil end

	-- self-calibrate ticks/real-second continuously, even while idle — NOT
	-- gated behind "only while spinning". Measuring only during a spin is a
	-- chicken-and-egg problem: on the first spin of a session the rate is
	-- still the stale 60 default, which (if the true rate is much higher,
	-- e.g. under fast-forward) makes the decay wildly too aggressive, so
	-- the spin resolves in a fraction of a second — before a full real
	-- second ever elapses to correct the measurement. Calibrating
	-- continuously means the rate is already accurate the moment a spin
	-- starts, whenever that happens to be.
	state.ticksThisSec = state.ticksThisSec + 1
	local now = os.time()
	if now ~= state.tickSecMark then
		state.measuredRate = math.max(1, state.ticksThisSec)
		state.ticksThisSec = 0
		state.tickSecMark = now
	end

	if state.phase == "idle" then return nil end
	state.frame = state.frame + 1

	if state.phase == "spinning" then
		state.angle = (state.angle + state.vel) % (2 * math.pi)
		local perTickDecay = DECAY_PER_SECOND ^ (1 / state.measuredRate)
		state.vel = state.vel * perTickDecay
		-- ratchet tick: fire whenever the wheel crosses a segment boundary,
		-- driven by the actual live angle/velocity (same physics the visual
		-- draw uses), not a separately-authored audio clip guessing the
		-- timing — this is what makes it track the real deceleration curve.
		-- At peak speed the wheel can cross more than one segment per tick,
		-- which would fire a burst of paplay spawns fast enough to overlap
		-- and garble — cap the audible rate (reusing the same self-
		-- calibrated measuredRate the decay math already depends on) rather
		-- than trying to fire one sound per crossing. 20/sec still garbled
		-- in live testing; dropped to 10/sec.
		local n = #wheel.SEGMENTS
		local segIdx = math.floor(state.angle / (2 * math.pi) * n) % n
		local minGap = math.max(1, math.floor(state.measuredRate / 10))
		if state.prevSegIdx and segIdx ~= state.prevSegIdx and wheel.onTick
				and state.frame - (state.lastTickFrame or -1e9) >= minGap then
			wheel.onTick()
			state.lastTickFrame = state.frame
		end
		state.prevSegIdx = segIdx
		if state.frame % 2 == 0 then draw() end
		if state.vel < 0.006 then
			local n = #wheel.SEGMENTS
			state.result = (math.floor(state.angle / (2 * math.pi) * n) % n) + 1
			state.phase = "showing"
			state.holdUntil = os.time() + 5
			draw()
			return wheel.SEGMENTS[state.result]
		end
	elseif state.phase == "showing" then
		if os.time() >= state.holdUntil then
			state.phase = "idle"
			wheel.active = false
			clearLayer()
		end
	end
	return nil
end

return wheel
