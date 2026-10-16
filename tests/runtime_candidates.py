"""Run on a private D-Bus session with isolated XDG dirs, never a user's bus."""
import os
from pathlib import Path
import subprocess
import time

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402


def drain():
    end = time.monotonic() + 0.1
    while time.monotonic() < end:
        while GLib.MainContext.default().pending():
            GLib.MainContext.default().iteration(False)
        time.sleep(0.005)


assert os.environ.get("ORI_ICE_PRIVATE_BUS") == "1", "Use tests/smoke.sh"
env = os.environ.copy()
for name in ["DISPLAY", "WAYLAND_DISPLAY"]:
    env.pop(name, None)
log = Path(os.environ["STATE_ROOT"]) / "runtime-test.log"
log.parent.mkdir(parents=True, exist_ok=True)
with log.open("w") as output:
    process = subprocess.Popen(
        ["fcitx5", "--disable=all", "--enable=dbus,dbusfrontend,keyboard,rime"],
        env=env, stdout=output, stderr=subprocess.STDOUT,
    )
    bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    context = None
    subscription = None
    interface = "org.fcitx.Fcitx.InputContext1"
    panels = []

    def call(path, iface, method, args=None):
        return bus.call_sync("org.fcitx.Fcitx5", path, iface, method, args,
                             None, Gio.DBusCallFlags.NO_AUTO_START, 15000, None)

    def signal(conn, sender, path, iface, name, params, data):
        panels.append(params.unpack()[4])

    def key(symbol):
        for release in [False, True]:
            call(context, interface, "ProcessKeyEvent",
                 GLib.Variant("(uuubu)", (symbol, 0, 0, release, 0)))
            drain()

    try:
        deadline = time.monotonic() + 15
        while True:
            if process.poll() is not None:
                raise RuntimeError(log.read_text())
            try:
                context = call("/org/freedesktop/portal/inputmethod",
                               "org.fcitx.Fcitx.InputMethod1", "CreateInputContext",
                               GLib.Variant("(a(ss))", ([("program", "ori-ice-test")],))).unpack()[0]
                break
            except GLib.Error:
                if time.monotonic() > deadline:
                    raise RuntimeError(log.read_text())
                time.sleep(0.1)
        subscription = bus.signal_subscribe(
            "org.fcitx.Fcitx5", interface, "UpdateClientSideUI", context, None,
            Gio.DBusSignalFlags.NONE, signal, None,
        )
        call(context, interface, "SetCapability", GLib.Variant("(t)", ((1 << 39) | 2 | 16,)))
        call(context, interface, "FocusIn")
        call("/controller", "org.fcitx.Fcitx.Controller1", "SetCurrentIM",
             GLib.Variant("(s)", ("rime",)))
        drain()
        for word, expected in [("kaixin", "😄"), ("pingguo", "🍎"), ("aixin", "❤️")]:
            key(65307)  # Escape clears composition without learning test words.
            panels.clear()
            for letter in word:
                key(ord(letter))
            candidates = [text for label, text in panels[-1]] if panels else []
            assert expected in candidates, (word, candidates, log.read_text())
            print(f"Native Fcitx5 candidate verified: {word} -> {expected}")
    finally:
        try:
            if context is not None:
                key(65307)
                call(context, interface, "FocusOut")
                call(context, interface, "DestroyIC")
            if subscription is not None:
                bus.signal_unsubscribe(subscription)
        finally:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
