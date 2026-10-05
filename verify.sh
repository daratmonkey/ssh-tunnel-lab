#!/usr/bin/env bash
# Verifies every tunnel type in the primer actually carries traffic.
# Each tunnel is started with an explicit PID so cleanup is exact.
set -uo pipefail

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYS="$LAB_DIR/keys"
PORT=2222
PASS=0
FAIL=0
PIDS=()

pass() { printf '  \033[1;32mok\033[0m   %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  \033[1;31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }
head() { printf '\n\033[1;36m%s\033[0m\n' "$1"; }

SSH_OPTS=(-i "$KEYS/lab_key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o ExitOnForwardFailure=yes -o ConnectTimeout=10)

# `timeout` cannot invoke a shell function, so anything that needs a deadline
# calls the real ssh binary with the option array.
ssh_k() { ssh "${SSH_OPTS[@]}" "$@"; }
ssh_t() { timeout 25 ssh "${SSH_OPTS[@]}" "$@"; }

# Background ssh must not inherit stdout/stderr: it holds the pipe open and any
# caller that reads our output would block forever waiting for EOF.
tunnel() {
  ssh_k -N "$@" >/dev/null 2>&1 &
  PIDS+=("$!")
  sleep 2
}

cleanup() {
  local pid
  for pid in "${PIDS[@]:-}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
  done
  wait 2>/dev/null
  return 0
}
trap cleanup EXIT

# Checks a local port serves the expected role name.
expect_role() {
  local url="$1" want="$2" label="$3"
  local body
  body=$(curl -s --max-time 8 "$url" 2>/dev/null)
  if printf '%s' "$body" | grep -q "Served by <strong>$want</strong>"; then
    pass "$label"
  else
    fail "$label (wanted role '$want')"
  fi
}

head "1. direct login to the bastion"
whoami_out=$(ssh_t -p "$PORT" lab@127.0.0.1 'whoami' 2>/dev/null)
[ "$whoami_out" = "lab" ] && pass "key auth to bastion" || fail "key auth to bastion (got '$whoami_out')"

head "2. bastion is reachable, target is NOT reachable directly"
if ssh_t -o ConnectTimeout=5 lab@"$(podman inspect -f '{{.NetworkSettings.IPAddress}}' ssh-lab-target)" true 2>/dev/null; then
  fail "target should not be reachable from the host"
else
  pass "target refuses direct connections from the host"
fi

head "3. local forward -L to the bastion's own service"
tunnel -L 127.0.0.1:8090:127.0.0.1:8080 -p "$PORT" lab@127.0.0.1
sleep 2
expect_role http://127.0.0.1:8090/ bastion "127.0.0.1:8090 reaches bastion:8080"
cleanup; PIDS=()

head "4. local forward -L through the bastion to the target"
tunnel -L 127.0.0.1:8091:target:8080 -p "$PORT" lab@127.0.0.1
sleep 2
expect_role http://127.0.0.1:8091/ target "127.0.0.1:8091 reaches target:8080 via bastion"
cleanup; PIDS=()

head "5. SOCKS proxy -D to reach the web container (no sshd at all)"
tunnel -D 127.0.0.1:1080 -p "$PORT" lab@127.0.0.1
# A direct fetch of the web container must fail: it has no published port.
if curl -s --max-time 5 http://web:8080/ >/dev/null 2>&1; then
  fail "web should not be reachable without the proxy"
else
  pass "web refuses a direct connection from the host"
fi
# socks5 resolves the name LOCALLY, so it cannot work for "web" -- this host has
# no DNS entry for it. socks5h sends the name to the proxy, which resolves it
# on the far side. That difference is the single most useful thing about -D.
if curl -s --max-time 10 --socks5 127.0.0.1:1080 http://web:8080/ | grep -q 'Served by <strong>web</strong>'; then
  fail "curl --socks5 should fail: the name cannot be resolved locally"
else
  pass "curl --socks5 fails as expected (client-side DNS)"
fi
if curl -s --max-time 10 --socks5-hostname 127.0.0.1:1080 http://web:8080/ | grep -q 'Served by <strong>web</strong>'; then
  pass "socks5h also works (proxy-side DNS)"
else
  fail "curl --socks5-hostname through the proxy"
fi
cleanup; PIDS=()

head "6. jump host -J for a command on the target"
# -J makes ssh spawn a second ssh for the jump host, and that inner ssh does not
# inherit -o flags: the target's host key gets verified against the default file
# and fails. An explicit config is the clean fix and mirrors real usage.
JUMP_CFG=$(mktemp)
cat > "$JUMP_CFG" <<CFG
Host bastion
  HostName 127.0.0.1
  Port $PORT
  User lab
  IdentityFile $KEYS/lab_key
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  LogLevel ERROR

Host target
  HostName target
  User lab
  IdentityFile $KEYS/lab_key
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  LogLevel ERROR
CFG
jump_out=$(timeout 25 ssh -F "$JUMP_CFG" -J bastion target 'hostname' 2>&1)
rm -f "$JUMP_CFG"
if printf '%s' "$jump_out" | grep -qE '^[a-f0-9]{12}$'; then
  pass "ssh -J runs a command on the target"
else
  fail "ssh -J to the target (got '$jump_out')"
fi

head "7. remote forward -R exposes a bastion port back to your host"
# Start a listener on the host, then ask the bastion to forward one of its
# ports to it. GatewayPorts clientspecified is what makes this reachable.
python3 -m http.server 8099 --bind 127.0.0.1 --directory "$LAB_DIR" >/dev/null 2>&1 &
PIDS+=("$!")
sleep 1
tunnel -R 8081:127.0.0.1:8099 -p "$PORT" lab@127.0.0.1
# From the host we cannot see the bastion's port directly, so check from inside
# the bastion that the reverse forward works.
rev=$(ssh_t -p "$PORT" lab@127.0.0.1 'curl -s --max-time 8 http://127.0.0.1:8081/ | head -3' 2>/dev/null)
if printf '%s' "$rev" | grep -qiE 'Containerfile|<!doctype|directory listing'; then
  pass "-R tunnel returns the host's file back through the bastion"
else
  fail "-R reverse forward (got '$rev')"
fi
cleanup; PIDS=()

head "results"
printf '  %d passed, %d failed\n\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]