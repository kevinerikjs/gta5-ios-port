"""Flicker in a burst of frames (GTA-176): how many pixels blink, bright-dark-bright or dark-bright-dark over three
consecutive frames, in a still scene. Moving cars and people change a pixel one way and stay; a blink comes back.

    python3 Harness/flicker_score.py FRAMES_DIR PREFIX [--map OUT.png]

Frames are PREFIX-000.png, PREFIX-001.png… (the debug channel's "burst"). Each is shrunk to 320 wide and turned into
brightness; a blink needs a jump of 40 of 255 both ways. Prints blinks per frame and the share of the picture that
blinked at least once; --map saves where (white = often).
"""
import sys
from pathlib import Path
from PIL import Image

folder, prefix = Path(sys.argv[1]), sys.argv[2]
out = sys.argv[sys.argv.index('--map') + 1] if '--map' in sys.argv else None
files = sorted(folder.glob(f'{prefix}-[0-9][0-9][0-9].png'))
if len(files) < 3: raise SystemExit(f'{prefix}: {len(files)} frames')
frames = []
for f in files:
    im = Image.open(f).convert('L')
    w = 320; h = max(1, round(im.height * w / im.width))
    frames.append(im.resize((w, h), Image.BOX).tobytes())
w = 320; h = len(frames[0]) // w
JUMP = 40
counts = [0] * (w * h)
blinks = 0
for t in range(1, len(frames) - 1):
    a, b, c = frames[t - 1], frames[t], frames[t + 1]
    for i in range(w * h):
        x, y, z = a[i], b[i], c[i]
        if (y - x >= JUMP and y - z >= JUMP) or (x - y >= JUMP and z - y >= JUMP):
            counts[i] += 1; blinks += 1
blinked = sum(1 for n in counts if n)
print(f'{prefix}: {len(files)} frames, {blinks / (len(frames) - 2):.1f} blinking pixels per frame, '
      f'{100 * blinked / (w * h):.2f}% of the picture blinked at least once')
if out:
    top = max(counts) or 1
    Image.frombytes('L', (w, h), bytes(min(255, n * 255 // top) for n in counts)).save(out)
