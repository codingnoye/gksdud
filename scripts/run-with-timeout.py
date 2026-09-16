#!/usr/bin/env python3
"""Bound a command and its process group without printing arguments or secrets."""
import os
import signal
import subprocess
import sys

seconds = float(sys.argv[1])
process = subprocess.Popen(sys.argv[2:], start_new_session=True)
try:
    sys.exit(process.wait(timeout=seconds))
except subprocess.TimeoutExpired:
    # Kill the whole group, including descendants, not just a waiting parent.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        pass
    print("Command exceeded its time limit.", file=sys.stderr)
    sys.exit(124)
