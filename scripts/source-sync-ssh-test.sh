#!/usr/bin/env bash
# A loopback-only daemon, disposable keys/config, and no user SSH changes.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# OpenSSH checks every ancestor of AuthorizedKeysFile with StrictModes.
# Container HOME may be a shared, writable Actions mount. Use the account's
# real home from the user database, without changing HOME or its modes.
SSH_FIXTURE_PARENT=$(python3 -c 'import os, pwd; print(pwd.getpwuid(os.getuid()).pw_dir)')
WORK=$(mktemp -d "$SSH_FIXTURE_PARENT/restic-ssh-test.XXXXXX")
SSHD_PID=
cleanup() { if [[ -n "$SSHD_PID" ]]; then kill "$SSHD_PID" 2>/dev/null || true; wait "$SSHD_PID" 2>/dev/null || true; fi; rm -rf "$WORK"; }
trap cleanup EXIT
umask 077
ssh-keygen -q -t ed25519 -N '' -f "$WORK/host"
ssh-keygen -q -t ed25519 -N '' -f "$WORK/client"
cp "$WORK/client.pub" "$WORK/authorized_keys"
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
PAM=no
# Disposable Linux CI containers commonly have a password-locked root
# account. PAM permits its key-only login without modifying that account.
if [[ "$(uname -s)" == Linux && "$(id -u)" == 0 ]]; then PAM=yes; fi
printf '[127.0.0.1]:%s %s\n' "$PORT" "$(cat "$WORK/host.pub")" > "$WORK/known_hosts"
cat > "$WORK/sshd_config" <<EOF
ListenAddress 127.0.0.1
Port $PORT
HostKey $WORK/host
PidFile $WORK/sshd.pid
AuthorizedKeysFile $WORK/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM $PAM
PermitRootLogin yes
StrictModes yes
AllowUsers $(id -un)
EOF
cat > "$WORK/ssh_config" <<EOF
Host fixture-peer
  HostName 127.0.0.1
  Port $PORT
  User $(id -un)
  IdentityFile $WORK/client
  IdentitiesOnly yes
  UserKnownHostsFile $WORK/known_hosts
  GlobalKnownHostsFile /dev/null
EOF
/usr/sbin/sshd -D -e -f "$WORK/sshd_config" > "$WORK/server.log" 2>&1 &
SSHD_PID=$!
READY=0
for ((attempt = 0; attempt < 30; attempt++)); do
  if /usr/bin/ssh -F "$WORK/ssh_config" -o BatchMode=yes -o StrictHostKeyChecking=yes fixture-peer true > "$WORK/client.log" 2>&1; then READY=1; break; fi
  if ! kill -0 "$SSHD_PID" 2>/dev/null; then cat "$WORK/server.log"; cat "$WORK/client.log"; exit 1; fi
  sleep .1
done
if [[ "$READY" != 1 ]]; then cat "$WORK/server.log"; cat "$WORK/client.log"; exit 1; fi
export RESTIC_STATION_TEST_SSH_CONFIG="$WORK/ssh_config"
HELPER="${RESTIC_STATION_HELPER_OVERRIDE:-$REPO/.build/debug/restic-station-helper}"
RESTIC_STATION_TEST_SSH_HELPER="$(cd "$(dirname "$HELPER")" && pwd)/$(basename "$HELPER")"
export RESTIC_STATION_TEST_SSH_HELPER
# GNU rsync is installed only for this step on Linux; run the real local
# rsync transfer check here too.
swift test --package-path "$REPO/Core" --filter 'realSSHFixture|staleStagedFileIsReplaced'
