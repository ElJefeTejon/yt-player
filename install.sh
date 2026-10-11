#!/usr/bin/env bash
# install.sh — instala yt-player de una sola linea.
#
#   curl -fsSL https://raw.githubusercontent.com/<usuario>/yt-player/main/install.sh | bash
#
# O si ya tenes el repo clonado:
#
#   ./install.sh
#
# Que hace:
#   1. Revisa las dependencias (mpv, ffmpeg, yt-dlp, python3).
#   2. Instala lo que falte cuando el gestor de paquetes lo permite
#      (apt / dnf / pacman / brew). Si no puede, te avisa y sigue.
#   3. Copia los scripts a ~/.local/lib/yt-player/.
#   4. Crea los comandos `yt` y `ytq` en ~/.local/bin/ (o donde digas).
#
# Nada pide sudo salvo la instalacion de dependencias del sistema, y ahi te
# lo va a pedir el gestor de paquetes, no este script.
set -euo pipefail

# ── donde vive este script ─────────────────────────────────────────────────
# Resolvemos el dir real (sirve para curl | bash, donde $0 es 'bash')
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-/dev/stdin}")" && pwd)"
if [[ ! -f "$SRC_DIR/src/yt.sh" ]]; then
  # curl | bash: SRC_DIR no apunta al repo. Clonamos a un tmp.
  echo "  · no encuentro el codigo en $SRC_DIR — lo voy a clonar"
  TMPDIR_CLONE="$(mktemp -d)"
  git clone --depth 1 https://github.com/${YTPLAYER_REPO:-jefetejon/yt-player}.git "$TMPDIR_CLONE"
  SRC_DIR="$TMPDIR_CLONE"
fi

LIB="${YTPLAYER_LIB:-$HOME/.local/lib/yt-player}"
BIN="${YTPLAYER_BIN:-$HOME/.local/bin}"

say() { printf '  %s\n' "$*"; }
ok()  { printf '  ✓ %s\n' "$*"; }
warn(){ printf '  ! %s\n' "$*"; }

echo
echo "  ♥ yt-player — instalacion"
echo

# ── 1. dependencias ────────────────────────────────────────────────────────
echo "  [1/4] revisando dependencias"

MISSING=()

# python3 (siempre necesario para el worker y la barra)
if ! command -v python3 >/dev/null 2>&1; then
  MISSING+=("python3")
fi

# mpv (reproductor) — si ya le pasamos una ruta explicita, no lo molestamos
if [[ -n "${YTPLAYER_MPV:-}" ]]; then
  say "usando mpv de YTPLAYER_MPV=$YTPLAYER_MPV"
elif ! command -v mpv >/dev/null 2>&1; then
  MISSING+=("mpv")
fi

# ffmpeg (extraccion de audio de yt-dlp)
if ! command -v ffmpeg >/dev/null 2>&1; then
  MISSING+=("ffmpeg")
fi

# yt-dlp (descargador) — idem: si ya hay ruta explicita, confiamos
if [[ -n "${YTPLAYER_YTDLP:-}" ]]; then
  say "usando yt-dlp de YTPLAYER_YTDLP=$YTPLAYER_YTDLP"
elif ! command -v yt-dlp >/dev/null 2>&1; then
  MISSING+=("yt-dlp")
fi

if [[ ${#MISSING[@]} -eq 0 ]]; then
  ok "todas las dependencias presentes"
else
  warn "faltan: ${MISSING[*]}"
  echo

  # yt-dlp es especial: casi nunca esta en los repos de distro, se instala
  # como binario standalone. Lo hacemos sin tocar el gestor de paquetes.
  if [[ " ${MISSING[*]} " == *" yt-dlp "* ]]; then
    say "instalando yt-dlp (binario standalone en ~/.local/bin)"
    mkdir -p "$BIN"
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp \
        -o "$BIN/yt-dlp"
    elif command -v wget >/dev/null 2>&1; then
      wget -qO "$BIN/yt-dlp" \
        https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp
    else
      warn "no tengo curl ni wget para bajar yt-dlp — instalalo a mano"
      MISSING=("${MISSING[@]/yt-dlp}")
    fi
    if [[ -f "$BIN/yt-dlp" ]]; then
      chmod +x "$BIN/yt-dlp"
      ok "yt-dlp instalado en $BIN/yt-dlp"
      MISSING=("${MISSING[@]/yt-dlp}")
    fi
  fi

  # el resto: mpv / ffmpeg / python3 por gestor de paquetes
  SYS_MISSING=()
  [[ " ${MISSING[*]} " == *" python3 "* ]] && SYS_MISSING+=("python3")
  [[ " ${MISSING[*]} " == *" mpv "* ]]     && SYS_MISSING+=("mpv")
  [[ " ${MISSING[*]} " == *" ffmpeg "* ]]  && SYS_MISSING+=("ffmpeg")

  if [[ ${#SYS_MISSING[@]} -gt 0 ]]; then
    say "instalando del sistema: ${SYS_MISSING[*]} (puede pedirte la contrasena)"
    if command -v apt >/dev/null 2>&1; then
      sudo apt-get install -y "${SYS_MISSING[@]}"
    elif command -v dnf >/dev/null 2>&1; then
      sudo dnf install -y "${SYS_MISSING[@]}"
    elif command -v pacman >/dev/null 2>&1; then
      sudo pacman -S --noconfirm "${SYS_MISSING[@]}"
    elif command -v brew >/dev/null 2>&1; then
      brew install "${SYS_MISSING[@]}"
    else
      warn "no reconozco el gestor de paquetes."
      warn "instala a mano: ${SYS_MISSING[*]}"
    fi
  fi
fi

# ── 2. copiar el codigo ────────────────────────────────────────────────────
echo
echo "  [2/4] copiando el codigo a $LIB"
mkdir -p "$LIB"
cp "$SRC_DIR/src/yt.sh"              "$LIB/yt"
cp "$SRC_DIR/src/ytq.sh"             "$LIB/ytq"
cp "$SRC_DIR/src/yt-bar.py"          "$LIB/yt-bar.py"
cp "$SRC_DIR/src/yt-queue-worker.py" "$LIB/yt-queue-worker.py"
cp "$SRC_DIR/src/yt-queue-enqueue.sh" "$LIB/yt-queue-enqueue.sh"
chmod +x "$LIB/yt" "$LIB/ytq" "$LIB"/*.py "$LIB"/*.sh
ok "codigo instalado"

# ── 3. los comandos en el PATH ─────────────────────────────────────────────
echo
echo "  [3/4] creando los comandos yt / ytq en $BIN"
mkdir -p "$BIN"

# wrappers finos: solo apuntan al codigo en $LIB
cat > "$BIN/yt" <<EOF
#!/usr/bin/env bash
exec "$LIB/yt" "\$@"
EOF
cat > "$BIN/ytq" <<EOF
#!/usr/bin/env bash
exec "$LIB/ytq" "\$@"
EOF
chmod +x "$BIN/yt" "$BIN/ytq"
ok "comandos listos"

# ── 4. aviso si ~/.local/bin no esta en el PATH ────────────────────────────
echo
echo "  [4/4] verificando el PATH"
if [[ ":$PATH:" != *":$BIN:"* ]]; then
  warn "$BIN no esta en tu PATH."
  echo
  say "Agrega esta linea a tu ~/.bashrc o ~/.zshrc:"
  echo
  echo "      export PATH=\"\$HOME/.local/bin:\$PATH\""
  echo
  say "y reabri la terminal (o corre: source ~/.bashrc)"
else
  ok "$BIN ya esta en tu PATH"
fi

echo
echo "  ♥ listo! Probalo con:"
echo
echo "      yt tu cancion favorita"
echo
if [[ -n "${TMPDIR_CLONE:-}" ]]; then
  rm -rf "$TMPDIR_CLONE"
fi
