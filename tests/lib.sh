# Shared by the e2e tests: the pinned template, its .env, the compose calls,
# and the checks every test makes. Sourced, never run.
# shellcheck shell=bash

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STACK="$ROOT/stacks/keycloak"
WORK="${WORK:-$(mktemp -d)}"
PASSED=0
FAILED=0
pass() { echo "  PASS: $1"; PASSED=$((PASSED + 1)); }
fail() { echo "  FAIL: $1"; FAILED=$((FAILED + 1)); }
summary() { echo; echo "passed: $PASSED   failed: $FAILED"; [ "$FAILED" -eq 0 ]; }

set -a
# shellcheck disable=SC1091
. "$ROOT/ci-images.pins"
# shellcheck disable=SC1091
. "$STACK/template.lock"
set +a

# The template at the locked commit, with a test .env of throwaway secrets.
fetch_template() {
  rm -rf "$WORK/template"
  git -c advice.detachedHead=false clone -q --depth 1 --branch "$TEMPLATE_TAG" "$TEMPLATE_REPO" "$WORK/template"
  local got
  got="$(git -C "$WORK/template" rev-parse HEAD)"
  [ "$got" = "$TEMPLATE_COMMIT" ] || { echo "$TEMPLATE_TAG is $got, the lock says $TEMPLATE_COMMIT" >&2; exit 1; }
  local pw1 pw2
  pw1="$(openssl rand -hex 16)"; pw2="$(openssl rand -hex 16)"
  cat > "$WORK/template/.env" <<ENV
TRAEFIK_LOG_LEVEL=WARN
TRAEFIK_ACME_EMAIL=ci@example.com
TRAEFIK_HOSTNAME=traefik.keycloak.test
TRAEFIK_BASIC_AUTH=traefikadmin:\$\$2y\$\$10\$\$sMzJfirKC75x/hVpiINeZOiSm.Jkity9cn4KwNkRvO7hSQVFc5FLO
KEYCLOAK_DB_NAME=keycloakdb
KEYCLOAK_DB_USER=keycloakdbuser
KEYCLOAK_DB_PASSWORD=$pw1
KEYCLOAK_ADMIN_USERNAME=keycloakadmin
KEYCLOAK_ADMIN_PASSWORD=$pw2
KEYCLOAK_HOSTNAME=keycloak.test
KEYCLOAK_BACKUP_INIT_SLEEP=30m
KEYCLOAK_BACKUP_INTERVAL=24h
KEYCLOAK_POSTGRES_BACKUP_PRUNE_DAYS=7
KEYCLOAK_POSTGRES_BACKUPS_PATH=/srv/keycloak-postgres/backups
KEYCLOAK_POSTGRES_BACKUP_NAME=keycloak-postgres-backup
ENV
  chmod 600 "$WORK/template/.env"
  docker network create keycloak-network >/dev/null 2>&1 || true
  docker network create traefik-network >/dev/null 2>&1 || true
}

# compose <project> official|dhi <args...>
compose() {
  local project="$1" flavour="$2"; shift 2
  local files=(-f "$WORK/template/$TEMPLATE_COMPOSE")
  [ "$flavour" = dhi ] && files+=(-f "${OVERRIDE:-$STACK/dhi.override.yml}")
  docker compose --project-directory "$WORK/template" "${files[@]}" -p "$project" "$@"
}

# Wait until every long-running service is healthy (or running, if it has no
# healthcheck). Prints the states and returns 1 on the deadline.
wait_healthy() {
  local project="$1" flavour="$2" seconds="${3:-600}" st=""
  local deadline=$(( $(date +%s) + seconds ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    st="$(compose "$project" "$flavour" ps -a --format '{{.Service}}={{.State}}/{{.Health}}' | sort | tr '\n' ' ')"
    if ! [[ "$st" =~ starting|created|restarting|unhealthy|exited|dead ]] \
       && [ "$(grep -o running <<<"$st" | wc -l | tr -d ' ')" -ge 4 ]; then
      echo "  $st"; return 0
    fi
    sleep 10
  done
  echo "  $st"; return 1
}

# Keycloak through Traefik, the way a browser reaches it. Traefik answers 404
# for a moment after a container is recreated, while it picks up the new
# route, so a check retries before it believes an answer.
via_traefik() { curl -s -k -o /dev/null -w '%{http_code}' --resolve keycloak.test:443:127.0.0.1 "https://keycloak.test$1"; }
expect_status() {
  local path="$1" want="$2" got=""
  for _ in $(seq 1 30); do got="$(via_traefik "$path")"; [ "$got" = "$want" ] && break; sleep 5; done
  echo "$got"
}

admin_token() {
  # shellcheck disable=SC1091
  . "$WORK/template/.env"
  curl -s -k --resolve keycloak.test:443:127.0.0.1 -d grant_type=password -d client_id=admin-cli \
    --data-urlencode "username=$KEYCLOAK_ADMIN_USERNAME" --data-urlencode "password=$KEYCLOAK_ADMIN_PASSWORD" \
    https://keycloak.test/realms/master/protocol/openid-connect/token \
    | python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("access_token", ""))'
}

# A realm is the data that has to survive: it lives only in the database.
create_realm() {
  local tok
  tok="$(admin_token)"
  [ -n "$tok" ] || { echo "no admin token" >&2; return 1; }
  printf 'header = "Authorization: Bearer %s"\n' "$tok" | curl -s -k -o /dev/null -w '%{http_code}' -K - \
    --resolve keycloak.test:443:127.0.0.1 -H 'Content-Type: application/json' \
    -d "{\"realm\":\"$1\",\"enabled\":true}" https://keycloak.test/admin/realms
}

cleanup_project() {
  compose "$1" official down -v --remove-orphans >/dev/null 2>&1 || true
  compose "$1" dhi down -v --remove-orphans >/dev/null 2>&1 || true
}
