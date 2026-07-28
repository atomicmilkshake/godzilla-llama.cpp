from pathlib import Path
import time
import re
import subprocess

log = Path(r"J:/LLM/engines/godzilla-llama.cpp/build_king_mtp_fix_final.log")
start = time.time()
last = ""
while time.time() - start < 2400:
    t = log.read_text(encoding="utf-8", errors="replace") if log.exists() else ""
    progs = re.findall(r"\[(\d+)/(\d+)\]", t)
    status = ""
    if "BUILD_OK" in t:
        status = "OK"
    elif "BUILD_FAIL" in t:
        status = "FAIL"
    elif "STAGE_FAIL" in t:
        status = "STAGE_FAIL"
    elif "ENV_FAIL" in t:
        status = "ENV_FAIL"
    prog = progs[-1] if progs else ("?", "?")
    r = subprocess.run(
        ["tasklist", "/FI", "IMAGENAME eq ninja.exe"],
        capture_output=True,
        text=True,
    )
    ninja = r.stdout.count("ninja.exe")
    msg = f"+{time.time()-start:.0f}s status={status or 'running'} last=[{prog[0]}/{prog[1]}] log={len(t)} ninja={ninja}"
    if msg != last:
        print(msg, flush=True)
        last = msg
    if status:
        print(t[-3000:], flush=True)
        raise SystemExit(0 if status == "OK" else 1)
    time.sleep(30)
print("TIMEOUT")
if log.exists():
    print(log.read_text(encoding="utf-8", errors="replace")[-2000:])
raise SystemExit(2)
