#!/usr/bin/env python3

"""yt-queue-worker.py — worker de la cola de `yt`, ligado a TU terminal.

Lo lanza `yt` en background de tu shell: su stdout ES tu terminal, asi la
barra kawaii (yt-bar.py) se ve donde escribis. Muere cuando cerras la
terminal (no usa systemd). Un lock flock garantiza un solo worker vivo.

Consume $YTPLAYER_STATE (o ~/.local/state/yt-queue) / queue.tsv (titulo \t
ruta-audio, el audio ya viene descargado por el cliente en incoming/). Por
cada item: mueve el audio a playing/, lo toca con mpv+dibuja la barra, y al
terminar pasa al siguiente.

NO toca la red. NO auto-sale: se queda esperando items; cuando cerras la
terminal muere con ella. Para vaciar todo: `ytq -p`.

"""

import fcntl
import glob
import os
import shutil
import signal
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
STATE = os.environ.get(
    "YTPLAYER_STATE", os.path.join(HOME, ".local", "state", "yt-queue")
)
QUEUE = os.path.join(STATE, "queue.tsv")
PLAYING = os.path.join(STATE, "playing")
INCOMING = os.path.join(STATE, "incoming")
LOCK = os.path.join(STATE, ".lock")
NOWPLAYING = os.path.join(STATE, "nowplaying.txt")

# ── donde vive el codigo (instalacion clonada o instalada por install.sh) ──
if "YTPLAYER_HOME" in os.environ:
    BASE = os.environ["YTPLAYER_HOME"]
else:
    BASE = os.path.join(HOME, ".local", "lib", "yt-player")

BAR = os.path.join(BASE, "yt-bar.py")


def _find_mpv():
    """Busca mpv: variable de entorno > PATH > appimage del usuario."""
    if "YTPLAYER_MPV" in os.environ:
        return os.environ["YTPLAYER_MPV"]
    for cand in ("/usr/bin/mpv", "/usr/local/bin/mpv", "/opt/homebrew/bin/mpv"):
        if os.path.isfile(cand) and os.access(cand, os.X_OK):
            return cand
    mpv_in_path = shutil.which("mpv")
    if mpv_in_path:
        return mpv_in_path
    appimage = os.path.join(HOME, ".local", "apps", "mpv.appimage")
    if os.path.isfile(appimage):
        return appimage
    return "mpv"  # confia en el PATH


MPV = _find_mpv()

for d in (STATE, PLAYING, INCOMING):
    os.makedirs(d, exist_ok=True)

log = open(os.path.join(STATE, "worker.log"), "a")
_cur_mpv = None


def logmsg(m):
    try:
        log.write(f"[{time.strftime('%H:%M:%S')}] {m}\n")
        log.flush()
    except OSError:
        pass


def _sigterm(_sig, _frm):
    # cierre limpio: matar mpv y salir
    global _cur_mpv
    if _cur_mpv and _cur_mpv.poll() is None:
        try:
            _cur_mpv.terminate()
            _cur_mpv.wait(timeout=2)
        except Exception:
            try:
                _cur_mpv.kill()
            except Exception:
                pass
    sys.exit(0)


signal.signal(signal.SIGTERM, _sigterm)
signal.signal(signal.SIGINT, _sigterm)


def pop_queue():
    """Saca el primer item de forma atomica. Devuelve (titulo, src) o None."""
    if not os.path.exists(QUEUE):
        return None
    fd = os.open(QUEUE, os.O_RDWR)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        with os.fdopen(os.dup(fd), "r") as f:
            lines = f.read().splitlines()
        if not lines:
            return None
        first, rest = lines[0], lines[1:]
        os.lseek(fd, 0, os.SEEK_SET)
        os.ftruncate(fd, 0)
        with os.fdopen(os.dup(fd), "w") as f:
            if rest:
                f.write("\n".join(rest) + "\n")
        if "\t" in first:
            titulo, src = first.split("\t", 1)
            return titulo, src
        return None
    finally:
        os.close(fd)


def clear_dir(d):
    for name in os.listdir(d):
        p = os.path.join(d, name)
        if os.path.isfile(p):
            try:
                os.remove(p)
            except OSError:
                pass


def take(src):
    """Lleva el audio a playing/audio.<ext>. Devuelve la ruta o None."""
    ext = os.path.splitext(src)[1] or ".opus"
    dest = os.path.join(PLAYING, "audio" + ext)
    clear_dir(PLAYING)
    try:
        shutil.move(src, dest)
    except OSError as e:
        cands = glob.glob(os.path.join(INCOMING, "*.opus")) + \
                glob.glob(os.path.join(INCOMING, "audio.*"))
        if cands:
            try:
                shutil.move(cands[0], dest)
            except OSError:
                logmsg(f"no pude tomar {src} ni {cands[0]}: {e}")
                return None
        else:
            logmsg(f"no pude mover {src} -> {dest}: {e}")
            return None
    return dest


def play(titulo, src):
    global _cur_mpv
    dest = take(src)
    if not dest:
        return
    d = os.path.dirname(src)
    if d.startswith("/tmp/yt.") or d == INCOMING or d.startswith(INCOMING + os.sep):
        shutil.rmtree(d, ignore_errors=True)

    with open(NOWPLAYING, "w") as f:
        f.write(titulo)

    sock = os.path.join(STATE, "ipc.sock")
    try:
        if os.path.exists(sock):
            os.remove(sock)
    except OSError:
        pass

    logmsg(f"play: {titulo}")
    _cur_mpv = subprocess.Popen(
        [MPV, "--no-video", "--no-config", "--no-terminal", "--really-quiet",
         "--input-ipc-server=" + sock, "--no-input-terminal",
         "--input-terminal=no", dest],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    try:
        subprocess.run(["python3", BAR, "--title", titulo,
                        "--socket", sock, "--pid", str(_cur_mpv.pid)],
                       stdout=sys.stdout, stderr=sys.stderr)
    finally:
        if _cur_mpv.poll() is None:
            try:
                _cur_mpv.terminate()
                _cur_mpv.wait(timeout=3)
            except Exception:
                try:
                    _cur_mpv.kill()
                except Exception:
                    pass
        _cur_mpv = None
    clear_dir(PLAYING)
    try:
        os.remove(NOWPLAYING)
    except OSError:
        pass


def main():
    lockf = os.open(LOCK, os.O_WRONLY | os.O_CREAT, 0o644)
    try:
        fcntl.flock(lockf, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        logmsg("ya hay un worker; salgo")
        return 0

    logmsg("worker iniciado")
    while True:
        item = pop_queue()
        if item is None:
            time.sleep(0.4)
            continue
        titulo, src = item
        play(titulo, src)


if __name__ == "__main__":
    sys.exit(main())
