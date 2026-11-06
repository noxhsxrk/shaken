#!/usr/bin/env python3
"""Writes synthetic pointer traces into Tests/ShakenCoreTests/Fixtures.

These model a mouse (fast, 120 Hz, big swings) and a trackpad (60 Hz, smaller,
smoother swings). Real recordings made with the app's "Record gesture trace"
menu item (hold ⌥ while opening the menu) go into the same folder and are
replayed by the same test; prefix them with `real-`.
"""
import json, math, os, random

OUT = os.path.join(os.path.dirname(__file__), "..", "Tests", "ShakenCoreTests", "Fixtures")
random.seed(7)

def write(name, device, expect, samples, note):
    with open(os.path.join(OUT, name + ".json"), "w") as f:
        json.dump({"device": device, "expectShake": expect, "note": note,
                   "samples": [[round(t, 4), round(x, 1), round(y, 1)] for t, x, y in samples]}, f)

def path(dur, hz, fn, noise=0.6):
    out, t = [], 0.0
    while t <= dur:
        x, y = fn(t)
        out.append((t, x + random.gauss(0, noise), y + random.gauss(0, noise)))
        t += 1.0 / hz
    return out

def drag_then(fn_shake, start, dur_drag, dur_shake, hz):
    # move toward a target, then shake, then keep moving
    def f(t):
        if t < dur_drag:
            return (400 + 300 * t / dur_drag, 500 - 120 * t / dur_drag)
        if t < dur_drag + dur_shake:
            dx, dy = fn_shake(t - dur_drag)
            return (700 + dx, 380 + dy)
        tt = t - dur_drag - dur_shake
        return (700 + 80 * tt, 380 + 40 * tt)
    return path(dur_drag + dur_shake + 0.5, hz, f)

os.makedirs(OUT, exist_ok=True)
# Positive: mouse, horizontal, 5 Hz, ±70 pt
for i, (amp, freq) in enumerate([(70, 5.0), (55, 4.5), (90, 6.0)]):
    write(f"mouse-shake-{i+1}", "mouse", True,
          drag_then(lambda t, a=amp, f=freq: (a * math.sin(2 * math.pi * f * t), 6 * math.sin(2 * math.pi * f * t * 0.5)), 0, 0.6, 0.8, 120),
          f"horizontal shake ±{amp}pt at {freq}Hz mid-drag")
write("mouse-shake-vertical", "mouse", True,
      drag_then(lambda t: (5 * math.sin(9 * t), 65 * math.sin(2 * math.pi * 5 * t)), 0, 0.5, 0.8, 120),
      "vertical shake")
write("mouse-shake-diagonal", "mouse", True,
      drag_then(lambda t: (55 * math.sin(2 * math.pi * 4.5 * t), 45 * math.sin(2 * math.pi * 4.5 * t)), 0, 0.5, 0.9, 120),
      "diagonal shake")
# Positive: trackpad, slower and smaller
for i, (amp, freq) in enumerate([(40, 3.5), (34, 3.0), (50, 4.0)]):
    write(f"trackpad-shake-{i+1}", "trackpad", True,
          drag_then(lambda t, a=amp, f=freq: (a * math.sin(2 * math.pi * f * t), 0), 0, 0.8, 1.2, 60),
          f"trackpad shake ±{amp}pt at {freq}Hz")
# Negatives
write("mouse-straight-drag", "mouse", False,
      path(1.5, 120, lambda t: (100 + 600 * t, 200 + 150 * t), noise=1.5), "plain drag across the screen")
write("mouse-hunting", "mouse", False,
      path(3.0, 120, lambda t: (500 + 60 * math.sin(2 * math.pi * 0.9 * t), 400 + 10 * t)), "slow back-and-forth while looking for a drop target")
write("mouse-overshoot", "mouse", False,
      path(1.2, 120, lambda t: (300 + 500 * min(t / 0.3, 1) + (-70 * min(max(t - 0.3, 0) / 0.15, 1) if t > 0.3 else 0) + (25 * min(max(t - 0.5, 0) / 0.2, 1) if t > 0.5 else 0), 300)),
      "overshoot a target and correct twice")
write("mouse-jitter", "mouse", False,
      path(2.0, 120, lambda t: (400 + 4 * math.sin(2 * math.pi * 9 * t), 300 + 3 * math.cos(2 * math.pi * 7 * t)), noise=1.0), "hand tremor while holding still")
write("mouse-circle", "mouse", False,
      path(2.0, 120, lambda t: (500 + 120 * math.cos(2 * math.pi * 0.7 * t), 400 + 120 * math.sin(2 * math.pi * 0.7 * t))), "circling around a target")
write("trackpad-slow-drag", "trackpad", False,
      path(2.5, 60, lambda t: (300 + 40 * t + 15 * math.sin(2 * math.pi * 1.2 * t), 300 + 5 * t)), "trackpad drag with small slow wobble")
write("trackpad-window-drag", "trackpad", False,
      path(2.0, 60, lambda t: (200 + 150 * math.sin(2 * math.pi * 0.4 * t), 200 + 30 * t)), "moving a window around slowly")
print("ok")
