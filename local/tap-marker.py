#!/usr/bin/env python3
"""Draw a ring where the agent tapped, on a screen recording of a run.

    python3 local/tap-marker.py run.log recording.mov out.mov --start <epoch seconds when recording began>
        [--screen x,y,w,h]   # where the phone's screen sits in the video (DeviceHub framed recordings)
        [--phone 1206x2622]  # the phone's screenshot size, which the logged tap points use

run.log holds the app's console output; each touch is a line "AGENT_TAP <epoch> <x> <y>" (OnDeviceController.tap).
Without --screen the whole video is the phone screen (simctl recordings). Needs ffmpeg and Pillow.
"""

import argparse
import re
import subprocess
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw

parser = argparse.ArgumentParser()
parser.add_argument("log")
parser.add_argument("video")
parser.add_argument("out")
parser.add_argument("--start", type=float, required=True)
parser.add_argument("--screen", default="")
parser.add_argument("--phone", default="1206x2622")
parser.add_argument("--fps", type=int, default=30)
args = parser.parse_args()

taps = [(float(t) - args.start, int(x), int(y))
        for t, x, y in re.findall(r"AGENT_TAP (\d+\.\d+) (-?\d+) (-?\d+)", Path(args.log).read_text())]
taps = [t for t in taps if t[0] >= 0]
print(f"{len(taps)} taps")
pw, ph = map(int, args.phone.split("x"))
SHOW = 0.6  # seconds a ring stays, shrinking and fading

with tempfile.TemporaryDirectory() as work:
    frames = Path(work)
    subprocess.run(["ffmpeg", "-loglevel", "error", "-i", args.video, "-vf", f"fps={args.fps}", str(frames / "f_%05d.png")], check=True)
    files = sorted(frames.glob("f_*.png"))
    first = Image.open(files[0])
    sx, sy, sw, sh = map(int, args.screen.split(",")) if args.screen else (0, 0, first.width, first.height)
    for i, path in enumerate(files):
        t = i / args.fps
        live = [(t - at, x, y) for at, x, y in taps if 0 <= t - at < SHOW]
        if not live:
            continue
        img = Image.open(path).convert("RGBA")
        layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
        draw = ImageDraw.Draw(layer)
        for age, x, y in live:
            cx, cy = sx + x * sw / pw, sy + y * sh / ph
            r = sw * (0.045 - 0.02 * age / SHOW)
            alpha = int(220 * (1 - age / SHOW))
            draw.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(255, 255, 255, alpha // 3), outline=(30, 120, 255, alpha), width=max(2, int(sw / 120)))
        Image.alpha_composite(img, layer).convert("RGB").save(path)
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-framerate", str(args.fps), "-i", str(frames / "f_%05d.png"),
                    "-c:v", "libx264", "-crf", "12", "-preset", "slow", "-pix_fmt", "yuv420p", "-movflags", "+faststart", args.out], check=True)
print(f"wrote {args.out}")
