"""Exercise the actual Lua entry point in a pseudoterminal against a live REPL."""
import fcntl
import os
from pathlib import Path
import pty
import select
import shutil
import struct
import subprocess
import sys
import termios
import time


def main():
    root = Path(__file__).resolve().parent.parent
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 120, 0, 0))
    command = [shutil.which("luajit"), str(root / "scripts/jl_tui.lua"),
               "inline", sys.argv[1], sys.argv[2]]
    if "--launcher" in sys.argv:
        command = ["bash", str(root / "scripts/jl-assist"), "-i", "-s", sys.argv[1]]
    env = dict(os.environ, TERM="xterm-256color", JEMACH_BACKEND="standalone")
    process = subprocess.Popen(command, stdin=slave, stdout=slave, stderr=slave,
                               cwd="/tmp", env=env)
    os.close(slave)
    output = bytearray()

    def await_text(expected):
        deadline = time.monotonic() + 10
        start = len(output)
        while time.monotonic() < deadline:
            if select.select([master], [], [], 0.1)[0]:
                try:
                    chunk = os.read(master, 65536)
                except OSError:
                    break
                output.extend(chunk)
                if expected in output[start:]:
                    return
            if process.poll() is not None:
                break
        raise AssertionError(f"TUI did not render {expected!r}:\n{output.decode(errors='replace')[-4000:]}")

    try:
        await_text(b"tui_smoke_value")
        for key, expected in [(b"2", b"History"), (b"3", b"Procedures"),
                              (b"4", b"Packages"), (b"?", b"Julia REPL Editing")]:
            os.write(master, key)
            await_text(expected)
        os.write(master, b"q")
        # Drain the PTY while waiting so a full output buffer cannot block exit.
        deadline = time.monotonic() + 5
        while process.poll() is None and time.monotonic() < deadline:
            if select.select([master], [], [], 0.1)[0]:
                try:
                    output.extend(os.read(master, 65536))
                except OSError:
                    break
        assert process.wait(timeout=5) == 0, output.decode(errors="replace")[-4000:]
        assert b"jl_tui error:" not in output
        print("TUI pseudoterminal smoke test passed")
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        os.close(master)


if __name__ == "__main__":
    main()
