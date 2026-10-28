#!/usr/bin/env bash
# shellcheck disable=SC2015  # pass and fail only print and count: `check && pass || fail` never runs both
# Each change in dhi.override.yml, taken out on its own: the stack must then
# fail exactly the way the change's comment says. A change that can be removed
# without that failure is not needed, or its comment is wrong.
#
#   tests/e2e-sabotage.sh postgres-volume | traefik-healthcheck | keycloak-user |
#                         keycloak-healthcheck | backups-entrypoint
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
change="${1:?which change}"
case "$change" in
  postgres-volume)      svc=postgres; key=volumes;     where=logs;   want="Read-only file system" ;;
  traefik-healthcheck)  svc=traefik;  key=healthcheck; where=health; want='"wget": executable file not found' ;;
  keycloak-user)        svc=keycloak; key=user;        where=logs;   want="AccessDeniedException" ;;
  keycloak-healthcheck) svc=keycloak; key=healthcheck; where=health; want="grep: command not found" ;;
  backups-entrypoint)   svc=backups;  key=entrypoint;  where=logs;   want="failed switching to 'postgres'" ;;
  *) echo "unknown change: $change" >&2; exit 2 ;;
esac
P="dhisab-${change}"
trap 'cleanup_project "$P"; rm -rf "$WORK"' EXIT
echo "=== without the $change change ==="
fetch_template
OVERRIDE="$WORK/sabotaged.yml"
python3 -I "$ROOT/tests/sabotage.py" "$STACK/dhi.override.yml" "$svc" "$key" > "$OVERRIDE" \
  || { fail "the $key under $svc is not in dhi.override.yml"; summary; exit; }
export OVERRIDE
cleanup_project "$P"
compose "$P" dhi up -d >/dev/null 2>&1 || true

container="$(compose "$P" dhi ps -a -q "$svc" | head -1)"
seen=""
deadline=$(( $(date +%s) + 420 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  if [ "$where" = logs ]; then
    seen="$(docker logs "$container" 2>&1 | grep -F -m1 "$want" || true)"
  else
    seen="$(docker inspect "$container" --format '{{range .State.Health.Log}}{{.Output}}{{end}}' 2>/dev/null | grep -F -m1 "$want" || true)"
  fi
  [ -n "$seen" ] && break
  sleep 10
done
if [ -n "$seen" ]; then
  pass "$svc fails as the comment says: $want"
else
  fail "$svc did not fail with '$want' within 7 minutes"
  docker logs --tail 15 "$container" 2>&1 | sed 's/^/    /'
fi
summary
