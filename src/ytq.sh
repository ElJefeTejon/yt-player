#!/usr/bin/env bash
# ytq  ->  ver la cola de yt (y que esta sonando)
#   ytq        muestra sonando + cola
#   ytq -c     vaciar la cola
#   ytq -p     vaciar la cola y detener la cancion actual
exec yt -q "$@"
