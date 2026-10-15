"""Generates the narration with Kokoro (open-weight TTS, Apache 2.0), one clip per line.

Needs: pip install kokoro-onnx soundfile, plus the model files from
https://github.com/thewh1teagle/kokoro-onnx/releases (kokoro-v1.0.onnx, voices-v1.0.bin).
Set KOKORO_DIR to the folder that holds them.

    KOKORO_DIR=~/tts python3 audio/voiceover.py [voice]

Writes audio/vo/<n>.wav and audio/vo/lines.json (start time and duration for each line).
"""
import json
import os
import sys

import numpy as np
import soundfile as sf
from kokoro_onnx import Kokoro

HERE = os.path.dirname(os.path.abspath(__file__))
MODEL_DIR = os.path.expanduser(os.environ.get('KOKORO_DIR', '~/tts'))
VOICE = sys.argv[1] if len(sys.argv) > 1 else 'af_heart'

# (start seconds, latest end seconds, text). Starts follow the scene cuts (30 fps, 120 BPM).
SCRIPT = [
    (0.35, 3.95, 'A screenshot rarely explains itself.'),
    (4.25, 7.85, 'Meet Snapper. Capture, annotate and share from your menu bar.'),
    (8.15, 10.75, 'Press a shortcut and grab any part of your screen.'),
    (11.0, 16.4, 'Then mark it up. Boxes, arrows, numbered steps, a magnifier, and blur.'),
    (16.6, 18.85, 'Give it a background.'),
    (19.0, 20.9, 'Then copy it, or share a link.'),
    (21.25, 24.9, 'Paste it anywhere, and everyone gets the point.'),
    (25.15, 27.9, 'Need motion? Record, trim, and send.'),
    (30.05, 31.7, 'Snapper. Invite only.'),
]

kokoro = Kokoro(os.path.join(MODEL_DIR, 'kokoro-v1.0.onnx'), os.path.join(MODEL_DIR, 'voices-v1.0.bin'))
out_dir = os.path.join(HERE, 'vo')
os.makedirs(out_dir, exist_ok=True)


def trim(x, sr, floor=0.008):
    idx = np.where(np.abs(x) > floor)[0]
    if len(idx) == 0:
        return x
    a = max(0, idx[0] - int(0.02 * sr))
    b = min(len(x), idx[-1] + int(0.06 * sr))
    return x[a:b]


lines = []
for n, (start, end, text) in enumerate(SCRIPT):
    slot = end - start
    speed = 1.0
    for _ in range(8):
        audio, sr = kokoro.create(text, voice=VOICE, speed=speed, lang='en-us')
        audio = trim(np.asarray(audio, dtype=np.float32), sr)
        dur = len(audio) / sr
        if dur <= slot or speed >= 1.35:
            break
        speed = min(1.35, speed * dur / slot * 1.02)
    path = os.path.join(out_dir, f'{n}.wav')
    sf.write(path, audio, sr)
    lines.append({'n': n, 'start': start, 'slot': round(slot, 2), 'dur': round(dur, 2), 'speed': round(speed, 2), 'sr': sr, 'text': text})
    flag = '' if dur <= slot else '  OVER'
    print(f'{n}: {dur:5.2f}s of {slot:4.2f}s at {speed:.2f}x  {text}{flag}')

json.dump({'voice': VOICE, 'lines': lines}, open(os.path.join(out_dir, 'lines.json'), 'w'), indent=2)


# Captions for the site, from the same timings.
def stamp(t):
    m, s = divmod(t, 60)
    return f'00:{int(m):02d}:{s:06.3f}'


vtt = ['WEBVTT', '']
for line in lines:
    vtt.append(f"{stamp(line['start'])} --> {stamp(line['start'] + line['dur'] + 0.3)}")
    vtt.append(line['text'])
    vtt.append('')
with open(os.path.join(HERE, '..', '..', 'site', 'media', 'snapper-explainer.vtt'), 'w') as fh:
    fh.write('\n'.join(vtt))
