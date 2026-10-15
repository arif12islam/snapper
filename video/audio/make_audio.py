"""Synthesizes the explainer soundtrack and sound effects.

Everything is generated from scratch (no samples), so the audio has no licensing strings attached.
The film runs at 30 fps and the music at 120 BPM, so one beat is exactly 15 frames.
Writes ../public/audio.wav (stereo, 44.1 kHz, 16 bit).

    python3 audio/make_audio.py
"""
import os
import numpy as np
from scipy.io import wavfile
from scipy.signal import butter, sosfilt, fftconvolve

SR = 44100
FPS = 30
BPM = 120
BEAT = 60 / BPM
BAR = BEAT * 4
LENGTH = 32.0
N = int(SR * LENGTH)
rng = np.random.default_rng(7)


def sec(frame):
    return frame / FPS


def midi(n):
    return 440.0 * 2 ** ((n - 69) / 12)


def lp(x, hz, order=2):
    return sosfilt(butter(order, hz, 'low', fs=SR, output='sos'), x)


def hp(x, hz, order=2):
    return sosfilt(butter(order, hz, 'high', fs=SR, output='sos'), x)


def bp(x, lo, hi, order=2):
    return sosfilt(butter(order, [lo, hi], 'band', fs=SR, output='sos'), x)


def env(n, attack=0.005, decay=0.3):
    t = np.arange(n) / SR
    a = np.clip(t / max(attack, 1e-4), 0, 1)
    return a * np.exp(-t / decay)


class Bus:
    def __init__(self):
        self.l = np.zeros(N)
        self.r = np.zeros(N)

    def add(self, t, sig, gain=1.0, pan=0.0):
        i = int(t * SR)
        if i >= N or i + len(sig) <= 0:
            return
        if i < 0:
            sig = sig[-i:]
            i = 0
        sig = sig[: N - i]
        gl = gain * np.cos((pan + 1) * np.pi / 4)
        gr = gain * np.sin((pan + 1) * np.pi / 4)
        self.l[i: i + len(sig)] += sig * gl
        self.r[i: i + len(sig)] += sig * gr


drums, bass, keys, pad, sfx, verb_send = Bus(), Bus(), Bus(), Bus(), Bus(), Bus()

# ------------------------------------------------------------------ instruments


def kick():
    n = int(0.45 * SR)
    t = np.arange(n) / SR
    f = 46 + 90 * np.exp(-t / 0.035)
    body = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t / 0.22)
    click = hp(rng.standard_normal(n), 3000) * np.exp(-t / 0.004) * 0.25
    return np.tanh((body + click) * 1.6) * 0.9


def hat(open_=False):
    n = int((0.25 if open_ else 0.06) * SR)
    x = hp(rng.standard_normal(n), 7500, 4)
    return x * env(n, 0.001, 0.08 if open_ else 0.018) * 0.5


def clap():
    n = int(0.3 * SR)
    t = np.arange(n) / SR
    noise = bp(rng.standard_normal(n), 900, 3200)
    e = np.zeros(n)
    for k, d in enumerate([0.0, 0.011, 0.022]):
        i = int(d * SR)
        e[i:] += np.exp(-(t[: n - i]) / (0.006 if k < 2 else 0.11))
    return noise * e * 0.6


def bass_note(note, length):
    n = int(length * SR)
    t = np.arange(n) / SR
    f = midi(note)
    x = np.sin(2 * np.pi * f * t) + 0.35 * np.sin(2 * np.pi * 2 * f * t) + 0.12 * np.sin(2 * np.pi * 3 * f * t)
    e = np.clip(t / 0.004, 0, 1) * np.exp(-t / 0.35) * np.clip((length - t) / 0.02, 0, 1)
    return lp(x * e, 900) * 0.55


def ep_note(note, length=1.2, bright=1.0):
    """Soft electric piano: a few decaying harmonics with a touch of tremolo."""
    n = int(length * SR)
    t = np.arange(n) / SR
    f = midi(note)
    x = (np.sin(2 * np.pi * f * t)
         + 0.45 * bright * np.sin(2 * np.pi * 2 * f * t) * np.exp(-t / 0.25)
         + 0.18 * bright * np.sin(2 * np.pi * 3 * f * t) * np.exp(-t / 0.12)
         + 0.05 * np.sin(2 * np.pi * 7.01 * f * t) * np.exp(-t / 0.03))
    trem = 1 + 0.08 * np.sin(2 * np.pi * 4.5 * t)
    return x * env(n, 0.003, 0.55) * trem * 0.18


def pad_chord(notes, length):
    n = int(length * SR)
    t = np.arange(n) / SR
    x = np.zeros(n)
    for note in notes:
        for det in (-0.08, 0.0, 0.08):
            f = midi(note + det)
            # Soft saw from a handful of harmonics, then low passed.
            for h in range(1, 6):
                x += np.sin(2 * np.pi * f * h * t + h) / h
    x = lp(x, 1400, 2)
    a = np.clip(t / 0.35, 0, 1)
    r = np.clip((length - t) / 0.4, 0, 1)
    return x * a * r * 0.018


def pluck(note, length=0.4):
    n = int(length * SR)
    t = np.arange(n) / SR
    f = midi(note)
    x = np.sign(np.sin(2 * np.pi * f * t)) * 0.4 + np.sin(2 * np.pi * f * t)
    return lp(x, 2600) * env(n, 0.002, 0.09) * 0.12


# ------------------------------------------------------------------ sound effects


def sfx_thump():
    n = int(0.35 * SR)
    t = np.arange(n) / SR
    f = 70 + 60 * np.exp(-t / 0.03)
    return np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t / 0.12) * 0.7


def sfx_marker(length):
    """Felt tip on glass: band passed noise with a scratchy wobble."""
    n = int(length * SR)
    t = np.arange(n) / SR
    x = bp(rng.standard_normal(n), 1800, 5200)
    wob = 0.6 + 0.4 * np.abs(np.sin(2 * np.pi * 9 * t))
    e = np.clip(t / 0.03, 0, 1) * np.clip((length - t) / 0.06, 0, 1)
    return x * wob * e * 0.16


def sfx_pop():
    n = int(0.18 * SR)
    t = np.arange(n) / SR
    f = 500 + 900 * (1 - np.exp(-t / 0.02))
    return np.sin(2 * np.pi * np.cumsum(f) / SR) * env(n, 0.002, 0.05) * 0.45


def sfx_whoosh(length, peak=0.7):
    n = int(length * SR)
    t = np.arange(n) / SR
    x = rng.standard_normal(n)
    # Sweep a band upward while the level swells toward the peak point.
    out = np.zeros(n)
    steps = 24
    for k in range(steps):
        a, b = k * n // steps, (k + 1) * n // steps
        center = 300 + 4000 * (k / steps) ** 2
        seg = bp(x, center * 0.7, center * 1.4)[a:b]
        out[a:b] = seg
    p = t / length
    e = np.where(p < peak, (p / peak) ** 2, np.exp(-(p - peak) / 0.08))
    return out * e * 0.35


def sfx_click():
    n = int(0.05 * SR)
    t = np.arange(n) / SR
    x = np.sin(2 * np.pi * 2400 * t) * np.exp(-t / 0.004) + hp(rng.standard_normal(n), 4000) * np.exp(-t / 0.002) * 0.6
    return x * 0.35


def sfx_tick():
    n = int(0.03 * SR)
    t = np.arange(n) / SR
    return hp(rng.standard_normal(n), 2500) * np.exp(-t / 0.004) * 0.22


def sfx_shutter():
    out = np.zeros(int(0.22 * SR))
    for d, g in ((0.0, 1.0), (0.085, 0.7)):
        n = int(0.07 * SR)
        t = np.arange(n) / SR
        x = bp(rng.standard_normal(n), 1500, 7000) * np.exp(-t / 0.012) * g
        i = int(d * SR)
        out[i: i + n] += x
    return out * 0.55


def sfx_shh(length):
    n = int(length * SR)
    t = np.arange(n) / SR
    x = bp(rng.standard_normal(n), 3000, 9000)
    e = np.sin(np.pi * np.clip(t / length, 0, 1))
    return x * e * 0.12


def sfx_chime(notes=(84, 91), gap=0.07):
    out = np.zeros(int(1.2 * SR))
    for k, note in enumerate(notes):
        n = int(1.0 * SR)
        t = np.arange(n) / SR
        f = midi(note)
        x = (np.sin(2 * np.pi * f * t) + 0.3 * np.sin(2 * np.pi * 2.76 * f * t) * np.exp(-t / 0.08)) * env(n, 0.002, 0.35)
        i = int(k * gap * SR)
        out[i: i + n] += x
    return out * 0.16


def sfx_msg():
    return sfx_chime((79, 86), 0.06) * 0.9


def sfx_beep():
    n = int(0.16 * SR)
    t = np.arange(n) / SR
    return np.sin(2 * np.pi * 1320 * t) * np.clip(t / 0.005, 0, 1) * np.clip((0.16 - t) / 0.02, 0, 1) * 0.16


# ------------------------------------------------------------------ arrangement

CHORDS = [
    ([53, 57, 60, 64], 41),   # Fmaj7
    ([55, 59, 62, 64], 43),   # G6
    ([52, 55, 59, 62], 40),   # Em7
    ([57, 60, 64, 67], 45),   # Am7
]

kick_times = []

for bar in range(16):
    t0 = bar * BAR
    notes, root = CHORDS[bar % 4]

    if bar < 15:
        pad.add(t0, pad_chord(notes, BAR + 0.3), gain=0.9 if bar < 14 else 0.6)

    # Electric piano: stab on 1, the "and" of 2, and 4.
    if bar < 14:
        for b, vel in ((0.0, 1.0), (1.5, 0.6), (3.0, 0.75)):
            for k, note in enumerate(notes):
                keys.add(t0 + b * BEAT + k * 0.004, ep_note(note + 12, 1.0, 0.8 + 0.2 * vel), gain=vel, pan=-0.25 + 0.17 * k)

    # Drums from the intro (bar 2) through bar 13.
    if 2 <= bar <= 13:
        for b in range(4):
            kick_times.append(t0 + b * BEAT)
        for e in range(8):
            if e % 2 == 1 or bar >= 4:
                drums.add(t0 + e * BEAT / 2, hat(open_=(e % 2 == 1 and bar >= 4 and e == 7)), gain=0.32 if e % 2 else 0.2, pan=0.3)
        if bar >= 4:
            for b in (1, 3):
                drums.add(t0 + b * BEAT, clap(), gain=0.8, pan=-0.1)
        if bar == 13:
            for s16 in range(12, 16):
                drums.add(t0 + s16 * BEAT / 4, clap(), gain=0.25 + 0.12 * (s16 - 12), pan=0.1)
    elif bar < 2:
        # Hook: only light hats on the off beats in bar 1.
        if bar == 1:
            for e in range(1, 8, 2):
                drums.add(t0 + e * BEAT / 2, hat(), gain=0.35, pan=0.3)

    # Bass: eighth notes with an octave hop on the last one.
    if 2 <= bar <= 13:
        for e in range(8):
            note = root + (12 if e == 7 else 0)
            bass.add(t0 + e * BEAT / 2, bass_note(note, BEAT / 2 * 0.9), gain=0.9 if e % 2 == 0 else 0.7)

    # Plucked arpeggio during the product walkthrough.
    if 4 <= bar <= 12:
        pattern = [0, 1, 2, 3, 2, 1, 3, 2]
        for e, idx in enumerate(pattern):
            p = pluck(notes[idx] + 24)
            keys.add(t0 + e * BEAT / 2, p, gain=0.8, pan=0.45 if e % 2 else -0.45)
            verb_send.add(t0 + e * BEAT / 2 + 3 * BEAT / 4, p * 0.5, pan=-0.45 if e % 2 else 0.45)

# Outro bar 14: the four words land on the four beats.
for b in range(4):
    kick_times.append(14 * BAR + b * BEAT)
    notes, root = CHORDS[b % 4]
    for k, note in enumerate(notes):
        keys.add(14 * BAR + b * BEAT, ep_note(note + 12, 0.6), gain=0.9, pan=-0.25 + 0.17 * k)
    bass.add(14 * BAR + b * BEAT, bass_note(root, 0.3), gain=1.0)

# Final chord on "Share." (frame 900, 30 s), ringing out.
final_t = sec(900)
for k, note in enumerate([53, 57, 60, 64, 69, 72]):
    keys.add(final_t + k * 0.012, ep_note(note + 12, 2.0, 1.0), gain=1.1, pan=-0.4 + 0.16 * k)
pad.add(final_t, pad_chord([41, 53, 57, 60, 64], 2.0), gain=1.2)
bass.add(final_t, bass_note(29 + 12, 1.6), gain=1.0)
kick_times.append(final_t)

for kt in kick_times:
    drums.add(kt, kick(), gain=1.0)

# Riser into the intro drop at 4 s.
sfx.add(sec(120) - 1.2, sfx_whoosh(1.3, 0.92), gain=0.9)

# ------------------------------------------------------------------ sound effects on picture
P = 240  # product scene start
events = [
    (15, sfx_thump(), 0.8), (30, sfx_thump(), 0.8), (45, sfx_thump(), 0.9),
    (56, sfx_marker(0.55), 1.0), (70, sfx_marker(0.55), 1.0), (92, sfx_pop(), 1.0),
    (136, sfx_pop(), 0.8),
    (P + 8, sfx_marker(1.0) * 0.4, 0.6),
    (P + 45, sfx_shutter(), 1.0), (P + 47, sfx_whoosh(0.8, 0.5), 0.5),
    (P + 90, sfx_marker(0.5), 1.0), (P + 105, sfx_pop(), 1.0),
    (P + 120, sfx_whoosh(0.45, 0.6), 0.7),
    (P + 165, sfx_pop(), 1.0), (P + 180, sfx_shh(0.5), 1.0),
    (P + 210, sfx_pop(), 1.0), (P + 214, sfx_whoosh(0.9, 0.6), 0.45),
    (P + 255, sfx_click(), 1.0), (P + 270, sfx_click(), 1.0), (P + 285, sfx_click(), 1.0), (P + 300, sfx_click(), 1.0),
    (P + 330, sfx_click(), 1.0), (P + 333, sfx_chime(), 1.0),
    (625 - 9, sfx_whoosh(0.5, 0.6), 0.8),
    (625 + 18, sfx_msg(), 1.0), (625 + 40, sfx_msg(), 1.0), (625 + 88, sfx_msg(), 1.0),
    (750 - 6, sfx_whoosh(0.45, 0.6), 0.8), (750 + 12, sfx_beep(), 1.0),
    (750 + 50, sfx_click(), 0.7), (750 + 54, sfx_click(), 0.7),
    (840 - 6, sfx_whoosh(0.45, 0.6), 0.8),
    (915, sfx_chime((88, 95), 0.08), 1.0),
]
# Typing ticks while the label "Best month yet" types out.
text = 'Best month yet'
for i in range(len(text)):
    frame = P + 139 + (160 - 139) * (i + 1) / len(text)
    events.append((frame, sfx_tick(), 0.9))

for frame, sig, gain in events:
    pan = float(rng.uniform(-0.2, 0.2))
    sfx.add(sec(frame), sig, gain=gain, pan=pan)
    verb_send.add(sec(frame), sig * 0.25, pan=-pan)

# ------------------------------------------------------------------ mix


def sidechain():
    g = np.ones(N)
    for kt in kick_times:
        i = int(kt * SR)
        n = int(0.28 * SR)
        t = np.arange(n) / SR
        duck = 1 - 0.55 * np.exp(-t / 0.09)
        j = min(N, i + n)
        g[i:j] = np.minimum(g[i:j], duck[: j - i])
    return g


sc = sidechain()


def reverb(l, r, seconds=1.6):
    n = int(seconds * SR)
    t = np.arange(n) / SR
    irl = rng.standard_normal(n) * np.exp(-t / (seconds / 5))
    irr = rng.standard_normal(n) * np.exp(-t / (seconds / 5))
    irl = lp(irl, 5000)
    irr = lp(irr, 5000)
    wl = fftconvolve(l, irl)[:N]
    wr = fftconvolve(r, irr)[:N]
    return wl * 0.035, wr * 0.035


keys_rl, keys_rr = reverb(keys.l + verb_send.l + pad.l * 0.3, keys.r + verb_send.r + pad.r * 0.3)

MUSIC = 0.68  # music bed sits under the sound effects
music_l = MUSIC * (drums.l * 0.9 + bass.l * sc * 0.9 + (keys.l + pad.l) * (0.6 + 0.4 * sc) + keys_rl)
music_r = MUSIC * (drums.r * 0.9 + bass.r * sc * 0.9 + (keys.r + pad.r) * (0.6 + 0.4 * sc) + keys_rr)

t = np.arange(N) / SR
# Hook opens filtered and widens out by the drop at 4 s.
open_mix = 0.55 + 0.45 * np.clip(t / 4.0, 0, 1)
music_l *= open_mix
music_r *= open_mix

# ------------------------------------------------------------------ voiceover
from scipy.signal import resample_poly
import json

vo = np.zeros(N)
vo_dir = os.path.join(os.path.dirname(__file__), 'vo')
meta_path = os.path.join(vo_dir, 'lines.json')
if os.path.exists(meta_path):
    meta = json.load(open(meta_path))
    for line in meta['lines']:
        sr_in, clip = wavfile.read(os.path.join(vo_dir, f"{line['n']}.wav"))
        clip = clip.astype(float)
        if clip.dtype.kind == 'i' or np.abs(clip).max() > 2:
            clip /= 32768.0
        if clip.ndim > 1:
            clip = clip.mean(axis=1)
        g = np.gcd(SR, sr_in)
        clip = resample_poly(clip, SR // g, sr_in // g)
        i = int(line['start'] * SR)
        j = min(N, i + len(clip))
        vo[i:j] += clip[: j - i]
    # Clean up the voice: remove rumble, add a little presence, even out the level.
    vo = hp(vo, 90)
    vo = vo + 0.25 * bp(vo, 2500, 5000)
    speech = np.abs(vo) > 0.01
    vo_rms = np.sqrt(np.mean(vo[speech] ** 2)) if speech.any() else 1.0
    vo *= 10 ** (-15 / 20) / vo_rms
    vo = np.tanh(vo * 1.6) / 1.6  # gentle limiter on peaks
    print(f"voice: {meta['voice']}, {len(meta['lines'])} lines")

# Duck the music (about 9 dB) and effects (about 3 dB) while the narrator talks.
active = (np.abs(vo) > 0.004).astype(float)
k = int(0.12 * SR)
env_ = np.convolve(active, np.ones(k) / k, mode='same')
# Hold the duck through short pauses between words.
from scipy.ndimage import maximum_filter1d
env_ = maximum_filter1d(env_, size=int(0.35 * SR))
env_ = lp(np.clip(env_ * 3, 0, 1), 6, 1)
duck_music = 1 - 0.65 * env_
duck_sfx = 1 - 0.3 * env_

bed_l = music_l * duck_music + sfx.l * 1.15 * duck_sfx
bed_r = music_r * duck_music + sfx.r * 1.15 * duck_sfx
bed = np.stack([bed_l, bed_r], axis=1)
bed = np.tanh(bed * 0.9) / np.tanh(0.9)
bed *= 10 ** (-3.0 / 20) / max(1e-9, np.max(np.abs(bed)))

mix = bed + np.stack([vo, vo], axis=1)

# Fade the very end so the loop is clean, after the last line has finished.
fade = np.clip((LENGTH - t) / 0.25, 0, 1)
fade_in = np.clip(t / 0.02, 0, 1)
mix *= (fade * fade_in)[:, None]

peak = np.max(np.abs(mix))
mix = mix / peak * 10 ** (-1.0 / 20)

out = os.path.join(os.path.dirname(__file__), '..', 'public', 'audio.wav')
wavfile.write(out, SR, (mix * 32767).astype(np.int16))
rms = np.sqrt(np.mean(mix ** 2))
print(f'wrote {out}: {LENGTH}s, peak -1.0 dBFS, rms {20 * np.log10(rms):.1f} dBFS')
