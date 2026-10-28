#!/usr/bin/env bash
# CVE counts for every image the stack runs, official and hardened, by two
# scanners, written to reports/cves.md and reports/cves.json.
#
#   scripts/measure.sh
#
# Two scanners on purpose. Trivy counts what its database says is in each
# package and applies no vendor statement. Docker Scout applies the VEX
# statements Docker publishes with its hardened images ("not affected", with a
# reason), so its count for a DHI image is the vendor's own view. The gap
# between the two columns is that VEX, and a team adopting these images has to
# decide which number its policy reads.
#
# Needs docker, a login to dhi.io and Docker Hub (Scout needs one), and the
# images' platform from the host: a count on arm64 can differ from amd64.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set -a
# shellcheck disable=SC1091
. "$ROOT/ci-images.pins"
# shellcheck disable=SC1091
. "$ROOT/stacks/keycloak/template.lock"
set +a
out="$ROOT/reports"; mkdir -p "$out"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

git -c advice.detachedHead=false clone -q --depth 1 --branch "$TEMPLATE_TAG" "$TEMPLATE_REPO" "$work/template"
[ "$(git -C "$work/template" rev-parse HEAD)" = "$TEMPLATE_COMMIT" ] || { echo "template tag moved" >&2; exit 1; }
# ${A:-repo:${B:-tag@sha256:…}} → repo:tag@sha256:…, the official pins.
official() { grep -m1 "^  $1: &" "$work/template/$TEMPLATE_COMPOSE" \
  | sed -E -e 's/^[^$]*//' -e ':a' -e 's/\$\{[A-Z0-9_]+:-([^{}]*)\}/\1/' -e 'ta' | sed 's/}*$//'; }
hardened() { sed -n "/^  $1:/,/^  [a-z]/p" "$ROOT/stacks/keycloak/dhi.override.yml" \
  | sed -n 's/^    image: //p' | head -1; }

images=(
  "postgres|$(official postgres)|$(hardened postgres)"
  "postgres (backups)|$(official postgres)|$(hardened backups)"
  "keycloak|$(official keycloak)|$(hardened keycloak)"
  "traefik|$(official traefik)|$(hardened traefik)"
)

# The summary line of `docker scout quickview`, or nothing. Its whole output is
# kept, and shown when there is no summary to read, so a failed login or a
# changed format says what it was instead of ending the run in silence.
scout() {
  if docker scout version >/dev/null 2>&1; then docker scout quickview "$1" > "$work/s.out" 2>&1 || true
  else docker run --rm -e DOCKER_SCOUT_HUB_USER -e DOCKER_SCOUT_HUB_PASSWORD \
         -v "$HOME/.docker/config.json:/root/.docker/config.json:ro" \
         -v /var/run/docker.sock:/var/run/docker.sock "$SCOUT_IMAGE" quickview "$1" > "$work/s.out" 2>&1 || true; fi
  local line
  line="$(sed 's/\x1b\[[0-9;]*m//g' "$work/s.out" | grep -m1 -E '^ *Target' || true)"
  if [ -z "$line" ]; then
    echo "Docker Scout gave no summary for $1:" >&2; tail -n 15 "$work/s.out" >&2; return 0
  fi
  sed -E 's/.*│ *//' <<<"$line"
}

docker volume create trivy-cache >/dev/null
json="["
md="| Image | Official, Trivy | DHI, Trivy | Official, Docker Scout | DHI, Docker Scout |\n|---|---|---|---|---|\n"
for row in "${images[@]}"; do
  IFS='|' read -r name off dhi <<<"$row"
  cells=()
  for ref in "$off" "$dhi"; do
    docker pull -q "$ref" >/dev/null
    # The vulnerability databases come from Google's mirror: ghcr.io answers a
    # fresh CI runner with 429 often enough to fail a weekly run.
    if ! docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v trivy-cache:/root/.cache \
        "$TRIVY_IMAGE" image --quiet --format json --scanners vuln \
        --db-repository mirror.gcr.io/aquasec/trivy-db:2 \
        --java-db-repository mirror.gcr.io/aquasec/trivy-java-db:1 \
        "$ref" > "$work/t.json" 2> "$work/t.err"; then
      echo "Trivy failed on $ref:" >&2; tail -n 20 "$work/t.err" >&2; exit 1
    fi
    cells+=("$(python3 -I - "$work/t.json" <<'PY'
import json, sys
seen, c = set(), {}
for r in json.load(open(sys.argv[1])).get("Results", []):
    for v in r.get("Vulnerabilities") or []:
        k = (v["VulnerabilityID"], v["PkgName"])
        if k not in seen:
            seen.add(k)
            c[v["Severity"]] = c.get(v["Severity"], 0) + 1
print("%dC %dH %dM %dL" % tuple(c.get(s, 0) for s in ("CRITICAL", "HIGH", "MEDIUM", "LOW")))
PY
)")
  done
  for ref in "$off" "$dhi"; do
    s="$(scout "$ref" | tr -s ' ' | sed 's/ *$//')"
    cells+=("${s:-not read}")
  done
  md+="| $name | ${cells[0]} | ${cells[1]} | ${cells[2]} | ${cells[3]} |\n"
  json+="{\"image\":\"$name\",\"official\":\"$off\",\"hardened\":\"$dhi\",\"trivy\":[\"${cells[0]}\",\"${cells[1]}\"],\"scout\":[\"${cells[2]}\",\"${cells[3]}\"]},"
done
json="${json%,}]"
trivy_v="$(docker run --rm "$TRIVY_IMAGE" --version | head -1)"
if docker scout version >/dev/null 2>&1; then
  scout_v="the docker scout plugin $(docker scout version 2>/dev/null | grep -o -m1 'v[0-9][0-9.]*' || true)"
else
  scout_v="${SCOUT_IMAGE%%@*}"
fi
{
  printf '# CVE counts, %s\n\n' "$(date -u +%Y-%m-%d)"
  # shellcheck disable=SC2016  # the backticks are Markdown, printed as they are
  printf 'Platform %s. Trivy: %s, no VEX. Docker Scout: %s, with the VEX Docker publishes for its hardened images. Counted once per CVE and package; `?` is severity not yet assigned.\n\n' \
    "$(uname -m)" "$trivy_v" "$scout_v"
  printf '%b' "$md"
} > "$out/cves.md"
printf '%s\n' "$json" | python3 -I -m json.tool > "$out/cves.json"
cat "$out/cves.md"
# Written either way, so the run keeps what it did read; failed if any cell
# could not be read, so a gap in the table is never mistaken for a zero.
if grep -q 'not read' "$out/cves.md"; then echo "some counts could not be read" >&2; exit 1; fi
