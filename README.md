# PokéParty mGBA

A party HUD for mGBA: docks a live panel beside the game screen showing your
current party (nickname, level, HP, status), badge count, Pokédex caught/seen,
and a persistent faint counter.

Everything runs inside mGBA's Lua scripting engine — no second app, no extra
windows.

![panel docks right of the game screen]

## Requirements

- mGBA **0.11+** (scripting canvas API) with our `newLayer` upscale patch
  (`src/script/canvas.c`). Build lives at `~/mgba-master/build/qt/mgba-qt`.
- A Gen 3 Pokémon game (US): Ruby, Sapphire, FireRed, LeafGreen, Emerald.
- For the high-resolution HUD on the OpenGL display driver:
  `hwaccelVideo=1` + `videoScale=4` in mGBA's config (Settings →
  Enhancements → High-resolution scale). Without it, GL's intermediate
  framebuffer averages the hi-res panel back down to GBA resolution.
  `POKEPARTY_HUD_SCALE=n` (default 4, 1-8) controls the panel's backing
  resolution; the script falls back to 1× on an unpatched mGBA.

## Usage

```sh
./pokemgba path/to/rom.gba
```

or manually:

```sh
mgba-qt --script party-hud.lua rom.gba
```

The panel docks to the right of the game. Resize the window freely — the
whole canvas scales together.

## Files

- `party-hud.lua` — entry point: canvas panel, faint tracking, wiring
- `gen3.lua` — Gen 3 decoding: game detection, party decryption, badges,
  Pokédex flags, ROM table discovery (species names/types found by
  byte-pattern scan, cached via mGBA script storage)
- `pokemgba` — launcher wrapper

## How it works

- Game detected from the 4-byte game code at `0x080000AC`.
- Party read from `gPlayerParty`; the 48-byte encrypted section is decrypted
  with `personality ^ otId` and the `personality % 24` substructure order.
- Badges/Pokédex read via SaveBlock pointers (FRLG/Emerald ASLR) or fixed
  addresses (Ruby/Sapphire).
- Faints aren't stored by the games — the script watches party HP
  transitions and persists its own counter per game+trainer ID.
- Species names and types are read out of the ROM itself, located by
  scanning for Bulbasaur's known bytes, so no giant data tables in Lua.
- Randomizer/ROM-hack friendly: the base stats table is found via growth
  rate + egg group bytes (fields randomizers and QoL hacks leave alone),
  table locations are cached per ROM checksum, and every party slot must
  pass the Gen 3 substructure checksum before display — shifted RAM layouts
  show an empty party instead of garbage. Verified against UPR ZX
  randomized Emerald and a rebuilt pokeemerald hack.

## Drunklocke mode

Header shows `D:n S:n` (drinks/shots), persisted per save. Auto rules:

| Event | Effect | Detection |
|---|---|---|
| Catch a Pokémon | +1 drink | Pokédex owned count |
| Beat a trainer | +1 drink | per-trainer defeat flags (0x500+) |
| Beat a gym | +1 shot + wheel spin | badge count |
| Pokémon faints | +1 shot | party HP transition |
| ★Important Pokémon faints | +2 shots | marked via hotkey |

Hotkeys: **R** = rival beaten (+1 shot, manual — rival battles aren't
reliably detectable across randomizers), **I** = toggle ★important on the
lead party mon (persisted), **W** = spin the wheel manually.

Manual counter correction (for a tracking bug or a new house-rule invented
mid-run): **[** / **]** = drink -1 / +1, **;** / **'** = shot -1 / +1,
**,** / **.** = revive -1 / +1. Left of each pair decrements, right
increments; every press flashes a confirmation banner and persists through
the normal save-gated commit like any other counter change.

The wheel (auto after each gym) is a hi-res disc centered over the game:
spinning arrow, decaying spin (~4s), result banner for 5s. Edit
`wheel.SEGMENTS` at the top of `wheel.lua` for house rules — wedges with
`drinks=`/`shots=` fields feed the counters when landed. Save-state
rewinds resync counters instead of double-counting.

## Cheats

Press **C** to top the items pocket up to 99 Rare Candies. The button strip
at the bottom of the panel shows the hotkey; it flashes on use.

- `POKEPARTY_CANDY=n` — target quantity (0 disables the cheat entirely)
- `POKEPARTY_CANDY_KEY=r` — different keyboard key
- `POKEPARTY_CANDY_PAD=n` — also trigger from a gamepad button; press
  buttons with `POKEPARTY_DEBUG` set and read the logged numbers to find n

Writes respect Gen 3 bag encryption (security key XOR) and validate the
bag decodes sanely first — on ROM hacks with moved/expanded bags it logs
`bag layout mismatch` and refuses to write rather than corrupt the save.

Gotcha for future key handling: Qt delivers letter keys to scripts as
uppercase ASCII codepoints ('C' = 67, never 99).

## Debugging

```sh
POKEPARTY_DEBUG=/some/dir ./pokemgba rom.gba
```

Writes `pokeparty.log` and a `panel.png` snapshot of the HUD to that dir.

## Scripting API gotchas (for future work)

- Objects **returned from methods** (`canvas:newLayer`, `image.newPainter`)
  are strong references — safe to keep.
- Objects from **member access** (`layer.image`) are weakrefs that die at
  the next API call. Never store them; access inline.
- Layers must be created at script load scope.
- Canvas units are GBA screen pixels; the canvas grows to contain layers and
  the window scales the whole canvas. Keep layers small or the game shrinks.
