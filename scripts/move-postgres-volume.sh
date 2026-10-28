#!/usr/bin/env bash
# Hand an existing PostgreSQL volume from the official image to the hardened
# one. Run it once, with the stack stopped, before the first start on DHI.
#
#   scripts/move-postgres-volume.sh <volume>          e.g. keycloak_keycloak-postgres
#   scripts/move-postgres-volume.sh <volume> --check  say what it would do
#
# The official image runs PostgreSQL as uid 999; the hardened image runs it as
# uid 70 and has no root step that could fix ownership itself. On a volume
# still owned by 999 it stops with "could not access directory ...:
# Permission denied" and starts nothing. The data files are the same: only
# their owner changes. Nothing else is touched.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set -a
# shellcheck disable=SC1091
. "$ROOT/ci-images.pins"
set +a
vol="${1:?usage: move-postgres-volume.sh <volume> [--check]}"
check="${2:-}"

docker volume inspect "$vol" >/dev/null 2>&1 || { echo "no volume named $vol" >&2; exit 1; }
# A running server holding the files must not have their owner changed under it.
users="$(docker ps --filter "volume=$vol" --format '{{.Names}}')"
[ -z "$users" ] || { echo "stop the stack first; $vol is in use by: $users" >&2; exit 1; }

peek() { docker run --rm --network none -v "$vol:/v:ro" "$HELPER_IMAGE" sh -c "$1"; }
[ "$(peek 'test -f /v/PG_VERSION && echo yes || echo no')" = yes ] \
  || { echo "$vol has no PG_VERSION at its root: not a PostgreSQL data directory in the official layout" >&2; exit 1; }
owner="$(peek 'stat -c %u:%g /v')"
version="$(peek 'cat /v/PG_VERSION')"
echo "$vol: PostgreSQL $version data, owned by $owner"
case "$owner" in
  70:70) echo "already owned by uid 70: nothing to do"; exit 0 ;;
  999:999) ;;
  *) echo "owned by $owner, which is neither the official image's 999 nor DHI's 70: refusing to guess" >&2; exit 1 ;;
esac
if [ "$check" = --check ]; then echo "would change the owner of every file from 999:999 to 70:70"; exit 0; fi

docker run --rm --network none -v "$vol:/v" "$HELPER_IMAGE" chown -R 70:70 /v
left="$(peek 'find /v ! -user 70 | wc -l')"
[ "$left" = 0 ] || { echo "$left files are still not owned by uid 70" >&2; exit 1; }
echo "$vol: every file now owned by 70:70; start the stack with dhi.override.yml"
