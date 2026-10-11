#!/usr/bin/env bash
# yt <busqueda>  ->  busca el primer resultado de YouTube, descarga el audio
# y lo ENCOLA. Si no hay nada sonando, arranca solo; si ya hay una cancion
# sonando, espera su turno (playlist). Suelta la terminal al toque.
#
# La barra kawaii la dibuja el worker (yt-queue-worker.py -> yt-bar.py) sobre
# la cancion que esta sonando, reescribiendose en su lugar.
#
# Comandos extra:
#   ytq            -> muestra la cola (y que esta sonando)
#   ytq -c         -> limpia la cola
#   ytq -p         -> limpia la cola Y detiene la cancion actual
set -euo pipefail

STATE="${YTPLAYER_STATE:-$HOME/.local/state/yt-queue}"
QUEUE="$STATE/queue.tsv"
NOWPLAYING="$STATE/nowplaying.txt"

# ── resolver rutas: si YTPLAYER_HOME esta definido lo usamos (instalacion
#    clonada), si no caemos a las rutas de la instalacion por defecto.
if [[ -n "${YTPLAYER_HOME:-}" ]]; then
  BASE="$YTPLAYER_HOME"
else
  BASE="$HOME/.local/lib/yt-player"
fi

WORKER="$BASE/yt-queue-worker.py"
ENQUEUE="$BASE/yt-queue-enqueue.sh"
BAR="$BASE/yt-bar.py"

# ── binarios externos: primero los del sistema, despues los del usuario ────
if [[ -n "${YTPLAYER_YTDLP:-}" ]]; then
  YTDLP="$YTPLAYER_YTDLP"
elif [[ -x /usr/local/bin/yt-dlp ]] || command -v yt-dlp >/dev/null 2>&1; then
  YTDLP="$(command -v yt-dlp)"
else
  YTDLP="$HOME/.local/bin/yt-dlp"
fi

if [[ -n "${YTPLAYER_MPV:-}" ]]; then
  MPV="$YTPLAYER_MPV"
elif command -v mpv >/dev/null 2>&1; then
  MPV="$(command -v mpv)"
else
  MPV="$HOME/.local/apps/mpv.appimage"
fi

mkdir -p "$STATE"

# ── subcomandos de cola: ytq / ytq -c / ytq -p ─────────────────────────────
if [[ "${1:-}" == "-q" || "$(basename "$0")" == "ytq" ]]; then
  shift || true
  case "${1:-}" in
    -c|--clear)
        : > "$QUEUE"
        echo "cola vaciada"
        exit 0 ;;
    -p|--purge)
        : > "$QUEUE"
        pkill -f "mpv.*yt-queue/playing" 2>/dev/null || true
        rm -f "$NOWPLAYING" 2>/dev/null || true
        echo "cola vaciada y cancion actual detenida"
        exit 0 ;;
    "")
        echo "── sonando ──────────────────────"
        if [[ -s "$NOWPLAYING" ]]; then
          echo "  ♥ $(cat "$NOWPLAYING")"
        else
          echo "  (nada)"
        fi
        echo "── en cola ──────────────────────"
        if [[ -s "$QUEUE" ]]; then
          n=1
          while IFS=$'\t' read -r q _; do
            echo "  $n. $q"; n=$((n+1))
          done < "$QUEUE"
        else
          echo "  (vacia)"
        fi
        exit 0 ;;
    *)
        echo "uso: ytq [-c|-p]" >&2; exit 1 ;;
  esac
fi

query="$*"
if [[ -z "$query" ]]; then
  echo "uso: yt <nombre de la cancion>   (encola y suelta la terminal)" >&2
  echo "      ytq            ver la cola" >&2
  echo "      ytq -c         vaciar la cola" >&2
  echo "      ytq -p         vaciar y detener la actual" >&2
  exit 1
fi

# ffmpeg para extraer audio
if [[ -x /usr/bin/ffmpeg ]]; then FFMPEG_LOC="/usr/bin"
else FFMPEG_LOC="$(ls -d "$HOME"/.hermes/tools/ffmpeg-*/bin 2>/dev/null | head -n1)"; fi

# 1) resolver: primer resultado + url
info="$("$YTDLP" --no-warnings --print '%(title)s|%(webpage_url)s' \
        --no-playlist "ytsearch1:${query}" 2>/dev/null | head -n1)"
if [[ -z "${info:-}" ]]; then
  echo "no encontre nada para: $query" >&2; exit 1
fi
title="${info%%|*}"; url="${info##*|}"

# 2) descargar audio a incoming/ (NO a un tmp con trap: el worker es otro
# proceso y el trap borraria el archivo antes de que llegue a moverlo).
mkdir -p "$STATE/incoming"
slot="$(date +%s%N).$$"
incoming="$STATE/incoming/$slot"
mkdir -p "$incoming"
if ! "$YTDLP" --no-warnings --no-playlist \
       --ffmpeg-location "$FFMPEG_LOC" \
       -f '250/251/bestaudio/best' -x --audio-format opus --audio-quality 0 \
       -o "$incoming/audio.%(ext)s" "$url" >"$incoming/dl.log" 2>&1; then
  echo "no pude descargar el audio de: $query" >&2
  tail -n 15 "$incoming/dl.log" >&2
  rm -rf "$incoming"; exit 1
fi
file="$(ls "$incoming"/audio.* 2>/dev/null | head -n1 || true)"
if [[ -z "${file:-}" ]]; then
  echo "no pude descargar el audio de: $query" >&2
  rm -rf "$incoming"; exit 1
fi

# 3) encolar (titulo\tsrc). El worker mueve el archivo a playing/ y lo toca.

"$ENQUEUE" "$title" "$file"

# feedback: posicion en la cola justo despues de encolar
nq=$(grep -c "" "$QUEUE" 2>/dev/null || echo 0)
if [[ -s "$NOWPLAYING" ]]; then
  echo "  ♡ en cola (#$nq): $title"
else
  echo "  ♥ arranca ya: $title"
fi
