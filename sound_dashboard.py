#!/usr/bin/env python3
"""Sound dashboard for PokéParty — audition every current sound file by
game event, using the same `paplay` path party-hud.lua uses."""

import os
import subprocess
import tkinter as tk
from tkinter import ttk

SOUND_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "sounds")

# (event label, [files]) — grouped to match audio.lua/party-hud.lua's
# actual trigger mapping, not just alphabetical file order
EVENTS = [
    ("SHOT", ["shot1.wav", "shot2.wav"]),
    ("DRINK", ["drink1.wav", "drink2.wav", "drink3.wav"]),
    ("REVIVE", ["revive1.wav"]),
    ("FAINT", ["faint1.wav", "faint2.wav", "faint3.wav", "faint4.wav", "faint5.wav"]),
    ("WHITE OUT (lose battle)", ["whiteout.wav"]),
    ("UNWIRED (not currently played anywhere)", ["important1.wav", "important2.wav", "important3.wav", "important4.wav"]),
    ("GYM BEATEN", ["badge.wav"]),
    ("WHEEL: bad outcome", ["badwheel1.wav", "badwheel2.wav", "badwheel3.wav", "badwheel4.wav"]),
    ("WHEEL: good outcome", ["cheer.wav", "partyblower_l.wav", "partyblower_r.wav"]),
    ("WHEEL: tick", ["tick.wav"]),
    ("DANGER MUSIC (low HP)", ["danger1.wav", "danger2.wav"]),
]

VOLUME_PCT = 55  # matches audio.lua's current default


def play(filename):
    path = os.path.join(SOUND_DIR, filename)
    if not os.path.isfile(path):
        print(f"missing: {path}")
        return
    vol = int(65536 * VOLUME_PCT / 100)
    subprocess.Popen(
        ["paplay", f"--volume={vol}", path],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )


def stop_all():
    subprocess.run(["pkill", "-x", "paplay"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def build_ui():
    root = tk.Tk()
    root.title("PokéParty Sound Dashboard")
    root.geometry("420x600")

    header = ttk.Label(root, text="PokéParty Sounds", font=("", 14, "bold"))
    header.pack(pady=(10, 0))
    sub = ttk.Label(root, text=f"playback at {VOLUME_PCT}% (matches game default)")
    sub.pack(pady=(0, 10))

    stop_btn = ttk.Button(root, text="STOP ALL", command=stop_all)
    stop_btn.pack(pady=(0, 10))

    canvas = tk.Canvas(root, borderwidth=0)
    frame = ttk.Frame(canvas)
    scrollbar = ttk.Scrollbar(root, orient="vertical", command=canvas.yview)
    canvas.configure(yscrollcommand=scrollbar.set)
    scrollbar.pack(side="right", fill="y")
    canvas.pack(side="left", fill="both", expand=True)
    canvas.create_window((0, 0), window=frame, anchor="nw")
    frame.bind("<Configure>", lambda e: canvas.configure(scrollregion=canvas.bbox("all")))

    for label, files in EVENTS:
        section = ttk.LabelFrame(frame, text=label, padding=8)
        section.pack(fill="x", padx=10, pady=6)
        for f in files:
            row = ttk.Frame(section)
            row.pack(fill="x", pady=2)
            ttk.Label(row, text=f, width=22).pack(side="left")
            ttk.Button(row, text="▶ Play", command=lambda f=f: play(f)).pack(side="left")

    root.mainloop()


if __name__ == "__main__":
    build_ui()
