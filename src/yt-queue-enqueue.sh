#!/usr/bin/env bash
# yt-queue-enqueue.sh — mete un item ya resuelto en la cola y despierta al worker.
# Uso: yt-queue-enqueue.sh "<titulo>" "<ruta/audio>"
#
# El worker se lanza en background de ESTA terminal (hereda el TTY), asi la
# barra kawaii se ve donde escribis. Un lock flock en el worker evita
# duplicados: si ya hay uno vivo, este nuevo arranca y sale al toque.
set -euo pipefail

STATE="${YTPLAYER_STATE:-$HOME/.local/state/yt-queue}"

if [[ -n "${YTPLAYER_HOME:-}" ]]; then
  BASE="$YTPLAYER_HOME"
else
  BASE="$HOME/.local/lib/yt-player"
fi
WORKER="$BASE/yt-queue-worker.py"

mkdir -p "$STATE/incoming" "$STATE/playing"
titulo="$1"
src="$2"

# linea: titulo \t src   (src apunta a incoming/<slot>/audio.opus)
printf '%s\t%s\n' "$titulo" "$src" >> "$STATE/queue.tsv"

# ¿hay un worker vivo? Contamos SOLO procesos python reales cuyo cmdline sea
# exactamente el worker (evita el falso positivo del wrapper bash que lleva el
# string en su linea de comandos).
worker_vivo=0
for p in $(pgrep -x python3 2>/dev/null); do
  if tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q "yt-queue-worker.py"; then
    worker_vivo=1; break
  fi
done

if [[ "$worker_vivo" -eq 0 ]]; then
  # NO redirigir stdout/stderr: la barra kawaii debe verse en ESTA terminal.
  # setsid lo despega del job control (no molesta al prompt) pero hereda el
  # TTY como stdout/stderr, y muere cuando cerras la terminal. stdin desde
  # /dev/null para que no compita con el prompt por la entrada del teclado.
  setsid "$WORKER" </dev/null &
  disown 2>/dev/null || true
fi
