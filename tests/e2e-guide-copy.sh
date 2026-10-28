#!/usr/bin/env bash
# shellcheck disable=SC2015  # pass and fail only print and count: `check && pass || fail` never runs both
# The "Direct data copy" route in Docker's guide to the DHI PostgreSQL image
# (docker-hardened-images/catalog, image/postgres/guides.md, Option 2), run as
# written and then with the two steps it is missing.
#
# As written, the copy stops on a directory that does not exist yet, and the
# guide's next command then starts the hardened image on a new, empty cluster.
# With the directory made, the copy keeps the official image's owner, uid 999,
# which the hardened image (uid 70) cannot read. Made and handed to uid 70,
# the data is there.
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
OFFICIAL="$(git -c advice.detachedHead=false clone -q --depth 1 --branch "$TEMPLATE_TAG" "$TEMPLATE_REPO" "$WORK/t" >/dev/null 2>&1; \
  grep -m1 '^  postgres: &' "$WORK/t/$TEMPLATE_COMPOSE" | sed -E -e 's/^[^$]*//' -e ':a' -e 's/\$\{[A-Z0-9_]+:-([^{}]*)\}/\1/' -e 'ta' | sed 's/}*$//')"
PG="$(sed -n 's/^    image: \(dhi\.io\/postgres:16@sha256:[0-9a-f]*\)$/\1/p' "$STACK/dhi.override.yml" | head -1)"
trap 'docker rm -f guide-old guide-new >/dev/null 2>&1; docker volume rm -f guide-old-data guide-new-data >/dev/null 2>&1; rm -rf "$WORK"' EXIT
echo "=== the guide's direct data copy ==="
echo "from $OFFICIAL to $PG"

fresh_old() {
  docker rm -f guide-old >/dev/null 2>&1; docker volume rm -f guide-old-data >/dev/null 2>&1
  docker run -d --name guide-old -e POSTGRES_PASSWORD=x -v guide-old-data:/var/lib/postgresql/data "$OFFICIAL" >/dev/null
  for _ in $(seq 1 30); do docker exec guide-old pg_isready -q -U postgres 2>/dev/null && break; sleep 2; done
  docker exec guide-old psql -U postgres -qc "create table kept(x int); insert into kept values (42);"
  docker stop guide-old >/dev/null
}
# copy <command> -> the copy's exit code, then the new container's state and the row
copy_and_start() {
  docker rm -f guide-new >/dev/null 2>&1; docker volume rm -f guide-new-data >/dev/null 2>&1
  local rc=0
  docker run --rm -v guide-old-data:/old -v guide-new-data:/new "$BUSYBOX_IMAGE" sh -c "$1" 2>/dev/null || rc=$?
  docker run --name guide-new -d -e POSTGRES_PASSWORD=mysecretpassword -v guide-new-data:/var/lib/postgresql "$PG" >/dev/null
  sleep 15
  local state row log
  state="$(docker inspect -f '{{.State.Status}}' guide-new)"
  row="$(docker exec guide-new psql -U postgres -tAc 'select x from kept' 2>/dev/null || true)"
  log="$(docker logs guide-new 2>&1)"
  echo "$rc|$state|$row|$log"
}

fresh_old
IFS='|' read -r rc state row _ <<<"$(copy_and_start 'cp -a /old/. /new/16/data/')"
if [ "$rc" != 0 ] && [ "$state" = running ] && [ -z "$row" ]; then
  pass "as written: the copy fails, and the next step starts the hardened image on an empty cluster"
else
  fail "as written: copy exit $rc, container $state, row '$row'"
fi

out="$(copy_and_start 'mkdir -p /new/16 && cp -a /old/. /new/16/data/')"
IFS='|' read -r rc state row _ <<<"$out"
if [ "$rc" = 0 ] && [[ "$out" == *"Permission denied"* ]] && [ -z "$row" ]; then
  pass "with the directory made: the copy keeps uid 999, and the hardened image cannot read it (Permission denied)"
else
  fail "with the directory made: copy exit $rc, container $state, row '$row'"
fi

IFS='|' read -r rc state row _ <<<"$(copy_and_start 'mkdir -p /new/16/data && cp -a /old/. /new/16/data/ && chown -R 70:70 /new/16')"
if [ "$rc" = 0 ] && [ "$state" = running ] && [ "$row" = 42 ]; then
  pass "made and handed to uid 70: the hardened image starts on the copied data"
else
  fail "made and handed to uid 70: copy exit $rc, container $state, row '$row'"
fi
summary
