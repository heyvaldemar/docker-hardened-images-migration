#!/usr/bin/env bash
# shellcheck disable=SC2015  # pass and fail only print and count: `check && pass || fail` never runs both
# The trap this migration is most likely to fall into, shown on the database
# alone: the hardened PostgreSQL on the official image's mount path.
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
PG="$(sed -n 's/^    image: \(dhi\.io\/postgres:16@sha256:[0-9a-f]*\)$/\1/p' "$STACK/dhi.override.yml" | head -1)"
trap 'docker rm -f dhitrap >/dev/null 2>&1; docker volume rm -f dhitrap-a dhitrap-b >/dev/null 2>&1; rm -rf "$WORK"' EXIT
echo "=== the hardened PostgreSQL on two mount paths ==="
echo "image: $PG"

run_pg() { docker rm -f dhitrap >/dev/null 2>&1; docker run -d --name dhitrap -e POSTGRES_PASSWORD=trap -v "$1:$2" "$PG" >/dev/null; for _ in $(seq 1 30); do docker exec dhitrap pg_isready -q -U postgres 2>/dev/null && return 0; sleep 2; done; return 1; }
row() { docker exec dhitrap psql -U postgres -tAc "select x from kept" 2>/dev/null; }

for case in "dhitrap-a:/var/lib/postgresql/data:official" "dhitrap-b:/var/lib/postgresql/16/data:hardened"; do
  vol="${case%%:*}"; rest="${case#*:}"; path="${rest%%:*}"; name="${rest#*:}"
  docker volume rm -f "$vol" >/dev/null 2>&1
  run_pg "$vol" "$path" || { fail "PostgreSQL did not start on the $name path"; continue; }
  docker exec dhitrap psql -U postgres -qc "create table kept(x int); insert into kept values (42);"
  [ "$(row)" = 42 ] || fail "could not write a row on the $name path"
  nfiles="$(docker run --rm -v "$vol:/v:ro" "$HELPER_IMAGE" sh -c 'ls -A /v | wc -l' | tr -d ' ')"
  run_pg "$vol" "$path" >/dev/null || true
  after="$(row)"
  if [ "$name" = official ]; then
    if [ "$nfiles" = 0 ] && [ -z "$after" ]; then
      pass "on the official path the volume stays empty and the row is gone after a recreate, while the database looked healthy throughout"
    else
      fail "on the official path: $nfiles files on the volume, row after recreate '$after'"
    fi
  else
    if [ "$nfiles" != 0 ] && [ "$after" = 42 ]; then
      pass "on the hardened path the data is on the volume and outlives the recreate"
    else
      fail "on the hardened path: $nfiles files on the volume, row after recreate '$after'"
    fi
  fi
done
summary
