-- gen3.lua — Gen 3 (GBA) Pokémon RAM/ROM decoding for PokéParty HUD
-- Supports: Ruby/Sapphire (AXVE/AXPE), FireRed/LeafGreen (BPRE/BPGE), Emerald (BPEE)

local gen3 = {}

-- ========================================================================
-- Gen 3 proprietary text charset (Western)
-- ========================================================================
local CHARSET = {}
do
	CHARSET[0x00] = " "
	local digits = "0123456789"
	for i = 1, 10 do CHARSET[0xA0 + i] = digits:sub(i, i) end
	CHARSET[0xAB] = "!"; CHARSET[0xAC] = "?"; CHARSET[0xAD] = "."
	CHARSET[0xAE] = "-"; CHARSET[0xB0] = "…"; CHARSET[0xB1] = "\u{201C}"
	CHARSET[0xB2] = "\u{201D}"; CHARSET[0xB3] = "\u{2018}"; CHARSET[0xB4] = "'"
	CHARSET[0xB5] = "\u{2642}"; CHARSET[0xB6] = "\u{2640}"; CHARSET[0xB8] = ","
	CHARSET[0xBA] = "/"
	for i = 0, 25 do
		CHARSET[0xBB + i] = string.char(0x41 + i) -- A-Z
		CHARSET[0xD5 + i] = string.char(0x61 + i) -- a-z
	end
end

function gen3.decodeText(bytes)
	local out = {}
	for i = 1, #bytes do
		local b = bytes:byte(i)
		if b == 0xFF then break end
		out[#out + 1] = CHARSET[b] or "?"
	end
	return table.concat(out)
end

-- ========================================================================
-- Per-game address database (US versions)
-- ========================================================================
-- ptrMode: saveblock addresses are pointers in IWRAM (FRLG/Emerald ASLR);
-- otherwise they are the fixed EWRAM addresses themselves (Ruby/Sapphire).
local GAMES = {
	BPEE = {
		name = "Emerald", party = 0x020244EC, partyCount = 0x020244E9,
		sb1 = 0x03005D8C, sb2 = 0x03005D90, ptrMode = true,
		flagsOfs = 0x1270, badgeFlag = 0x867,
		bagOfs = 0x560, bagSlots = 30, secKeyOfs = 0xAC,
		trainerFlag = 0x500, trainerCount = 864,
	},
	BPRE = {
		name = "FireRed", party = 0x02024284, partyCount = 0x02024029,
		sb1 = 0x03005008, sb2 = 0x0300500C, ptrMode = true,
		flagsOfs = 0xEE0, badgeFlag = 0x820,
		bagOfs = 0x310, bagSlots = 42, secKeyOfs = 0xF20,
		trainerFlag = 0x500, trainerCount = 743,
	},
	BPGE = {
		name = "LeafGreen", party = 0x02024284, partyCount = 0x02024029,
		sb1 = 0x03005008, sb2 = 0x0300500C, ptrMode = true,
		flagsOfs = 0xEE0, badgeFlag = 0x820,
		bagOfs = 0x310, bagSlots = 42, secKeyOfs = 0xF20,
		trainerFlag = 0x500, trainerCount = 743,
	},
	AXVE = {
		name = "Ruby", party = 0x03004360, partyCount = 0x03004350,
		sb1 = 0x02025734, sb2 = 0x02024EA4, ptrMode = false,
		flagsOfs = 0x1220, badgeFlag = 0x807,
		bagOfs = 0x560, bagSlots = 20, secKeyOfs = nil,
		trainerFlag = 0x500, trainerCount = 694,
	},
	AXPE = {
		name = "Sapphire", party = 0x03004360, partyCount = 0x03004350,
		sb1 = 0x02025734, sb2 = 0x02024EA4, ptrMode = false,
		flagsOfs = 0x1220, badgeFlag = 0x807,
		bagOfs = 0x560, bagSlots = 20, secKeyOfs = nil,
		trainerFlag = 0x500, trainerCount = 694,
	},
}

-- Common SaveBlock2 layout (all Gen 3)
local SB2_TRAINER_ID = 0x0A -- u32: TID | SID<<16
local SB2_DEX_OWNED  = 0x28 -- u8[52] bitfield, national dex order
local SB2_DEX_SEEN   = 0x5C -- u8[52]

gen3.TYPE_NAMES = {
	[0]="Normal","Fighting","Flying","Poison","Ground","Rock","Bug","Ghost",
	"Steel","???","Fire","Water","Grass","Electric","Psychic","Ice","Dragon","Dark",
}

-- ========================================================================
-- Detection
-- ========================================================================
function gen3.detect()
	local ok, code = pcall(function() return emu:readRange(0x080000AC, 4) end)
	if not ok or not code then return nil end
	local game = GAMES[code]
	if not game then return nil end
	local g = {}
	for k, v in pairs(game) do g[k] = v end
	g.code = code
	return g
end

-- ========================================================================
-- ROM table discovery (scan once, cache result)
-- gSpeciesNames: 11 bytes/entry, entry 1 = "BULBASAUR"
-- gBaseStats:    28 bytes/entry, entry 1 = Bulbasaur (45,49,49,45,65,65, Grass/Poison, 45, 64)
-- ========================================================================
local NAMES_PATTERN = "\xBC\xCF\xC6\xBC\xBB\xCD\xBB\xCF\xCC\xFF" -- "BULBASAUR" + terminator
-- Base stats anchored by entry bytes +19..21 (growthRate, eggGroup1,
-- eggGroup2) — randomizers (UPR ZX) and QoL hacks leave these alone while
-- stats, types, catch rate, egg cycles etc. all get edited. Anchor is
-- Bulbasaur's MEDIUM_SLOW + Monster/Grass, verified across species 1-9.
local STATS_ANCHOR = "\x03\x01\x07"
local STATS_EXPECT = {
	[1] = "\x03\x01\x07", [2] = "\x03\x01\x07", [3] = "\x03\x01\x07", -- bulbasaur line
	[4] = "\x03\x01\x0E", [5] = "\x03\x01\x0E", [6] = "\x03\x01\x0E", -- charmander line
	[7] = "\x03\x01\x02", [8] = "\x03\x01\x02", [9] = "\x03\x01\x02", -- squirtle line
}

-- find every match of pattern in ROM, call verify(absOffset); first offset
-- accepted by verify wins. verify=nil accepts the first match.
local function scanROM(pattern, verify)
	local CHUNK = 0x40000
	local overlap = #pattern - 1
	for base = 0, 0x00FFFFFF, CHUNK do
		local ok, data = pcall(function()
			return emu:readRange(0x08000000 + base, CHUNK + overlap)
		end)
		if not ok or not data then
			ok, data = pcall(function() return emu:readRange(0x08000000 + base, CHUNK) end)
			if not ok or not data then return nil end
		end
		local pos = 0
		while true do
			pos = data:find(pattern, pos + 1, true)
			if not pos or pos > CHUNK then break end
			local hit = base + pos - 1
			if not verify or verify(hit) then return hit end
		end
	end
	return nil
end

-- candidate = anchor hit at +19 of Bulbasaur's entry (#1); verify the
-- growth/egg-group triple for species 1-9
local function verifyStatsAnchor(hit)
	local tbl = hit - 19 - 28
	if tbl < 0 then return false end
	local ok, data = pcall(function()
		return emu:readRange(0x08000000 + tbl, 10 * 28)
	end)
	if not ok or not data then return false end
	for sp, expect in pairs(STATS_EXPECT) do
		if data:sub(sp * 28 + 20, sp * 28 + 22) ~= expect then return false end
	end
	return true
end

-- unique-per-ROM cache identity (randomizers/hacks share game codes)
function gen3.romIdent(game)
	if game.ident then return game.ident end
	local okC, crc = pcall(function() return emu:checksum() end)
	game.ident = okC and crc and (crc:gsub(".", function(c)
		return string.format("%02x", c:byte())
	end)) or game.code
	return game.ident
end

-- bucket: script storage bucket for caching scan results across sessions
function gen3.locateTables(game, bucket)
	local key = "romtbl2_" .. game.code .. "_" .. gen3.romIdent(game)
	-- storage returns tables as userdata wrappers; type() lies but field
	-- access works, so probe fields directly
	local cNames, cStats
	pcall(function()
		local v = bucket and bucket[key]
		if v then cNames, cStats = v.names, v.stats end
	end)
	if type(cNames) == "number" and type(cStats) == "number" then
		game.namesTable = cNames
		game.statsTable = cStats
		return true
	end
	local namesHit = scanROM(NAMES_PATTERN)
	local statsHit = scanROM(STATS_ANCHOR, verifyStatsAnchor)
	if not namesHit then return false end
	game.namesTable = 0x08000000 + namesHit - 11 -- entry 0 precedes Bulbasaur
	game.statsTable = statsHit and (0x08000000 + statsHit - 19 - 28) or nil
	if bucket then
		bucket[key] = { names = game.namesTable, stats = game.statsTable }
	end
	return true
end

function gen3.speciesName(game, id)
	if not game.namesTable or id < 0 or id > 439 then return "?" end
	local ok, raw = pcall(function() return emu:readRange(game.namesTable + id * 11, 11) end)
	if not ok or not raw then return "?" end
	return gen3.decodeText(raw)
end

function gen3.speciesTypes(game, id)
	if not game.statsTable or id < 1 or id > 439 then return nil, nil end
	local base = game.statsTable + id * 28
	local ok, t1, t2 = pcall(function() return emu:read8(base + 6), emu:read8(base + 7) end)
	if not ok then return nil, nil end
	return t1, t2
end

-- ========================================================================
-- Save block access
-- ========================================================================
-- Rebuilt ROM hacks (pokeemerald decomp) shift the IWRAM addresses of
-- gSaveBlock1Ptr/gSaveBlock2Ptr. Scan IWRAM for two adjacent EWRAM pointers
-- (vanilla order: SB1 then SB2) where SB2's trainerId matches some party
-- mon's OT id. Returns true if the game's sb1/sb2 addresses were updated.
function gen3.findSavePtrs(game, party, bucket)
	if not game.ptrMode or #party == 0 then return false end
	local key = "sbptr_" .. game.code .. "_" .. gen3.romIdent(game)

	local function tidMatches(sb2ptr)
		local ok, lo, hi = pcall(function()
			return emu:read16(sb2ptr + SB2_TRAINER_ID), emu:read16(sb2ptr + SB2_TRAINER_ID + 2)
		end)
		if not ok then return false end
		local tid = lo | (hi << 16)
		for _, mon in ipairs(party) do
			if mon.otId == tid then return true end
		end
		return false
	end

	local cached = bucket and tonumber(bucket[key])
	if cached then
		local ok, b = pcall(function() return emu:read32(cached + 4) end)
		if ok and b and (b & 0xFF000000) == 0x02000000 and tidMatches(b) then
			game.sb1, game.sb2 = cached, cached + 4
			return true
		end
	end

	local ok, iwram = pcall(function() return emu:readRange(0x03000000, 0x8000) end)
	if not ok or not iwram then return false end
	for off = 0, #iwram - 8, 4 do
		local a = string.unpack("<I4", iwram, off + 1)
		if (a & 0xFF000000) == 0x02000000 then
			local b = string.unpack("<I4", iwram, off + 5)
			if (b & 0xFF000000) == 0x02000000 and a ~= b and tidMatches(b) then
				game.sb1 = 0x03000000 + off
				game.sb2 = 0x03000000 + off + 4
				if bucket then bucket[key] = game.sb1 end
				return true
			end
		end
	end
	return false
end

local function saveBlocks(game)
	local sb1, sb2 = game.sb1, game.sb2
	if game.ptrMode then
		local ok
		ok, sb1 = pcall(function() return emu:read32(game.sb1) end)
		if not ok then return nil end
		ok, sb2 = pcall(function() return emu:read32(game.sb2) end)
		if not ok then return nil end
	end
	-- validate: must point into EWRAM
	if (sb1 & 0xFF000000) ~= 0x02000000 or (sb2 & 0xFF000000) ~= 0x02000000 then
		return nil
	end
	return sb1, sb2
end

local function popcountRange(addr, len)
	local ok, data = pcall(function() return emu:readRange(addr, len) end)
	if not ok or not data then return 0 end
	local n = 0
	for i = 1, #data do
		local b = data:byte(i)
		while b > 0 do
			n = n + (b & 1)
			b = b >> 1
		end
	end
	return n
end

-- popcount of the first nbits bits starting at addr
local function popcountBits(addr, nbits)
	local n = popcountRange(addr, nbits // 8)
	local rem = nbits % 8
	if rem > 0 then
		local ok, b = pcall(function() return emu:read8(addr + nbits // 8) end)
		if ok and b then
			b = b & ((1 << rem) - 1)
			while b > 0 do
				n = n + (b & 1)
				b = b >> 1
			end
		end
	end
	return n
end

-- badges, dex caught/seen, trainer id — nil if save not ready
function gen3.readTrainerStats(game)
	local sb1, sb2 = saveBlocks(game)
	if not sb1 then return nil end
	local badges = 0
	local flagsBase = sb1 + game.flagsOfs
	for i = 0, 7 do
		local f = game.badgeFlag + i
		local ok, byte = pcall(function() return emu:read8(flagsBase + (f >> 3)) end)
		if ok and byte and (byte & (1 << (f & 7))) ~= 0 then
			badges = badges + 1
		end
	end
	local caught = popcountRange(sb2 + SB2_DEX_OWNED, 52)
	local seen = popcountRange(sb2 + SB2_DEX_SEEN, 52)
	local okTid, tid = pcall(function() return emu:read32(sb2 + SB2_TRAINER_ID) end)
	local trainers = 0
	if game.trainerFlag then
		trainers = popcountBits(flagsBase + (game.trainerFlag >> 3), game.trainerCount)
	end
	return {
		badges = badges,
		caught = caught,
		seen = seen,
		trainers = trainers,
		tid = okTid and (tid & 0xFFFF) or 0,
	}
end

-- ========================================================================
-- Party icon sprites
-- ========================================================================
-- gMonIconTable = long run of ROM pointers (one per species incl. egg and
-- unown forms), immediately followed by gMonIconPaletteIndices (one small
-- byte per species), then the 4-aligned gMonIconPaletteTable
-- ({ptr,tag,pad} entries). The run+indices combo is a unique signature that
-- survives randomizers and rebuilt hacks.
function gen3.locateIconTables(game, bucket)
	local key = "icons_" .. game.code .. "_" .. gen3.romIdent(game)
	local cTbl, cN, cIdx, cPal
	pcall(function()
		local v = bucket and bucket[key]
		if v then cTbl, cN, cIdx, cPal = v.tbl, v.n, v.idx, v.pal end
	end)
	if type(cTbl) == "number" and type(cN) == "number"
		and type(cIdx) == "number" and type(cPal) == "number" then
		game.iconTable = cTbl
		game.iconCount = cN
		game.iconPalIdx = cIdx
		game.iconPalTbl = cPal
		return true
	end
	local CHUNK = 0x40000
	local run, runStart = 0, 0
	for base = 0, 0x00FFFFFF, CHUNK do
		local ok, data = pcall(function() return emu:readRange(0x08000000 + base, CHUNK) end)
		if not ok or not data or #data < 4 then break end
		for off = 0, #data - 4, 4 do
			local w = string.unpack("<I4", data, off + 1)
			if (w & 0xFE000000) == 0x08000000 then
				if run == 0 then runStart = base + off end
				run = run + 1
			else
				if run >= 410 then
					local tblEnd = base + off
					local okI, idx = pcall(function() return emu:readRange(0x08000000 + tblEnd, run) end)
					if okI and idx then
						local good, nonzero = true, 0
						for i = 1, #idx do
							local b = idx:byte(i)
							if b > 5 then
								good = false
								break
							end
							if b > 0 then nonzero = nonzero + 1 end
						end
						if good and nonzero > 50 then
							game.iconTable = 0x08000000 + runStart
							game.iconCount = run
							game.iconPalIdx = 0x08000000 + tblEnd
							game.iconPalTbl = 0x08000000 + ((tblEnd + run + 3) & ~3)
							if bucket then
								bucket[key] = {
									tbl = game.iconTable, n = run,
									idx = game.iconPalIdx, pal = game.iconPalTbl,
								}
							end
							return true
						end
					end
				end
				run = 0
			end
		end
	end
	return false
end

gen3.SPECIES_EGG = 412

-- build a px×px image resampled (nearest) from the 32x32 4bpp icon frame 0;
-- returned image is a method-return value so callers may cache it
function gen3.monIconImage(game, species, px)
	px = px or 16
	if not game.iconTable then return nil end
	if species < 0 or species >= game.iconCount then return nil end
	local ok, gfx, palIdx = pcall(function()
		local gfxPtr = emu:read32(game.iconTable + species * 4)
		return emu:readRange(gfxPtr, 512), emu:read8(game.iconPalIdx + species)
	end)
	if not ok or not gfx or #gfx < 512 then return nil end
	local okP, palRaw = pcall(function()
		local palPtr = emu:read32(game.iconPalTbl + palIdx * 8)
		return emu:readRange(palPtr, 32)
	end)
	if not okP or not palRaw or #palRaw < 32 then return nil end
	local colors = {}
	for i = 0, 15 do
		local c = string.unpack("<I2", palRaw, i * 2 + 1)
		colors[i] = 0xFF000000
			| (((c & 31) << 3) << 16)         -- R (BGR555 low bits)
			| ((((c >> 5) & 31) << 3) << 8)   -- G
			| (((c >> 10) & 31) << 3)         -- B
	end
	local img = image.new(px, px)
	for y = 0, px - 1 do
		local sy = y * 32 // px
		for x = 0, px - 1 do
			local sx = x * 32 // px
			local tile = (sy >> 3) * 4 + (sx >> 3)
			local byte = gfx:byte(tile * 32 + (sy & 7) * 4 + ((sx & 7) >> 1) + 1)
			local v = (sx & 1) == 1 and (byte >> 4) or (byte & 0xF)
			if v ~= 0 then -- 0 = transparent, image starts blank
				img:setPixel(x, y, colors[v])
			end
		end
	end
	return img
end

-- ========================================================================
-- Bag editing (cheats)
-- ========================================================================
gen3.ITEM_RARE_CANDY = 68

-- ensure the main items pocket holds at least `qty` of `itemId`.
-- Gen 3 bag quantities are XOR-encrypted with the low 16 bits of the
-- security key (Emerald SB2+0xAC, FRLG SB2+0xF20, none in Ruby/Sapphire).
-- Returns "topped"|"added"|nil(no change/not possible), plus error string.
function gen3.giveItem(game, itemId, qty)
	if not game.bagOfs then return nil end
	local sb1, sb2 = saveBlocks(game)
	if not sb1 then return nil end
	local key = 0
	if game.secKeyOfs then
		local ok, k = pcall(function() return emu:read32(sb2 + game.secKeyOfs) end)
		if not ok or not k then return nil end
		key = k & 0xFFFF
	end
	local base = sb1 + game.bagOfs
	local empty = nil
	for i = 0, game.bagSlots - 1 do
		local addr = base + i * 4
		local ok, id, q = pcall(function() return emu:read16(addr), emu:read16(addr + 2) end)
		if not ok then return nil end
		if id == 0 then
			empty = empty or addr
		else
			local quantity = q ~ key
			-- sanity: hacks can move/expand the bag; garbage means our
			-- offsets are wrong and writing would corrupt the save
			if id > 0x1FF or quantity > 999 then
				return nil, "bag layout mismatch — cheat disabled"
			end
			if id == itemId then
				if quantity >= qty then return nil end
				pcall(function() emu:write16(addr + 2, qty ~ key) end)
				return "topped"
			end
		end
	end
	if empty then
		local okW = pcall(function()
			emu:write16(empty, itemId)
			emu:write16(empty + 2, qty ~ key)
		end)
		if okW then return "added" end
	end
	return nil, "bag full"
end

-- ========================================================================
-- Badge icons (real sprites instead of plain squares)
-- ========================================================================
-- Badge graphics are LZ77-compressed in ROM (pret: sHoennTrainerCardBadges_Gfx
-- / sKantoTrainerCardBadges_Gfx, "graphics/trainer_card/badges.png" resp.
-- ".../frlg/badges.png") — unlike species icons, which are stored raw.
-- mGBA's scripting API has no decompression built in, so this is a small
-- from-scratch GBA-format LZ77 decoder.
--
-- Layout, read directly from pret's DrawStarsAndBadgesOnCard: badge i's four
-- 8x8 tiles sit at buffer positions 2i, 2i+1, 16+2i, 17+2i (a 16-tile-wide,
-- 2-row grid) — NOT four consecutive tiles as a naive guess would assume.
-- Confirmed by rendering and visually matching against the real 8 Hoenn and
-- 8 Kanto badges.
--
-- We only extract the SHAPE (4bpp index 0 = transparent, anything else =
-- ink) and tint it at draw time via mPainter:drawMask with the HUD's own
-- accent colors, rather than also hunting for the exact in-ROM palette —
-- simpler, one less thing to get wrong per-game, and matches the existing
-- gold/gray earned-badge color language already in use.
--
-- Addresses are hardcoded per game rather than scanned: this is purely
-- cosmetic UI data with no text/content anchor to scan for (unlike species
-- names or trainer names), and randomizers never touch cosmetic ROM
-- assets — only a full rebuild hack could move it, which the decompression
-- validation below will simply fail closed against (falls back to the
-- original colored squares).
local BADGE_GFX_ADDR = {
	BPEE = 0x0856F5CC, -- Hoenn badges; verified against a real Emerald ROM
	BPRE = 0x083CD658, -- Kanto badges; verified against a real FireRed ROM
}
BADGE_GFX_ADDR.BPGE = BADGE_GFX_ADDR.BPRE -- LeafGreen shares FireRed's assets
-- AXVE/AXPE (Ruby/Sapphire) presumably share Emerald's table, but this is
-- UNVERIFIED against a real ROM — see backlog.
BADGE_GFX_ADDR.AXVE = BADGE_GFX_ADDR.BPEE
BADGE_GFX_ADDR.AXPE = BADGE_GFX_ADDR.BPEE

local function lz77Decompress(addr)
	local ok, hdr = pcall(function() return emu:readRange(addr, 4) end)
	if not ok or not hdr or #hdr < 4 or hdr:byte(1) ~= 0x10 then return nil end
	local size = hdr:byte(2) | (hdr:byte(3) << 8) | (hdr:byte(4) << 16)
	if size <= 0 or size > 0x10000 then return nil end
	-- compressed data is never larger than ~9/8 of decompressed size in
	-- the GBA LZ77 format; 2x is a safe upper bound on how much to read
	local ok2, src = pcall(function() return emu:readRange(addr + 4, size * 2) end)
	if not ok2 or not src then return nil end
	local out = {}
	local pos, n = 1, 0
	while n < size do
		if pos > #src then return nil end
		local flags = src:byte(pos); pos = pos + 1
		for bit = 7, 0, -1 do
			if n >= size then break end
			if (flags & (1 << bit)) ~= 0 then
				if pos + 1 > #src then return nil end
				local b1, b2 = src:byte(pos), src:byte(pos + 1)
				pos = pos + 2
				local length = (b1 >> 4) + 3
				local disp = ((b1 & 0xF) << 8) | b2
				local start = n - disp - 1
				if start < 0 then return nil end
				for k = 0, length - 1 do
					if n >= size then break end
					n = n + 1
					out[n] = out[start + k + 1]
				end
			else
				if pos > #src then return nil end
				n = n + 1
				out[n] = src:byte(pos)
				pos = pos + 1
			end
		end
	end
	-- string.char in chunks: some Lua builds cap how many args a single
	-- call can take, 1024 individual bytes isn't safe to pass in one go
	local chunks = {}
	for i = 1, size, 200 do
		chunks[#chunks + 1] = string.char(table.unpack(out, i, math.min(i + 199, size)))
	end
	return table.concat(chunks)
end

-- decompresses (once per session — cheap, not worth persisting across a
-- restart) and validates the badge graphics for this game. Not cached to
-- storage: raw binary doesn't round-trip safely through the JSON-backed
-- bucket.
function gen3.locateBadgeIcons(game)
	if game.badgeData then return true end
	local addr = BADGE_GFX_ADDR[game.code]
	if not addr then return false end
	local data = lz77Decompress(addr)
	if not data or #data ~= 0x400 then return false end
	game.badgeData = data
	return true
end

-- 4bpp index -> grayscale shade, read directly from the real source art's
-- embedded palette (graphics/trainer_card/badges.png, same file for both
-- BPEE and BPRE — Gen3 renders every badge in this uniform silver-medal
-- style, no per-badge hue at all in the actual game). Every badge only
-- ever uses these five indices (confirmed by scanning all 8 badges in both
-- games' source art): 1-4 are the bevel highlight/mid/shadow tones, 15 is
-- the outline. Index 0 is the transparent background.
local BADGE_SHADE = { [1] = 0xF8, [2] = 0xD0, [3] = 0xB0, [4] = 0x78, [15] = 0x00 }

-- builds a px×px shaded mask for badge `index` (0-7), nearest-neighbor
-- sampled from the native 16x16 grid. RGB carries the real highlight/
-- shadow gradient (all three channels equal — i.e. grayscale); alpha is
-- opaque everywhere there's ink, transparent on background. Pass to
-- painter:drawMask with setFillColor: drawMask multiplies mask RGB by the
-- fill color channelwise, so a white pixel takes the fill color at full
-- strength and a gray pixel takes a proportionally darker shade of it —
-- this reproduces the bevel with WHATEVER tint the caller picks, whether
-- that's the real silver or a stylized per-badge hue.
function gen3.badgeIconImage(game, index, px)
	px = px or 16
	if not game.badgeData or index < 0 or index > 7 then return nil end
	local data = game.badgeData
	local shade = {} -- 0-255 grayscale value, or nil = transparent
	local function readQuadrant(tileIdx, ox, oy)
		local base = tileIdx * 32
		for r = 0, 7 do
			for c = 0, 3 do
				local byte = data:byte(base + r * 4 + c + 1)
				if not byte then return end
				local lo, hi = byte & 0xF, byte >> 4
				shade[(oy + r) * 16 + (ox + c * 2)] = BADGE_SHADE[lo] or (lo ~= 0 and 0x90 or nil)
				shade[(oy + r) * 16 + (ox + c * 2 + 1)] = BADGE_SHADE[hi] or (hi ~= 0 and 0x90 or nil)
			end
		end
	end
	readQuadrant(2 * index, 0, 0)
	readQuadrant(2 * index + 1, 8, 0)
	readQuadrant(16 + 2 * index, 0, 8)
	readQuadrant(17 + 2 * index, 8, 8)

	local img = image.new(px, px)
	for y = 0, px - 1 do
		local sy = y * 16 // px
		for x = 0, px - 1 do
			local sx = x * 16 // px
			local v = shade[sy * 16 + sx]
			if v then
				img:setPixel(x, y, 0xFF000000 | (v << 16) | (v << 8) | v)
			end
		end
	end
	return img
end

-- ========================================================================
-- Level cap tracking (gym/E4/champion boss levels)
-- ========================================================================
-- Boss trainer is located by name (encoded in the same charset as species
-- names) rather than by table offset: robust to ROM hacks that move
-- gTrainers[], and to randomizers that shuffle species/stats but leave
-- trainer identity alone. trainerId is fixed by the game engine (it's the
-- same index used for the trainer-beaten flag, TRAINER_FLAGS_START+id) and
-- is stable across randomizers for the same reason.
-- Struct layout (all Gen3 games, verified against pret/pokeemerald and
-- pret/pokefirered include/data.h, cross-checked byte-for-byte against real
-- ROMs — identical in both games):
--   struct Trainer { u8 partyFlags; u8 class; u8 music_gender; u8 pic;
--     u8 name[12]; u16 items[4]; bool8 doubleBattle; u32 aiFlags;
--     u8 partySize; <pad> TrainerMonPtr party; } -- 40 bytes total
-- partyFlags selects the TrainerMon variant; lvl is byte+2, species is
-- u16+4 within each entry, in every variant. STRIDE IS NOT THE STRUCT'S
-- NATURAL SIZE: the compiler 4-byte-aligns array elements, so the 6-byte
-- and 14-byte variants (flags 0/1) actually occupy 8 and 16 bytes each.
-- This bit Emerald's own validation by luck — every Emerald boss happens to
-- use flags=3 (16 bytes either way) — but broke FireRed's Brock outright
-- (his 2nd party slot decoded as garbage: level 0) until corrected here.
local TRAINER_STRUCT_SIZE = 40
local PARTY_STRIDE = { [0] = 8, [1] = 16, [2] = 8, [3] = 16 }

local function encodeName(name)
	local out = {}
	for i = 1, #name do
		out[i] = string.char(0xBB + (name:byte(i) - 0x41))
	end
	return table.concat(out)
end

-- structBase = start of the 40-byte Trainer struct (name begins at +4).
-- Returns the party's highest level, or nil if this isn't a valid trainer.
local function tryDecodeBossParty(structBase)
	if structBase < 0 then return nil end
	local ok, hdr = pcall(function()
		return emu:readRange(0x08000000 + structBase, TRAINER_STRUCT_SIZE)
	end)
	if not ok or not hdr or #hdr < TRAINER_STRUCT_SIZE then return nil end
	local partyFlags = hdr:byte(1)
	if not partyFlags or partyFlags > 3 then return nil end
	local partySize = hdr:byte(0x21)
	if not partySize or partySize < 1 or partySize > 6 then return nil end
	local ptr = string.unpack("<I4", hdr, 0x25)
	if (ptr & 0xFF000000) ~= 0x08000000 then return nil end
	local stride = PARTY_STRIDE[partyFlags]
	local okP, data = pcall(function() return emu:readRange(ptr, partySize * stride) end)
	if not okP or not data or #data < partySize * stride then return nil end
	local maxLevel = 0
	for m = 0, partySize - 1 do
		local lvl = data:byte(m * stride + 3)
		local sp = string.unpack("<I2", data, m * stride + 5)
		if not lvl or lvl < 1 or lvl > 100 or sp < 1 or sp > 439 then return nil end
		if lvl > maxLevel then maxLevel = lvl end
	end
	return maxLevel
end

-- Ordered stage list per game. label is the short HUD tag. id is the
-- gTrainers[] index (== trainer-beaten flag bit, TRAINER_FLAGS_START+id).
-- name must be the trainer's FULL internal name, not just a recognizable
-- substring — "SURGE" alone never matches anything (his real name is
-- "LT. SURGE" and the struct's name field starts at "LT.", not "SURGE");
-- every entry below was read directly out of a real ROM to confirm both
-- the id and the exact name, not assumed from memory.
--
-- BPEE (Emerald) verified against Roxanne's story team = Geodude/Geodude
-- L12, Nosepass L15 (matches published data). Champion is Wallace.
--
-- BPRE/BPGE (FireRed/LeafGreen) verified against a real FireRed ROM, full
-- level progression 14/21/24/29/43/43/47/50/54/56/58/60 — sane monotonic
-- gym→E4 curve. No champion entry: FRLG's champion is the player's
-- rival, whose stored trainer name is chosen per-save and can't be
-- name-matched reliably. Giovanni needed the id-based path specifically:
-- his name also appears on two much-weaker Team Rocket boss fights
-- (Hideout/Silph Co, L20s-30s) that a plain "lowest level wins" name
-- search picks by mistake over his real L50 gym battle.
--
-- AXVE/AXPE (Ruby/Sapphire): not yet verified against a real ROM.
local STAGES = {
	BPEE = {
		{ key = "gym1", label = "G1", name = "ROXANNE", id = 265 },
		{ key = "gym2", label = "G2", name = "BRAWLY", id = 266 },
		{ key = "gym3", label = "G3", name = "WATTSON", id = 267 },
		{ key = "gym4", label = "G4", name = "FLANNERY", id = 268 },
		{ key = "gym5", label = "G5", name = "NORMAN", id = 269 },
		{ key = "gym6", label = "G6", name = "WINONA", id = 270 },
		{ key = "gym7", label = "G7", name = "TATE", id = 271 },
		{ key = "gym8", label = "G8", name = "JUAN", id = 272 },
		{ key = "e4_1", label = "E1", name = "SIDNEY", id = 261 },
		{ key = "e4_2", label = "E2", name = "PHOEBE", id = 262 },
		{ key = "e4_3", label = "E3", name = "GLACIA", id = 263 },
		{ key = "e4_4", label = "E4", name = "DRAKE", id = 264 },
		{ key = "champ", label = "CH", name = "WALLACE", id = 335 },
	},
	BPRE = {
		{ key = "gym1", label = "G1", name = "BROCK", id = 414 },
		{ key = "gym2", label = "G2", name = "MISTY", id = 415 },
		{ key = "gym3", label = "G3", name = "LT. SURGE", id = 416 },
		{ key = "gym4", label = "G4", name = "ERIKA", id = 417 },
		{ key = "gym5", label = "G5", name = "KOGA", id = 418 },
		{ key = "gym6", label = "G6", name = "SABRINA", id = 420 },
		{ key = "gym7", label = "G7", name = "BLAINE", id = 419 },
		{ key = "gym8", label = "G8", name = "GIOVANNI", id = 350 },
		{ key = "e4_1", label = "E1", name = "LORELEI", id = 410 },
		{ key = "e4_2", label = "E2", name = "BRUNO", id = 411 },
		{ key = "e4_3", label = "E3", name = "AGATHA", id = 412 },
		{ key = "e4_4", label = "E4", name = "LANCE", id = 413 },
	},
}
STAGES.BPGE = STAGES.BPRE -- LeafGreen shares FireRed's trainer table 1:1
gen3.STAGES = STAGES

function gen3.isTrainerBeaten(game, trainerId)
	local sb1 = saveBlocks(game)
	if not sb1 then return false end
	local flagsBase = sb1 + game.flagsOfs
	local f = (game.trainerFlag or 0x500) + trainerId
	local ok, byte = pcall(function() return emu:read8(flagsBase + (f >> 3)) end)
	return ok and byte and (byte & (1 << (f & 7))) ~= 0
end

-- full-ROM name scan, picking the WEAKEST matching encounter (assumes the
-- lowest-level hit is the real story battle, not a rematch). This breaks
-- down when a name has multiple unrelated encounters at wildly different
-- points in the story (FireRed's Giovanni) — locateStageBoss only falls
-- back to this after trying precise id-based addressing first.
local function scanForBossByName(stageName)
	local pattern = encodeName(stageName)
	local CHUNK = 0x40000
	local overlap = #pattern - 1
	local bestLevel, bestBase = nil, nil
	for base = 0, 0x00FFFFFF, CHUNK do
		local ok, data = pcall(function()
			return emu:readRange(0x08000000 + base, CHUNK + overlap)
		end)
		if not ok or not data then
			ok, data = pcall(function() return emu:readRange(0x08000000 + base, CHUNK) end)
			if not ok or not data then break end
		end
		local pos = 0
		while true do
			pos = data:find(pattern, pos + 1, true)
			if not pos or pos > CHUNK then break end
			local structBase = base + pos - 1 - 4
			local lvl = tryDecodeBossParty(structBase)
			if lvl and (not bestLevel or lvl < bestLevel) then
				bestLevel, bestBase = lvl, structBase
			end
		end
	end
	return bestBase, bestLevel
end

-- does the Trainer struct at structBase have exactly this name? Used to
-- sanity-check a direct-addressed candidate before trusting it.
local function verifyBossAt(structBase, expectedName)
	local ok, raw = pcall(function() return emu:readRange(0x08000000 + structBase, 16) end)
	if not ok or not raw or #raw < 16 then return false end
	return gen3.decodeText(raw:sub(5, 16)) == expectedName
end

-- resolves (and caches, per ROM checksum) a single stage's boss max level.
--
-- Two strategies, in order:
--  1. Direct gTrainers[] addressing from a cached table-start anchor
--     (tableStart + id*40, verified by name match before trusting it).
--     Exact — no ambiguity even when a name has multiple encounters.
--  2. Full-ROM name scan picking the weakest match (only reached if no
--     anchor exists yet, or the anchor's math doesn't check out for this
--     particular id — e.g. a ROM hack reordered the table).
-- The first successful resolution of ANY stage establishes the anchor for
-- every stage after it, so in practice only one full-ROM scan ever runs
-- per playthrough — the rest resolve instantly.
function gen3.locateStageBoss(game, stageKey, bucket)
	game.bossCaps = game.bossCaps or {}
	if game.bossCaps[stageKey] then return game.bossCaps[stageKey] end
	local stages = STAGES[game.code]
	if not stages then return nil end
	local stage
	for _, s in ipairs(stages) do
		if s.key == stageKey then stage = s; break end
	end
	if not stage then return nil end

	local cacheKey = "boss2_" .. game.code .. "_" .. gen3.romIdent(game) .. "_" .. stageKey
	local cachedLvl
	pcall(function()
		local v = bucket and bucket[cacheKey]
		if type(v) == "number" then cachedLvl = v end
	end)
	if cachedLvl then
		game.bossCaps[stageKey] = { id = stage.id, maxLevel = cachedLvl, label = stage.label }
		return game.bossCaps[stageKey]
	end

	local level = nil
	local anchorKey = "tblstart_" .. game.code .. "_" .. gen3.romIdent(game)
	local tableStart
	pcall(function()
		local v = bucket and bucket[anchorKey]
		if type(v) == "number" then tableStart = v end
	end)
	if not tableStart then
		local anchorBase, anchorLevel = scanForBossByName(stage.name)
		if anchorBase then
			tableStart = anchorBase - stage.id * 40
			if bucket then bucket[anchorKey] = tableStart end
			level = anchorLevel -- already decoded this exact stage while anchoring
		end
	end
	if not level and tableStart then
		local candidateBase = tableStart + stage.id * 40
		if verifyBossAt(candidateBase, stage.name) then
			level = tryDecodeBossParty(candidateBase)
		end
	end
	if not level then
		local _, lvl = scanForBossByName(stage.name)
		level = lvl
	end

	if not level then return nil end
	if bucket then bucket[cacheKey] = level end
	game.bossCaps[stageKey] = { id = stage.id, maxLevel = level, label = stage.label }
	return game.bossCaps[stageKey]
end

-- first not-yet-beaten stage, or nil once every stage is cleared
function gen3.currentStage(game, bucket)
	local stages = STAGES[game.code]
	if not stages then return nil end
	for _, s in ipairs(stages) do
		if not gen3.isTrainerBeaten(game, s.id) then
			return gen3.locateStageBoss(game, s.key, bucket)
		end
	end
	return nil
end

-- ========================================================================
-- Party decoding
-- ========================================================================
-- Substructure orders (Growth/Attacks/EVs/Misc) by personality % 24:
-- value at index = position of that block in stored data
local SUBSTRUCT_ORDER = {
	"GAEM","GAME","GEAM","GEMA","GMAE","GMEA",
	"AGEM","AGME","AEGM","AEMG","AMGE","AMEG",
	"EGAM","EGMA","EAGM","EAMG","EMGA","EMAG",
	"MGAE","MGEA","MAGE","MAEG","MEGA","MEAG",
}

local function decodeMon(raw)
	local personality = string.unpack("<I4", raw, 1)
	local otId = string.unpack("<I4", raw, 5)
	if personality == 0 and otId == 0 then return nil end
	local nickname = gen3.decodeText(raw:sub(9, 18))

	-- decrypt the 48-byte data section (offset 32, 12 x u32 XOR key)
	local key = personality ~ otId
	local words = {}
	local sum = 0
	for i = 0, 11 do
		local w = string.unpack("<I4", raw, 33 + i * 4) ~ key
		words[i] = w
		sum = sum + (w & 0xFFFF) + (w >> 16)
	end
	-- substructure checksum guards against reading garbage RAM (ROM hacks
	-- with shifted memory layouts) — reject anything that doesn't verify
	local checksum = string.unpack("<I2", raw, 29)
	if (sum & 0xFFFF) ~= checksum then return nil end
	local order = SUBSTRUCT_ORDER[(personality % 24) + 1]
	local gPos = order:find("G") - 1 -- block index 0-3
	local mPos = order:find("M") - 1
	local growth0 = words[gPos * 3]
	local misc1 = words[mPos * 3 + 1] -- IVs/egg/ability word
	local species = growth0 & 0xFFFF
	local isEgg = (misc1 & 0x40000000) ~= 0

	local status = string.unpack("<I4", raw, 81)
	local level = raw:byte(85)
	local hp = string.unpack("<I2", raw, 87)
	local maxHP = string.unpack("<I2", raw, 89)

	local cond = nil
	if hp == 0 then cond = "FNT"
	elseif (status & 0x07) ~= 0 then cond = "SLP"
	elseif (status & 0x08) ~= 0 then cond = "PSN"
	elseif (status & 0x10) ~= 0 then cond = "BRN"
	elseif (status & 0x20) ~= 0 then cond = "FRZ"
	elseif (status & 0x40) ~= 0 then cond = "PAR"
	elseif (status & 0x80) ~= 0 then cond = "TOX"
	end

	return {
		personality = personality, otId = otId,
		nickname = nickname, species = species, isEgg = isEgg,
		level = level, hp = hp, maxHP = maxHP, cond = cond,
	}
end

function gen3.readParty(game)
	local ok, count = pcall(function() return emu:read8(game.partyCount) end)
	if not ok or not count or count == 0 or count > 6 then return {} end
	local party = {}
	for i = 0, count - 1 do
		local okR, raw = pcall(function() return emu:readRange(game.party + i * 100, 100) end)
		if okR and raw and #raw == 100 then
			local mon = decodeMon(raw)
			if mon then
				mon.speciesName = mon.isEgg and "EGG" or gen3.speciesName(game, mon.species)
				mon.type1, mon.type2 = gen3.speciesTypes(game, mon.species)
				party[#party + 1] = mon
			end
		end
	end
	return party
end

return gen3
