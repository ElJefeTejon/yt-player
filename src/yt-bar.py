#!/usr/bin/env python3
"""yt-bar.py — barra de progreso kawaii para el comando `yt`.

Reemplaza el --term-osd-bar de mpv (que escupe una linea nueva por segundo y
van apilandose hacia abajo). Aca el tiempo real se lee del socket IPC de mpv
y la barra se reescribe EN SU LUGAR (sube el cursor y borra), no escupe
bloques nuevos hacia abajo.

Layout (ancho dinamico segun la terminal):

    ♥ nombre de la cancion
    ┌────────────────── rosa claro ──────────────────┐
    │ ♡♡♡✧♡♡♥♡♡♡♡♡♡♡♡♡♡♡♡♡♡♡♡♡♡♡♡♡  01:23 ✧ 03:45 │
    └────────────────────────────────────────────────┘

- parte ya reproducida: corazones ♡ (lila) con ✧ que parpadean suavemente
- cabeza de la barra: ♥ (rosa fuerte) que avanza con el tiempo real
- parte pendiente: ♡ tenues (gris)
- caja con borde rosa; tiempos en cada extremo

Glifos elegidos porque JetBrains Mono Nerd Font los resuelve sin tofu
(♥ ♡ ✧ ─ │ ┌ ┐ └ ┘). No se usan emoji de ancho doble.

NOTA DE ANCHO (verificado con unicodedata.east_asian_width): TODOS los glifos
son de 1 celda (♥/♡/✧/─/│/┌ = Narrow o Ambiguous = 1 celda). La barra se
mide en celdas y cada glifo ocupa exactamente 1, asi el ancho total de la
linea es CONSTANTE en cada frame. Contar un glifo como 2 celdas cuando la
terminal lo dibuja en 1 corre el bloque de tiempos a izquierda/derecha en
cada parpadeo (el "salto" que se veia). Cada ✧ REEMPLAZA a un ♡ en su propia
celda: nunca agrega ancho.
"""
import argparse
import json
import os
import re
import shutil
import socket
import sys
import time

# ── paleta pastel (256-color) ──────────────────────────────────────────────
ROSA      = "\033[38;5;218m"   # rosa claro  (borde / cabecera)
CORAZON   = "\033[38;5;205m"   # rosa fuerte (el ♥ que avanza)
RELLENO   = "\033[38;5;139m"   # lila suave  (♡ reproducidos)
ESTRELLA  = "\033[38;5;183m"   # lila claro  (✧ que parpadean)
PENDIENTE = "\033[38;5;240m"   # gris tenue  (♡ pendientes)
DIM       = "\033[2m"
BOLD      = "\033[1m"
RESET     = "\033[0m"

CORAZON_FULL = "♥"   # 1 celda
CORAZON_VAC  = "♡"   # 1 celda
ESTRELLA_CH  = "✧"   # 1 celda (verificado: U+2727 es Narrow)

ANSI_RE = re.compile(r"\033\[[0-9;]*m")


def fmt_time(sec):
    if sec is None or sec < 0:
        return "--:--"
    sec = int(sec)
    return f"{sec // 60:02d}:{sec % 60:02d}"


class MPV:
    """Cliente IPC minimo para mpv."""

    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(2.0)
        self.sock.connect(path)
        self.ok = True

    def get(self, prop):
        msg = json.dumps({"command": ["get_property", prop]}) + "\n"
        self.sock.sendall(msg.encode())
        buf = b""
        while b"\n" not in buf:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionError("mpv cerro el socket")
            buf += chunk
        data = json.loads(buf.split(b"\n")[0])
        if data.get("error") != "success":
            return None
        return data.get("data")

    def close(self):
        self.ok = False
        try:
            self.sock.close()
        except OSError:
            pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--title", required=True)
    ap.add_argument("--socket", required=True)
    ap.add_argument("--pid", type=int, required=True)
    ap.add_argument("--width", type=int, default=0, help="forzar ancho (test)")
    args = ap.parse_args()

    if args.width:
        term_w = args.width
    else:
        term_w = shutil.get_terminal_size((80, 24)).columns
    box_w = max(30, min(term_w - 6, 72))
    inner = box_w - 4
    time_cells = 14       # " mm:ss ✧ mm:ss" = 1+5+1+1+1+5 = 14 celdas (✧ vale 1)
    bar_w = max(10, inner - time_cells)   # celdas de la barra

    t = args.title
    if len(t) > term_w - 6:
        t = t[: term_w - 9] + "..."

    print()
    print(f"  {ROSA}{BOLD}{CORAZON_FULL}{RESET} {BOLD}{t}{RESET}")
    print()

    def render(pos_sec, dur_sec, frame):
        if dur_sec and dur_sec > 0:
            p = min(1.0, max(0.0, (pos_sec or 0) / dur_sec))
        else:
            p = 0.0
        head = min(bar_w - 1, int(p * bar_w))   # celdas reproducidas
        rest = bar_w - head - 1

        # parte reproducida: exactamente `head` glifos de 1 celda cada uno.
        # Una ✧ cada 4 celdas parpadea REEMPLAZANDO al ♡ de esa celda: el
        # ancho no cambia nunca, solo el glifo. Ancho total constante = el
        # bloque de tiempos no se mueve.
        cells = []
        for i in range(head):
            if (i % 4 == 2) and ((frame // 3) % 2 == 0):
                cells.append(f"{ESTRELLA}{DIM}{ESTRELLA_CH}{RESET}")
            else:
                cells.append(f"{RELLENO}{CORAZON_VAC}{RESET}")
        played_str = "".join(cells)

        head_str = f"{CORAZON}{CORAZON_FULL}{RESET}"
        rest_str = f"{PENDIENTE}{CORAZON_VAC * rest}{RESET}"
        bar = played_str + head_str + rest_str

        times = f" {fmt_time(pos_sec)} {ESTRELLA}{ESTRELLA_CH}{RESET} {fmt_time(dur_sec)}"
        # ancho total = (head + 1 + rest) + 14 = bar_w + 14 = constante,
        # igual en cada frame: el bloque de tiempos queda anclado.
        pad = max(0, inner - (bar_w + time_cells))
        times = times + (" " * pad)

        line = f"{ROSA}│{RESET} {bar}{times} {ROSA}│{RESET}"
        top = f"{ROSA}┌{'─' * (inner + 2)}┐{RESET}"
        bot = f"{ROSA}└{'─' * (inner + 2)}┘{RESET}"
        return top, line, bot

    # esperar el socket
    for _ in range(50):
        if os.path.exists(args.socket):
            break
        time.sleep(0.1)
    else:
        print("no pude conectar con mpv (no aparecio el socket)", file=sys.stderr)
        return 1

    try:
        mpv = MPV(args.socket)
    except OSError:
        print("no pude conectar con mpv", file=sys.stderr)
        return 1

    frame = 0
    first = True
    last_dur = 0
    try:
        while True:
            try:
                pos = mpv.get("time-pos")
                dur = mpv.get("duration")
            except (ConnectionError, BrokenPipeError, socket.timeout):
                break

            if dur:
                last_dur = dur
            top, line, bot = render(pos, dur, frame)

            if first:
                # primera vez: 3 lineas normales, sin subir el cursor
                sys.stdout.write(f"{top}\n{line}\n{bot}")
                first = False
            else:
                # reescribir EN SU LUGAR: subir 2 (a top) y limpiar cada linea
                sys.stdout.write(f"\033[2A\r{top}\033[K\n\r{line}\033[K\n\r{bot}\033[K")
            sys.stdout.flush()

            frame += 1
            time.sleep(0.25)
            if pos is not None and dur is not None and pos >= dur - 0.3:
                break
    except (ConnectionError, BrokenPipeError):
        pass
    finally:
        # duración final ANTES de cerrar el socket
        if not last_dur and mpv.ok:
            try:
                last_dur = mpv.get("duration") or 0
            except Exception:
                pass
        mpv.close()

    # estado final lleno (usando la última duración conocida)
    top, line, bot = render(last_dur, last_dur or 1, 0)
    if first:
        sys.stdout.write(f"{top}\n{line}\n{bot}")
    else:
        sys.stdout.write(f"\033[2A\r{top}\033[K\n\r{line}\033[K\n\r{bot}\033[K")
    sys.stdout.flush()
    print()
    print(f"  {ROSA}{BOLD}listo {CORAZON_FULL}{RESET}")
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
