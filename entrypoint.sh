#!/bin/sh
# Shared entrypoint for every lab container. ROLE decides what gets started.
set -eu

ROLE="${ROLE:-bastion}"
LAB_USER="${LAB_USER:-lab}"
LAB_HOME=/home/lab

# The client public key is mounted read-only by lab.sh; install it if present.
if [ -s /lab/client.pub ]; then
  install -o "$LAB_USER" -g "$LAB_USER" -m 600 /lab/client.pub "$LAB_HOME/.ssh/authorized_keys"
fi

ssh-keygen -A >/dev/null 2>&1 || true
mkdir -p /run/sshd

case "$ROLE" in
  bastion|target)
    /usr/sbin/sshd -D -e &
    echo "[$ROLE] sshd listening on 22"
    ;;
  web)
    # Deliberately no sshd here: this host is reachable only through a tunnel.
    echo "[web] no sshd; reachable only via a tunnel"
    ;;
  *)
    echo "unknown ROLE: $ROLE" >&2
    exit 1
    ;;
esac

# Optional demo service, the thing port forwarding is pointed at.
if [ -n "${SERVICE_PORT:-}" ]; then
  SERVICE_PORT="$SERVICE_PORT" ROLE="$ROLE" \
    python3 /usr/local/bin/demo_server.py "$SERVICE_PORT" &
  echo "[$ROLE] demo service on $SERVICE_PORT"
fi

# Keep PID 1 alive so podman stop tears the container down cleanly.
while true; do sleep 3600; done