# SSH tunneling: a short primer

## The one idea

An SSH connection is a bidirectional byte pipe. Once you have that pipe, you
can ask the machine on the other end to open a TCP connection on your behalf.
That is all a "tunnel" is: no VPN, no proxy software, no new protocol. The
bytes just ride inside the encrypted SSH channel.

The direction matters, and it is the thing people get wrong most often.

```
        you                                   remote host
  ┌──────────────┐                        ┌──────────────────┐
  │   ssh client │◀── encrypted pipe ────▶│     sshd         │
  └──────────────┘                        └──────────────────┘
                                            │  opens a socket
                                            ▼
                                         10.0.0.5:5432
```

Which flag you use depends on **where the listening socket is created** — on
your machine or the remote one.

| Flag | Listener is created on | Connection goes to |
|------|------------------------|--------------------|
| `-L` | your machine | remote host's network |
| `-R` | **remote** host | your machine (or anywhere it can reach) |
| `-D` | your machine, as a SOCKS proxy | wherever the proxy is told to go |

`-L` is "let me reach something you can see." `-R` is "let something over
there reach something over here." `-D` is "I don't know the destination yet;
decide at request time."

## The syntax

All three share one shape: `-<flag> <bind_address>:<port>:<destination>`.

```
-L [bind_address:]port:host:hostport
-R [bind_address:]port:host:hostport
-D [bind_address:]port
```

Read it right to left: "when something arrives on `port`, connect to
`host:hostport`."

## The lab

Three containers on a private podman network. Only the bastion is published.

```
  your machine
      |
      | ssh (published 127.0.0.1:2222)
      v
  +-------------+        +-------------+        +-------------+
  |   bastion   |──ssh──▶|   target    │──http──▶|    web      |
  | 10.89.1.2   |        | 10.89.1.3   │        │ 10.89.1.4   |
  | sshd :22    |        | sshd :22    │        | no sshd     |
  | demo :8080  │        | demo :8080  │        | demo :8080  |
  +-------------+        +-------------+        +-------------+
```

The `target` and `web` containers have no route from your machine at all. That
is the point: it reproduces the real situation where a database or admin panel
exists only inside a network you cannot route to directly.

Start it:

```bash
cd ~/ssh-tunnel-lab
./lab.sh up        # builds the image, starts 3 containers, prints status
./lab.sh status    # what is running and what is published
./lab.sh down      # remove containers and network
./verify.sh        # proves every tunnel below actually works
```

`./lab.sh ssh -p 2222 lab@127.0.0.1` drops you into the bastion, so you can
inspect the environment while you work.

Throughout, the private key is `keys/lab_key`.

---

## Exercise 1 — connect directly

Start here to establish the baseline.

```bash
ssh -i keys/lab_key -p 2222 lab@127.0.0.1
```

Inside the bastion, confirm you can reach a service on it directly:

```bash
curl -s http://127.0.0.1:8080/ | grep Served
# Served by <strong>bastion</strong>
```

Now confirm the target is *not* reachable without help:

```bash
podman inspect -f '{{.NetworkSettings.IPAddress}}' ssh-lab-target   # 10.89.1.3
ssh -i keys/lab_key lab@10.89.1.3            # hangs, then times out
```

That timeout is the whole motivation for tunneling.

## Exercise 2 — local forward (`-L`)

Reach the bastion's service through your own loopback:

```bash
ssh -i keys/lab_key -p 2222 -N -L 127.0.0.1:8090:127.0.0.1:8080 lab@127.0.0.1
```

In a second terminal:

```bash
curl -s http://127.0.0.1:8090/ | grep Served
# Served by <strong>bastion</strong>
```

Your browser, curl, or psql can all use `127.0.0.1:8090` as if the service were
local. Nothing else on your machine can reach that port, because you bound it
to loopback explicitly.

Omit the bind address — `-L 8090:127.0.0.1:8080` — and ssh listens on all your
interfaces, which exposes the tunnel to your LAN. **Always bind `127.0.0.1`
unless you specifically want it reachable.**

## Exercise 3 — forwarding through the bastion to the target

The destination is resolved *by the bastion*, so you can name a host that only
it can see:

```bash
ssh -i keys/lab_key -p 2222 -N -L 127.0.0.1:8091:target:8080 lab@127.0.0.1
curl -s http://127.0.0.1:8091/ | grep Served
# Served by <strong>target</strong>
```

This is the workhorse case: a database on an internal subnet, reached from your
laptop through the one host you are allowed to log into.

Practical case — PostgreSQL on the target:

```bash
ssh -i keys/lab_key -p 2222 -N -L 127.0.0.1:5432:db.internal:5432 bastion-host
psql -h 127.0.0.1 -p 5432 -U postgres   # feels local
```

Run it with `-f` to background it, and add `-o ExitOnForwardFailure=yes` so you
find out immediately if the port is already taken, rather than silently
connecting to whatever was already listening there.

## Exercise 4 — jump host (`-J`)

To run a *command* on the target rather than forward a port, use a jump host.
`-J bastion` is shorthand for a nested ssh.

```bash
cat > /tmp/lab-ssh-config <<'CFG'
Host bastion
  HostName 127.0.0.1
  Port 2222
  User lab
  IdentityFile ~/ssh-tunnel-lab/keys/lab_key
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null

Host target
  HostName target
  User lab
  IdentityFile ~/ssh-sunnel-lab/keys/lab_key
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
CFG

ssh -F /tmp/lab-ssh-config -J bastion target hostname
```

**The gotcha worth remembering:** the inner ssh spawned for the jump host does
not inherit your `-o` flags. If you rely on `-i` or `StrictHostKeyChecking` on
the command line, the second hop fails with "Host key verification failed" or
asks for a password. A `Host` block in `~/.ssh/config` applies to every hop.
This is why people keep jump hosts in a config file.

Equivalently, without `-J`:

```bash
ssh -o ProxyCommand="ssh -i keys/lab_key -W %h:%p lab@127.0.0.1 -p 2222" lab@target
```

## Exercise 5 — SOCKS proxy (`-D`)

When you don't know which host you'll need, forward a SOCKS proxy and let each
request choose its own destination:

```bash
ssh -i keys/lab_key -p 2222 -N -D 127.0.0.1:1080 lab@127.0.0.1
curl -s --socks5-hostname http://web:8080/ | grep Served
# Served by <strong>web</strong>
```

The `web` container has no sshd and no published port. It is reachable here
only because the proxy relays the request.

**`--socks5` vs `--socks5-hostname` is the detail that matters.**

- `--socks5` resolves the hostname **on your machine**, then sends an IP.
- `--socks5-hostname` (aka `socks5h`) sends the **hostname** and lets the
  remote end resolve it.

In this lab `curl --socks5 http://web:8080/` fails, because your machine has no
DNS entry for `web` — and that is correct behavior. Use `socks5h` whenever the
name only resolves on the far side. Same distinction in browsers: "SOCKS5" and
"SOCKS5h" are separate settings, and picking the wrong one is a common
mystery.

This is how you browse an internal admin panel with your normal browser: set
the proxy to `127.0.0.1:1080` and resolve remote DNS there.

## Exercise 6 — remote forward (`-R`)

`-R` reverses the direction: the listener is created on the **remote** host and
forwards back to you.

```bash
# On your machine, something to reach:
python3 -m http.server 8099 --bind 127.0.0.1 &

# Tell the bastion: "make your port 8081 reach my port 8099"
ssh -i keys/lab_key -p 2222 -N -R 8081:127.0.0.1:8099 lab@127.0.0.1

# From inside the bastion:
curl -s http://127.0.0.1:8081/ | head -3
```

**`-R` binds to the remote host's loopback by default**, so nothing on the
remote network can reach it. To expose it more widely you must say so, on the
*server* side, with `GatewayPorts clientspecified` in `sshd_config`. In this lab
that is already set so the exercise works.

The legitimate use is giving a server on a private network access to a
callback service running on your machine — a webhook receiver for testing, for
instance. The illegitimate use is the same mechanism in reverse: someone
persuading you to open `-R 0.0.0.0:22:localhost:22` hands them a public route
into an internal network, which is a large part of how SSH forwarding gets
exploited. Treat any request to run an `-R` forward as a request to be suspicious
of.

---

## Options you will actually use

| Option | Effect |
|--------|--------|
| `-N` | Don't run a remote command; just forward. Pair with `-f` to background. |
| `-f` | Background after authentication. Requires `-N` or a command. |
| `-T` | No pty. Required for machine-to-machine and inside scripts. |
| `-v` / `-vv` | Debug. Shows each forward as it's requested and refused. |
| `-L 0.0.0.0:...` | Bind all interfaces — exposes the tunnel to your network. Avoid. |
| `-o ExitOnForwardFailure=yes` | Fail loudly if the local port is taken. |
| `-o ServerAliveInterval=30` | Keep idle tunnels from being reaped. |

## Debugging

- **Tunnel up, connection refused.** The tunnel is fine; the destination is
  wrong. On the remote host, `curl` the target directly to confirm the port.
- **`channel 3: open failed: connect failed: Connection refused`.** sshd
  reached the destination and was rejected. Same fix.
- **`bind: Address already in use`.** Something owns that local port. Check
  with `ss -ltnp | grep PORT`.
- **`channel_setup_fwd_listener` failures, nothing on the server.** The *server*
  forbids it. Check `sshd_config` for `AllowTcpForwarding` and `PermitOpen`.
- **It worked yesterday.** A restart on either end drops it; forwards are not
  persistent unless you set up autossh or a systemd unit.

For an existing session, `~C` opens the ssh command line, where you can add
forwards without reconnecting:

```
~C
-L 9000:localhost:3000
```

`~?` lists all the escape sequences.

## What this does not give you

The tunnel is only as good as the account you log in with. It is not a
privilege boundary — anything that account can read, a tunnel to that account
exposes. If the remote host is compromised, the tunnel carries whatever
direction the attacker wants. And forwarding is not encryption for services you
reach by other means: `curl http://web:8080/` is plain HTTP, and only traffic
that actually goes through the tunnel is protected.

## Cleanup

```bash
./lab.sh down
```

Keys stay in `keys/` so you can bring the lab back up without regenerating
them. Delete that directory if you want a clean slate.