#!/usr/bin/env bash
# shellcheck disable=SC2015  # pass and fail only print and count: `check && pass || fail` never runs both
# An install that already runs on the official images moves to Docker Hardened
# Images and keeps its data. Shown the failure first: without the volume move,
# the hardened PostgreSQL refuses the old volume.
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
P=dhiupgrade
trap 'cleanup_project "$P"; rm -rf "$WORK"' EXIT
echo "=== an official install moves to Docker Hardened Images ==="
fetch_template
cleanup_project "$P"
compose "$P" official up -d >/dev/null 2>&1
if wait_healthy "$P" official; then pass "the template comes up on its official images"; else fail "the official template did not come up"; fi
[ "$(create_realm migration-proof)" = 201 ] && pass "a realm is created on the official images" || fail "the realm could not be created"
compose "$P" official down >/dev/null 2>&1
vol="${P}_keycloak-postgres"

compose "$P" dhi up -d postgres >/dev/null 2>&1
sleep 30
# Read whole, then matched in bash: `| grep -q` under pipefail reports a
# failure when grep stops reading before the writer is done.
pglog="$(compose "$P" dhi logs postgres 2>&1)"
if [[ "$pglog" == *"Permission denied"* ]]; then
  pass "without the move, the hardened PostgreSQL refuses the old volume (Permission denied)"
else
  fail "the hardened PostgreSQL did not refuse a volume owned by uid 999"
fi
compose "$P" dhi down >/dev/null 2>&1

if "$ROOT/scripts/move-postgres-volume.sh" "$vol"; then pass "the volume is handed to uid 70"; else fail "the volume move failed"; fi
compose "$P" dhi up -d >/dev/null 2>&1
if wait_healthy "$P" dhi; then pass "the same install is up and healthy on DHI"; else fail "the moved install did not come up on DHI"; fi
[ "$(expect_status /realms/migration-proof 200)" = 200 ] && pass "the realm made on the official images is there on DHI" \
  || fail "the realm made on the official images is gone"
summary
