# Setting up PokéParty on a new machine (Linux)

Assumes an apt-based distro (Ubuntu/Debian/Mint etc.) like the machine this
was built on. If your laptop uses a different package manager, swap the
`apt install` line (in `deps:` in the Makefile, or step 2 below) for your
distro's equivalent — package names are close to identical everywhere.

## The fast way

```sh
git clone https://github.com/ryanjakegarcia/PokeParty.git ~/PokePartymGBA
cd ~/PokePartymGBA
make setup
```

That's it — `make setup` runs everything in steps 2-4 below (installs
deps, clones + patches + builds mGBA, sets the display config). Every step
checks whether it's already done before doing it again, so it's safe to
run more than once (e.g. after a `git pull` picks up a Makefile change).
`make help` lists the individual steps if you want to run just one, and
`make run ROM=/path/to/game.gba` launches once set up.

Steps 1-4 below are what `make setup` does under the hood, spelled out for
reference or if you'd rather run them by hand.

## 1. Clone this repo

```sh
git clone https://github.com/ryanjakegarcia/PokeParty.git ~/PokePartymGBA
```

## 2. Install build dependencies

```sh
sudo apt install -y qt6-base-dev qt6-multimedia-dev libsdl2-dev liblua5.4-dev \
  libelf-dev libepoxy-dev libsqlite3-dev libzip-dev libpng-dev libjson-c-dev \
  cmake ninja-build git
```

## 3. Build patched mGBA from source

The upstream mGBA release doesn't have the high-resolution overlay patch
this HUD needs (see `mgba-patches/`), so we build mGBA's `master` branch
ourselves with that patch applied. Takes a few minutes.

```sh
git clone --depth 1 https://github.com/mgba-emu/mgba.git ~/mgba-master
cd ~/mgba-master
git apply ~/PokePartymGBA/mgba-patches/0001-hires-canvas-layers.patch
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DSKIP_GIT=ON
ninja -C build mgba-qt
```

`-DSKIP_GIT=ON` works around a CMake error on shallow clones (no full tag
history to compute a version string from) — harmless, just affects the
version string mGBA reports.

Verify the build worked:

```sh
~/mgba-master/build/qt/mgba-qt --version
```

Should print something like `0.11-1-<hash>`. If instead you get a build
error, the patch likely doesn't apply cleanly against whatever the current
mGBA `master` looks like — check `mgba-patches/0001-hires-canvas-layers.patch`
against the current `src/script/canvas.c` and reapply by hand if needed.

## 4. Enable the OpenGL display + high-resolution scale

The HUD needs mGBA's OpenGL display driver with 4x internal scale, or the
hi-res overlay patch has nothing to render into (GL composites overlays
through an internal framebuffer sized to `videoScale`, so without this the
panel silently falls back to blurry/low-res). Run mGBA once first so it
creates its config file, then either:

- **In-app**: Settings → Display → Driver → OpenGL, then
  Settings → Enhancements → High-resolution scale → 4, or
- **Directly edit** `~/.config/mgba/config.ini` and `~/.config/mgba/qt.ini`:
  ```ini
  # config.ini
  hwaccelVideo=1
  videoScale=4
  ```
  ```ini
  # qt.ini
  displayDriver=1
  ```

## 5. Bring your ROMs and saves

ROMs/saves are never checked into this repo. Copy over whatever `.gba`/
`.sav` files you were using, anywhere on disk.

## 6. Launch

```sh
~/PokePartymGBA/pokemgba /path/to/your/rom.gba
# or, equivalently:
make run ROM=/path/to/your/rom.gba
```

`pokemgba` hardcodes `~/mgba-master/build/qt/mgba-qt` as the emulator path —
if you cloned mGBA somewhere else, edit that one line in the script.

### Useful env vars (all optional)

| Var | Default | Purpose |
|---|---|---|
| `POKEPARTY_HUD_SCALE` | 4 | Side panel / strip backing-image upscale factor |
| `POKEPARTY_STRIP_H` | 24 | Top/bottom strip height (24 = tuned for 1080p fullscreen) |
| `POKEPARTY_BADGE_COLORS` | color | Badge color mode ('color' = stylized, 'silver' = in-game accurate) |
| `POKEPARTY_CANDY` | 99 | Rare Candy cheat target count (0 disables) |
| `POKEPARTY_CANDY_KEY` | c | Keyboard hotkey for Rare Candy cheat (single character) |
| `POKEPARTY_CANDY_PAD` | unset | Gamepad button number for Rare Candy cheat |
| `POKEPARTY_SOUND` | 1 | Enable sound effects (0 = disable) |
| `POKEPARTY_SFX_VOLUME` | 80 | Sound effect volume (0-100 percent) |
| `POKEPARTY_DEBUG` | unset | Dir path — writes `pokeparty.log` + panel/strip PNG snapshots |

## Troubleshooting

- **HUD text looks pixelated/blurry**: `videoScale` isn't set to 4, or
  display driver isn't OpenGL (step 4).
- **No panel/strips at all, just the game**: check `mgba-qt --version`
  actually reports the patched build (not a system-installed mGBA on PATH —
  `pokemgba` always uses the explicit `~/mgba-master/...` path so this
  shouldn't happen via the wrapper, but matters if launching mGBA some
  other way).
- **Panel shows "No supported game"**: only Gen 3 (Ruby/Sapphire/
  FireRed/LeafGreen/Emerald, US versions) is supported.
