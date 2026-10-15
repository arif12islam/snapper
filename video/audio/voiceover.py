"""Generates the narration with Kokoro (open-weight TTS, Apache 2.0), one clip per line.

Needs: pip install kokoro-onnx soundfile, plus the model files from
https://github.com/thewh1teagle/kokoro-onnx/releases (kokoro-v1.0.onnx, voices-v1.0.bin).
Set KOKORO_DIR to the folder that holds them.

    KOKORO_DIR=~/tts python3 audio/voiceover.py

The script and its cue points live in src/timeline.json under "voice":
each line has "at" = [scene start frame, frame within the scene] and "until" = the
latest frame (within the same scene) the line may run to.

Writes audio/vo/<n>.wav, audio/vo/lines.json and the site captions file.
"""
import json
import os

import numpy as np
import soundfile as sf
from kokoro_onnx import Kokoro

HERE = os.path.dirname(os.path.abspath(__file__))
TL = json.load(open(os.path.join(HERE, '..', 'src', 'timeline.json')))
FPS = TL['fps']
MODEL_DIR = os.path.expanduser(os.environ.get('KOKORO_DIR', '~/tts'))

kokoro = Kokoro(os.path.join(MODEL_DIR, 'kokoro-v1.0.onnx'), os.path.join(MODEL_DIR, 'voices-v1.0.bin'))

# A deep narrator: mostly am_onyx (the lowest male voice, about 89 Hz) with some
# am_michael (the clearest male voice) blended in. Lands around 96 Hz.
VOICE_NAME = 'onyx 70 / michael 30'
VOICE = 0.7 * kokoro.get_voice_style('am_onyx') + 0.3 * kokoro.get_voice_style('am_michael')
BASE_SPEED = 0.94   # a touch slower than normal, for weight
MAX_SPEED = 1.12

out_dir = os.path.join(HERE, 'vo')
os.makedirs(out_dir, exist_ok=True)
for name in os.listdir(out_dir):
    if name.endswith('.wav'):
        os.remove(os.path.join(out_dir, name))


def trim(x, sr, floor=0.008):
    idx = np.where(np.abs(x) > floor)[0]
    if len(idx) == 0:
        return x
    a = max(0, idx[0] - int(0.02 * sr))
    b = min(len(x), idx[-1] + int(0.08 * sr))
    return x[a:b]


lines = []
for n, cue in enumerate(TL['voice']):
    scene, local = cue['at']
    start = (scene + local) / FPS
    slot = (cue['until'] - local) / FPS
    speed = BASE_SPEED
    for _ in range(8):
        audio, sr = kokoro.create(cue['text'], voice=VOICE, speed=speed, lang='en-us')
        audio = trim(np.asarray(audio, dtype=np.float32), sr)
        dur = len(audio) / sr
        if dur <= slot or speed >= MAX_SPEED:
            break
        speed = min(MAX_SPEED, speed * dur / slot * 1.02)
    sf.write(os.path.join(out_dir, f'{n}.wav'), audio, sr)
    lines.append({'n': n, 'start': round(start, 3), 'slot': round(slot, 2), 'dur': round(dur, 2),
                  'speed': round(speed, 2), 'sr': sr, 'text': cue['text']})
    flag = '' if dur <= slot else '  OVER'
    print(f"{n:2d} @{start:6.2f}s  {dur:4.2f}s of {slot:4.2f}s at {speed:.2f}x  {cue['text']}{flag}")

json.dump({'voice': VOICE_NAME, 'lines': lines}, open(os.path.join(out_dir, 'lines.json'), 'w'), indent=2)


# Captions for the site. Short lines that follow each other closely are merged into one cue.
def stamp(t):
    m, s = divmod(t, 60)
    return f'00:{int(m):02d}:{s:06.3f}'


cues = []
for line in lines:
    a, b = line['start'], line['start'] + line['dur']
    if cues and a - cues[-1][1] < 0.45 and len(cues[-1][2]) + len(line['text']) < 60:
        cues[-1] = (cues[-1][0], b, cues[-1][2] + ' ' + line['text'])
    else:
        cues.append((a, b, line['text']))
vtt = ['WEBVTT', '']
for a, b, text in cues:
    vtt += [f'{stamp(a)} --> {stamp(b + 0.3)}', text.replace('...', '…'), '']
with open(os.path.join(HERE, '..', '..', 'site', 'media', 'snapper-explainer.vtt'), 'w') as fh:
    fh.write('\n'.join(vtt))
print(f'{len(cues)} caption cues written')
