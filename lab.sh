#!/usr/bin/env bash
# SSH tunneling practice lab.
#
# Topology (all on a private podman network, only the bastion is published):
#
#     you ──ssh──> bastion :2222 ──ssh──> target :22   (internal only)
#                                       target ──> web :8080 (internal only)
#
#   bastion  the one host you can log into directly
#   target   only reachable by hopping through bastion
#   web      no sshd at all, only reachable by forwarding a port to it
set -euo pipefail

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NET_NAME=ssh-lab-net
IMAGE=ssh-tunnel-lab
KEYS="$LAB_DIR/keys"
BASTION_PORT=${BASTION_PORT:-2222}

podman() { command podman "$@"; }

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

ensure_keys() {
  mkdir -p "$KEYS"
  chmod 700 "$KEYS"
  if [ ! -f "$KEYS/lab_key" ]; then
    log "Generating a lab-only SSH keypair"
    ssh-keygen -t ed25519 -N '' -C 'ssh-lab (local practice key)' -f "$KEYS/lab_key" >/dev/null
  fi
  chmod 600 "$KEYS/lab_key"
}

build_image() {
  # Always rebuild: the image is cheap and a stale cache hides edits to the
  # sshd config or entrypoint.
  log "Building image $IMAGE"
  podman build -t "$IMAGE" "$LAB_DIR" >/dev/null
}

# Alpine has no `ss`/`nc` in the image's PATH as podman resolves it, so probe
# the port from inside the container with Python, which we know is present.
wait_for_port() {
  local container="$1" port="$2" tries=0
  until podman exec "$container" python3 -c \
      "import socket,sys; s=socket.socket(); s.settimeout(1); sys.exit(s.connect_ex(('127.0.0.1',$port)))" \
      >/dev/null 2>&1; do
    tries=$((tries + 1))
    [ "$tries" -gt 40 ] && die "$container did not start listening on $port"
    sleep 0.5
  done
}

up() {
  ensure_keys
  build_image

  # Podman requires published ports to be declared when the pod is created, so
  # the bastion's port is published on the pod itself.
  #
  # Deliberately NOT using a pod: containers in a pod share one network
  # namespace, which would put the target's sshd on the same published port and
  # destroy the point of the lab. Each container gets its own netns on a
  # user-defined network instead, and only the bastion is published.
  if podman network exists "$NET_NAME" 2>/dev/null; then
    log "Network $NET_NAME already exists"
  else
    log "Creating network $NET_NAME"
    podman network create "$NET_NAME" >/dev/null
  fi

  local mount_args=()
  # Podman needs the SELinux label relaxed for a bind mount into the container.
  if [ -z "${SKIP_SELINUX:-}" ]; then
    mount_args=(--security-opt label=disable)
  fi

  if podman container exists ssh-lab-bastion 2>/dev/null; then
    log "Containers already running"
    show_status
    return
  fi

  # --network-alias gives each container a short DNS name (bastion, target,
  # web). Without it only the full container name resolves, and the short name
  # used throughout the exercises fails.
  log "Starting bastion (the only published container)"
  podman run -d --name ssh-lab-bastion --network "$NET_NAME" --network-alias bastion \
    -e ROLE=bastion -e SERVICE_PORT=8080 \
    -v "$KEYS/lab_key.pub:/lab/client.pub:ro" "${mount_args[@]}" \
    -p "127.0.0.1:$BASTION_PORT:22" \
    "$IMAGE" >/dev/null

  log "Starting target (no published port: reachable only via bastion)"
  podman run -d --name ssh-lab-target --network "$NET_NAME" --network-alias target \
    -e ROLE=target -e SERVICE_PORT=8080 \
    -v "$KEYS/lab_key.pub:/lab/client.pub:ro" "${mount_args[@]}" \
    "$IMAGE" >/dev/null

  log "Starting web (no sshd, no published port)"
  podman run -d --name ssh-lab-web --network "$NET_NAME" --network-alias web \
    -e ROLE=web -e SERVICE_PORT=8080 \
    "$IMAGE" >/dev/null

  log "Waiting for sshd on the bastion"
  wait_for_port ssh-lab-bastion 22
  log "Waiting for sshd on the target"
  wait_for_port ssh-lab-target 22

  cat <<EOF

$(log "Lab is up")

  bastion   ssh -i keys/lab_key -p $BASTION_PORT lab@127.0.0.1
  target    reachable only through the bastion (see primer, exercise 4)
  web       reachable only by forwarding a port to it (exercise 5)

EOF
  show_status
}

down() {
  log "Removing containers, network, and pod (if any)"
  podman rm -f ssh-lab-web ssh-lab-target ssh-lab-bastion >/dev/null 2>&1 || true
  podman network rm "$NET_NAME" >/dev/null 2>&1 || true
  podman pod rm -f ssh-lab >/dev/null 2>&1 || true
  log "Lab is down (keys kept in $KEYS)"
}

show_status() {
  echo
  printf '%-22s %-12s %s\n' CONTAINER STATE PORTS
  local name
  for name in ssh-lab-bastion ssh-lab-target ssh-lab-web; do
    if podman container exists "$name" 2>/dev/null; then
      local ports
      ports=$(podman port "$name" 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g')
      printf '%-22s %-12s %s\n' "$name" "$(podman inspect -f '{{.State.Status}}' "$name")" "${ports:-(none)}"
    else
      printf '%-22s %-12s %s\n' "$name" absent -
    fi
  done
  echo
}

logs() { podman logs "$1"; }

ssh_lab() {
  # Convenience wrapper: ssh_lab [user@]host [ssh args...]
  ssh -i "$KEYS/lab_key" -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$@"
}

case "${1:-up}" in
  up)      up ;;
  down)    down ;;
  restart) down; up ;;
  status)  show_status ;;
  logs)    logs "${2:-ssh-lab-bastion}" ;;
  ssh)     shift; ssh_lab "$@" ;;
  keys)    ls -l "$KEYS" ;;
  *)       die "usage: lab.sh {up|down|restart|status|logs|ssh}" ;;
esac