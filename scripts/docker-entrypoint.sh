#!/bin/sh
set -e

# Capture runtime UID/GID from environment variables, defaulting to 1000
PUID=${USER_UID:-1000}
PGID=${USER_GID:-1000}

# Without root we can neither remap the node user (usermod/groupmod/chown)
# nor switch users (gosu needs CAP_SETUID/CAP_SETGID), so exec directly.
# This covers Kubernetes restricted PodSecurity (runAsNonRoot + runAsUser)
# as well as platforms that assign arbitrary UIDs (e.g. OpenShift); for the
# latter a UID/GID mismatch is unfixable here, so warn instead of letting
# usermod fail cryptically and keep volume-permission issues diagnosable.
if [ "$(id -u)" -ne 0 ]; then
    if [ "$(id -u)" -ne "$PUID" ] || [ "$(id -g)" -ne "$PGID" ]; then
        echo "docker-entrypoint.sh: running unprivileged as $(id -u):$(id -g); cannot remap to requested ${PUID}:${PGID}" >&2
    fi
    exec "$@"
fi

# Adjust the node user's UID/GID if they differ from the runtime request
# and fix volume ownership only when a remap is needed
changed=0

if [ "$(id -u node)" -ne "$PUID" ]; then
    echo "Updating node UID to $PUID"
    usermod -o -u "$PUID" node
    changed=1
fi

if [ "$(id -g node)" -ne "$PGID" ]; then
    echo "Updating node GID to $PGID"
    groupmod -o -g "$PGID" node
    usermod -g "$PGID" node
    changed=1
fi

# A freshly-mounted platform volume (e.g. Railway) shadows the build-time chown with a
# root-owned dir even when no UID/GID remap occurred — always ensure node owns the data dir.
# Always repair data-dir ownership at boot (files created by root shells/CLI runs on the
# shared volume would otherwise wedge the unprivileged app — EACCES on .env/config).
chown -R node:node /paperclip

# Normalize a CLI-created instance config for containerized serving: its local bind host
# ("127.0.0.1") overrides the env HOST and hides the server from platform healthchecks.
if [ -f /paperclip/instances/default/config.json ]; then
    sed -i 's@"host": "127.0.0.1"@"host": "0.0.0.0"@' /paperclip/instances/default/config.json
fi

# Optional tailnet bridge for SSH execution targets: when TS_AUTHKEY is set, join the
# tailnet (userspace) and expose MAC_SSH_TAILNET_HOST:22 on 127.0.0.1:2222 for the ssh
# driver (plain TCP in, tailscale-dialed out). Inert without the env vars.
if [ -n "$TS_AUTHKEY" ]; then
    mkdir -p /paperclip/tailscale
    tailscaled --state=/paperclip/tailscale/tailscaled.state \
        --socket=/paperclip/tailscale/tailscaled.sock \
        --tun=userspace-networking >/tmp/tailscaled.log 2>&1 &
    for i in 1 2 3 4 5 6 7 8 9 10; do
        tailscale --socket=/paperclip/tailscale/tailscaled.sock up \
            --authkey="$TS_AUTHKEY" --hostname=paperclip-railway --accept-dns=true \
            && break || sleep 2
    done
    if [ -n "$MAC_SSH_TAILNET_HOST" ]; then
        socat TCP-LISTEN:2222,bind=127.0.0.1,fork,reuseaddr \
            EXEC:"tailscale --socket=/paperclip/tailscale/tailscaled.sock nc $MAC_SSH_TAILNET_HOST 22" \
            >/tmp/socat.log 2>&1 &
    fi
fi

exec gosu node "$@"
