# PokéParty setup automation. Linux/apt-based distros.
#
#   make setup           full setup: deps, patched mGBA build, display config
#   make run ROM=x.gba   launch pokemgba with a ROM
#
# Every target is safe to re-run — each step checks whether it's already
# done before doing it again (idempotent), so `make setup` after a `git
# pull` just fills in whatever's new instead of erroring or rebuilding
# from scratch.

SHELL := /bin/bash
MGBA_DIR := $(HOME)/mgba-master
MGBA_BIN := $(MGBA_DIR)/build/qt/mgba-qt
PATCH := $(CURDIR)/mgba-patches/0001-hires-canvas-layers.patch
CONFIG_DIR := $(HOME)/.config/mgba

DEPS := qt6-base-dev qt6-multimedia-dev libsdl2-dev liblua5.4-dev \
        libelf-dev libepoxy-dev libsqlite3-dev libzip-dev libpng-dev \
        libjson-c-dev cmake ninja-build git pulseaudio-utils

.PHONY: help setup deps mgba-clone mgba-patch mgba-build config run clean

help:
	@echo "PokéParty setup"
	@echo ""
	@echo "  make setup           full setup: deps, patched mGBA build, display config"
	@echo "  make deps            install build dependencies (apt, needs sudo)"
	@echo "  make mgba-build      clone + patch + build mGBA only"
	@echo "  make config          apply mGBA display config (OpenGL driver, 4x hi-res scale)"
	@echo "  make run ROM=x.gba   launch pokemgba with the given ROM"
	@echo "  make clean           remove the mGBA build directory (forces a rebuild)"

setup: deps mgba-build config
	@echo ""
	@echo "Setup complete. Launch with:"
	@echo "  ./pokemgba /path/to/rom.gba"

deps:
	sudo apt-get update
	sudo apt-get install -y $(DEPS)

mgba-clone:
	@if [ -d "$(MGBA_DIR)" ]; then \
		echo "mGBA source already present at $(MGBA_DIR), skipping clone"; \
	else \
		git clone --depth 1 https://github.com/mgba-emu/mgba.git "$(MGBA_DIR)"; \
	fi

# detects the patch by its most distinctive change (the upscale parameter
# added to mScriptCanvasLayerCreate's signature) rather than trying to run
# `git apply` twice and parse whether it failed because it's already applied
# vs. failed for some other reason
mgba-patch: mgba-clone
	@if grep -q "int w, int h, int upscale" "$(MGBA_DIR)/src/script/canvas.c" 2>/dev/null; then \
		echo "hi-res canvas patch already applied"; \
	else \
		echo "applying hi-res canvas patch..."; \
		cd "$(MGBA_DIR)" && git apply "$(PATCH)"; \
	fi

mgba-build: mgba-patch
	cmake -S "$(MGBA_DIR)" -B "$(MGBA_DIR)/build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DSKIP_GIT=ON
	ninja -C "$(MGBA_DIR)/build" mgba-qt
	@echo -n "built: "; "$(MGBA_BIN)" --version

# mGBA needs to have run at least once to create its config dir; touch the
# files ourselves instead so `make config` works standalone, in any order
config:
	@mkdir -p "$(CONFIG_DIR)"
	@touch "$(CONFIG_DIR)/config.ini" "$(CONFIG_DIR)/qt.ini"
	@for kv in hwaccelVideo=1 videoScale=4; do \
		key=$${kv%%=*}; \
		if grep -q "^$$key=" "$(CONFIG_DIR)/config.ini" 2>/dev/null; then \
			sed -i "s/^$$key=.*/$$kv/" "$(CONFIG_DIR)/config.ini"; \
		else \
			echo "$$kv" >> "$(CONFIG_DIR)/config.ini"; \
		fi; \
	done
	@if grep -q "^displayDriver=" "$(CONFIG_DIR)/qt.ini" 2>/dev/null; then \
		sed -i "s/^displayDriver=.*/displayDriver=1/" "$(CONFIG_DIR)/qt.ini"; \
	else \
		echo "displayDriver=1" >> "$(CONFIG_DIR)/qt.ini"; \
	fi
	@echo "mGBA config updated: OpenGL display driver, 4x hi-res scale"

run:
	@if [ -z "$(ROM)" ]; then \
		echo "Usage: make run ROM=/path/to/game.gba"; \
		exit 1; \
	fi
	./pokemgba "$(ROM)"

clean:
	rm -rf "$(MGBA_DIR)/build"
