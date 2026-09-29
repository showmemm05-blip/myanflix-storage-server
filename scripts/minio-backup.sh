#!/usr/bin/env bash
#
# Copy the MinIO bucket to a second place with `mc mirror`, then check that
# every object made it.
#
#   MINIO_BACKUP_TARGET=/Volumes/SSD/myanflix-media bash scripts/minio-backup.sh
#   MINIO_BACKUP_TARGET=backup/myanflix-media bash scripts/minio-backup.sh
#   bash scripts/minio-backup.sh images/          # one prefix only
#
# MINIO_BACKUP_TARGET (here or in .env) is where the bucket's keys land:
#   - an absolute path: a folder on this machine or a mounted drive. Keep it
#     on a DIFFERENT disk from the one MinIO uses, or it is not a backup.
#   - <alias>/<bucket>[/<path>]: another S3 or MinIO, reached with mc's own
#     MC_HOST_<alias>=https://<access-key>:<secret-key>@<host> variable (here
#     or in .env). Every MC_HOST_* variable is passed through to mc.
#
# What is copied: the whole bucket except temp/ (upload staging). Nothing is
# ever deleted from the copy, so a title deleted by mistake can still be
# restored; clear old objects from the copy by hand when space matters.
#
# mc runs in a throwaway container made from the SAME image the running
# minio service uses (so there is nothing to install or pull), inside that
# service's network, so it reaches MinIO at localhost:9000 on a laptop and on
# the storage VPS alike. It signs in with the root user from .env, the same
# values docker-compose.yml gives MinIO.
#
# Restore is the same command the other way round, for example one title:
#   mc mirror <target>/videos/<id> src/movies/videos/<id>
# (see "Backups" in ../README.md).
#
set -euo pipefail

cd "$(dirname "$0")/.."

# A value given on the command line wins over .env.
cli_target="${MINIO_BACKUP_TARGET:-}"
if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi
TARGET="${cli_target:-${MINIO_BACKUP_TARGET:-}}"
TARGET="${TARGET%/}"
BUCKET="${MINIO_BUCKET:-movies}"
PREFIX="${1:-}"
PREFIX="${PREFIX#/}"
PREFIX="${PREFIX%/}"

if [[ -z "$TARGET" ]]; then
  echo "error: MINIO_BACKUP_TARGET is not set (an absolute folder, or <alias>/<bucket>)." >&2
  exit 1
fi

container="$(docker compose ps -q minio 2>/dev/null || true)"
if [[ -z "$container" ]]; then
  echo "error: the minio service isn't running (docker compose ps -q minio returned nothing)." >&2
  echo "       start it with: docker compose up -d minio" >&2
  exit 1
fi
image="$(docker inspect -f '{{.Config.Image}}' "$container")"

run_args=(--rm --network "container:$container" -e MC_CONFIG_DIR=/tmp/.mc
  -e SRC_USER -e SRC_PASS -e MIRROR_SRC -e MIRROR_DST)
if [[ "$TARGET" == /* ]]; then
  mkdir -p "$TARGET"
  # Files end up owned by whoever runs this, not by root.
  run_args+=(--user "$(id -u):$(id -g)" -v "$TARGET:/backup")
  dest="/backup"
  shown="$TARGET"
else
  dest="$TARGET"
  shown="$TARGET"
fi
while IFS= read -r name; do
  [[ -n "$name" ]] && run_args+=(-e "$name")
done <<EOF
$(env | sed -n 's/^\(MC_HOST_[A-Za-z0-9_]*\)=.*/\1/p')
EOF

# Passed by name (-e VAR, no value) so the password never shows up in a
# process list.
export SRC_USER="${MINIO_ROOT_USER:-myanflix}"
export SRC_PASS="${MINIO_ROOT_PASSWORD:-change-me-locally}"

mc_in() {
  docker run "${run_args[@]}" --entrypoint sh "$image" -c \
    'mc alias set src http://localhost:9000 "$SRC_USER" "$SRC_PASS" >/dev/null && '"$1"
}

MIRROR_SRC="src/$BUCKET${PREFIX:+/$PREFIX}"
MIRROR_DST="$dest${PREFIX:+/$PREFIX}"
export MIRROR_SRC="${MIRROR_SRC%/}" MIRROR_DST="${MIRROR_DST%/}"
echo "→ mirroring $BUCKET/${PREFIX} → $shown${PREFIX:+/$PREFIX}"
mc_in 'mc mirror --quiet --no-color --overwrite --exclude "temp/*" "$MIRROR_SRC" "$MIRROR_DST"' > /dev/null

# A copy that was not checked is not a backup. `mc diff` compares name, size
# and time: `<` = only in the bucket (missing from the copy), `!` = newer in
# the bucket (the copy is stale). Both are failures; `>` (only in the copy)
# is an object deleted from the bucket since, which is expected.
diff_out="$(mc_in 'mc diff --quiet --no-color "$MIRROR_SRC" "$MIRROR_DST"')"
missing="$(printf '%s\n' "$diff_out" | grep -E '^[<!] ' | grep -v "/$BUCKET/temp/" || true)"
if [[ -n "$missing" ]]; then
  echo "error: the copy is incomplete:" >&2
  printf '%s\n' "$missing" | head -20 >&2
  exit 1
fi

objects="$(mc_in 'mc ls --recursive --no-color "$MIRROR_DST"' | wc -l | tr -d ' ')"
echo "✅ $shown${PREFIX:+/$PREFIX} matches the bucket ($objects objects in the copy)"
