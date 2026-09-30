#!/usr/bin/env python3
"""Exercise the plugin against the installed Omarchy UI and scoped shell API.

Requires an active Wayland session and Quickshell. All timer state stays in a
temporary directory; the test never opens the popup or the break overlay.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

repository = Path(__file__).resolve().parent.parent
host = Path("/usr/share/omarchy/shell")
if not host.is_dir() or not os.environ.get("WAYLAND_DISPLAY"):
    raise SystemExit("Requires installed Omarchy and an active Wayland session")

with tempfile.TemporaryDirectory(prefix="pomodoro-integration-") as directory:
    root = Path(directory)
    for module in ("Commons", "Ui"):
        (root / module).symlink_to(host / module, target_is_directory=True)
    (root / "Host").symlink_to(host / "services", target_is_directory=True)
    plugin = root / "TestPlugin"
    shutil.copytree(repository, plugin, ignore=shutil.ignore_patterns(".git", "tests"))
    state = root / "state"
    state.mkdir()
    (state / "state.json").write_text(json.dumps({
        "version": 1, "phase": "focus", "running": False,
        "remainingMs": 660000, "plannedMs": 1500000,
    }))
    service = plugin / "Service.qml"
    service.write_text(service.read_text().replace(
        'Quickshell.env("HOME") + "/.local/state/uni-pomo"',
        json.dumps(str(state)),
    ))
    reader = plugin / "pomo-state-read"
    reader.write_text(reader.read_text().replace(
        'os.path.join(os.path.expanduser("~"), ".local", "state", "uni-pomo")',
        json.dumps(str(state)),
    ))
    shutil.copyfile(repository / "tests/shell.qml", root / "shell.qml")
    result = subprocess.run(
        ["quickshell", "-p", str(root), "--no-color"],
        env={**os.environ, "QT_QPA_PLATFORM": "wayland"},
        capture_output=True, text=True, timeout=15,
    )
    output = result.stdout + result.stderr
    print(output, end="")
    if result.returncode or "FAIL" in output or "PASS Stop resets timer" not in output:
        raise SystemExit(result.returncode or 1)
