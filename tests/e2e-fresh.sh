#!/usr/bin/env bash
# shellcheck disable=SC2015  # pass and fail only print and count: `check && pass || fail` never runs both
# A new install on Docker Hardened Images: the template's own checks, and the
# one a hardened image makes urgent: does the data outlive its containers?
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
P=dhifresh
trap 'cleanup_project "$P"; rm -rf "$WORK"' EXIT
echo "=== a new install on Docker Hardened Images ==="
fetch_template
cleanup_project "$P"
compose "$P" dhi up -d >/dev/null 2>&1

if wait_healthy "$P" dhi; then pass "every service is up and healthy on DHI"; else fail "the stack did not come up healthy on DHI"; fi
[ "$(expect_status / 302)" = 302 ] && pass "Keycloak answers through Traefik" || fail "Keycloak does not answer through Traefik"
issuer="$(curl -s -k --resolve keycloak.test:443:127.0.0.1 https://keycloak.test/realms/master/.well-known/openid-configuration \
  | python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("issuer",""))' 2>/dev/null)"
[ "$issuer" = "https://keycloak.test/realms/master" ] && pass "OpenID discovery names the public issuer" || fail "OpenID discovery says '$issuer'"
[ "$(create_realm fresh-proof)" = 201 ] && pass "a realm is created" || fail "the realm could not be created"

compose "$P" dhi up -d --force-recreate postgres keycloak >/dev/null 2>&1
wait_healthy "$P" dhi >/dev/null || true
[ "$(expect_status /realms/fresh-proof 200)" = 200 ] && pass "the realm outlives a recreate of the database and Keycloak" \
  || fail "the realm is gone after a recreate: the data was not on the volume"
vol="${P}_keycloak-postgres"
owner="$(docker run --rm -v "$vol:/v:ro" "$HELPER_IMAGE" stat -c %u:%g /v)"
pgv="$(docker run --rm -v "$vol:/v:ro" "$HELPER_IMAGE" sh -c 'cat /v/PG_VERSION 2>/dev/null')"
[ "$owner" = 70:70 ] && [ "$pgv" = 16 ] && pass "the cluster is on the named volume, owned by uid 70" \
  || fail "the named volume holds PG_VERSION='$pgv', owner $owner"
summary
