#!/usr/bin/env python3
"""Soak test: random copies for DURATION seconds against a running Debug Clipboard History.
Samples footprint/CPU every 60 s via the debug dump + ps. Usage: soak.py <data_dir> <seconds> <out.csv>"""
import io, json, os, random, subprocess, sys, time
from AppKit import NSPasteboard
from Foundation import NSData
from PIL import Image

data_dir, duration, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
here = os.path.dirname(os.path.abspath(__file__))
locked_bin = os.environ.get("LOCKED_BIN")
pb = NSPasteboard.generalPasteboard()
pid = subprocess.check_output(["pgrep", "-x", "ClipboardHistory"]).split()[0].decode()
words = "alpha beta gamma delta code build deploy note meeting café naïve 東京 emoji 🎉 https://example.com/x".split()

def dump():
    subprocess.run([f"{here}/dbg.sh", "dump"]); time.sleep(0.5)
    return json.load(open(f"{data_dir}/debug-state.json"))

def unlocked():
    return not locked_bin or subprocess.run([locked_bin], capture_output=True).returncode == 0

with open(out, "w") as f:
    f.write("t,copies,items,footprint_mb,cpu_time_s,panel_opens\n")
    start = last_sample = time.time(); copies = opens = 0
    while time.time() - start < duration:
        r = random.random(); pb.clearContents()
        if r < 0.08:
            im = Image.new("RGB", (random.randrange(200, 3000), random.randrange(200, 2000)),
                           tuple(random.randrange(256) for _ in range(3)))
            b = io.BytesIO(); im.save(b, "PNG"); v = b.getvalue()
            pb.setData_forType_(NSData.dataWithBytes_length_(v, len(v)), "public.png")
        elif r < 0.12:
            pb.setString_forType_("#%06X" % random.randrange(1 << 24), "public.utf8-plain-text")
        else:
            pb.setString_forType_(" ".join(random.choice(words) for _ in range(random.randrange(1, 400))), "public.utf8-plain-text")
        copies += 1
        if random.random() < 0.1 and unlocked():   # open + close the panel now and then
            subprocess.run([f"{here}/dbg.sh", "toggle"]); time.sleep(0.4)
            subprocess.run([f"{here}/dbg.sh", "hide"]); opens += 1
        if time.time() - last_sample >= 60:
            d = dump(); cpu = subprocess.check_output(["ps", "-o", "cputime=", "-p", pid]).decode().strip()
            m, s = cpu.split(":"); cpu_s = int(m) * 60 + float(s)
            f.write(f"{int(time.time()-start)},{copies},{d['count']},{d['residentMB']:.1f},{cpu_s:.2f},{opens}\n"); f.flush()
            last_sample = time.time()
        time.sleep(random.uniform(1.0, 4.0))
print("done", copies, "copies", opens, "panel opens")
