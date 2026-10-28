# docker-hardened-images-migration

[![Verify](https://github.com/heyvaldemar/docker-hardened-images-migration/actions/workflows/verify.yml/badge.svg?branch=main)](https://github.com/heyvaldemar/docker-hardened-images-migration/actions/workflows/verify.yml)

Moving a production Docker Compose stack from official images to [Docker Hardened Images](https://docs.docker.com/dhi/), with every change the move needs, each proven by the failure it fixes, and an existing install moved without losing its data.

The stack is [keycloak-traefik-letsencrypt-docker-compose](https://github.com/heyvaldemar/keycloak-traefik-letsencrypt-docker-compose) at v1.8.13: Traefik, Keycloak, PostgreSQL and a backup sidecar, already hardened with read-only roots, dropped capabilities and non-root users. The template is used as it is. [`stacks/keycloak/dhi.override.yml`](stacks/keycloak/dhi.override.yml) goes next to it and holds every difference.

## What swapping the images alone breaks

The template on DHI images, with nothing else changed:

| Service | What broke | Why | The change |
|---|---|---|---|
| PostgreSQL | `initdb: error: could not change permissions of directory "/var/lib/postgresql/16/data": Read-only file system` | DHI keeps the cluster in `/var/lib/postgresql/16/data` and runs as uid 70; the official image uses `/var/lib/postgresql/data` and uid 999 | Mount the volume at the DHI path |
| Traefik | Unhealthy forever, so nothing that waits for it starts | The healthcheck calls `wget`, which the image does not have | `traefik healthcheck --ping` |
| Keycloak | A restart loop: `AccessDeniedException: /opt/keycloak/lib/quarkus/...` | The template pins the official image's uid 1000; this image's files belong to 65532, and the first start rebuilds Keycloak into them | Run as 65532 |
| Keycloak | Unhealthy: `grep: command not found` | The image has bash but no `grep`, `cat` or `tee` | A healthcheck in bash builtins |
| Backups | A restart loop: `failed switching to 'postgres': operation not permitted` | The loop is a shell script, so it needs the `-dev` image, whose entrypoint always drops root, which needs the SETUID the template takes away | The `-dev` image with `entrypoint: []` |

Each row is a test: `tests/e2e-sabotage.sh` takes that one change out of the override and requires exactly that failure.

## The trap: a healthy database that keeps nothing

On the official image's mount path, without a read-only root, the hardened PostgreSQL starts, answers, accepts writes, and keeps everything inside the container. The named volume stays empty, and the next recreate starts from nothing. Nothing in the logs says so.

`tests/e2e-trap.sh` shows it happening: a row written on the official path, zero files on the volume, and the row gone after a recreate. The same test on the DHI path keeps the row. The template's read-only root is what turned this into the loud failure in the first row of the table; a stack without one loses its data quietly.

## Moving an install that already runs

1. Stop the stack. Its volumes stay.
2. Hand the database volume to uid 70, once: `scripts/move-postgres-volume.sh keycloak_keycloak-postgres`. It refuses while anything uses the volume, checks that the volume holds a PostgreSQL data directory, and changes only the owner of its files from 999 to 70. `--check` says what it would do.
3. Start with the override: `docker compose -f keycloak-traefik-letsencrypt-docker-compose.yml -f dhi.override.yml up -d`.

Skip step 2, and the hardened PostgreSQL stops with `Permission denied` and starts nothing. `tests/e2e-upgrade.sh` shows that refusal first, then does the move: a realm created on the official images is there on DHI.

## CVE counts

From [run 40742373013](https://github.com/heyvaldemar/docker-hardened-images-migration/actions/runs/40742373013), on amd64, counted once per CVE and package (C critical, H high, M medium, L low, ? not yet rated):

| Image | Official, Trivy | DHI, Trivy | Official, Docker Scout | DHI, Docker Scout |
|---|---|---|---|---|
| postgres | 2C 86H 140M 141L | 1C 16H 90M 118L | 4C 33H 30M 55L 1? | 0C 3H 5M 50L |
| postgres, `-dev` for backups | 2C 86H 140M 141L | 1C 39H 107M 139L | 4C 33H 30M 55L 1? | 0C 3H 6M 57L |
| keycloak | 0C 3H 55M 35L | 0C 4H 30M 21L | 1C 12H 14M 6L | 0C 2H 2M 17L |
| traefik | 0C 1H 0M 0L | 0C 0H 0M 0L | 0C 2H 0M 0L 4? | 0C 2H 0M 0L 3? |

Two scanners, because they disagree. Trivy (0.76.1) applies no vendor statements. Docker Scout applies the VEX that Docker publishes with these images: a "not affected" statement per CVE, with a reason. The gap between the two hardened columns is that VEX.

- **The hardened PostgreSQL and Keycloak have fewer critical and high findings by Docker Scout; Traefik has the same 2 high on both.** By Trivy, PostgreSQL and Traefik have fewer, and Keycloak has more: 4 high on DHI against 3 on the official image.
- **Which number counts is a policy decision.** A gate that reads Trivy's will not see the "near zero" a gate reading Scout's sees. Decide which scanner and which VEX the policy trusts before the move, not after.
- **The `-dev` image costs more than the runtime one,** by Trivy 39 high against 16, because it carries a shell and a package manager. Only the backup sidecar runs it.

Verify measures again every Monday, on the same pinned images and the scanners' current databases.

## What the move costs

- **A login for every pull.** dhi.io refuses anonymous pulls, the free images included: its token endpoint answers 401 without credentials. Every host and CI runner that pulls needs a Docker account, and an air-gapped install mirrors the images with one.
- **Healthchecks rewritten.** Anything that ran a shell tool inside a container (`wget`, `grep`, a `sh -c` loop) is gone or has to move to a `-dev` image.
- **A uid change per service,** with a one-time ownership change for every volume that already holds data.

## How it is proven

`Verify` runs on every change and every Monday, each test on a fresh runner:

| Test | What it requires |
|---|---|
| `tests/e2e-fresh.sh` | A new install comes up healthy on DHI, Keycloak answers through Traefik with the right OpenID issuer, and a realm outlives a recreate of the database and Keycloak |
| `tests/e2e-upgrade.sh` | The official install comes up and gets a realm; the hardened PostgreSQL refuses its volume until the move; after the move the realm is there |
| `tests/e2e-trap.sh` | The official mount path loses the data; the DHI path keeps it |
| `tests/e2e-sabotage.sh <change>` | Each of the five changes, taken out on its own, fails the way its comment says |
| `scripts/measure.sh` | The CVE table above, by both scanners |

## What it does not do

- **One stack.** The findings are about PostgreSQL, Keycloak and Traefik. Another image has its own uid, paths and missing tools; the method carries over, the override does not.
- **Docker Compose 2.24.4 or newer.** The override uses [`!override`](https://docs.docker.com/reference/compose-file/merge/) to replace the database mount instead of adding a second one.
- **The Community images only.** FIPS and STIG variants and DHI Enterprise customizations are not exercised.
- **Image updates by hand.** The DHI digests are pinned in the override and moved deliberately, each move proven by Verify.

## Repository

| Path | What it is |
|---|---|
| `stacks/keycloak/dhi.override.yml` | Every difference from the template, each with what broke without it |
| `stacks/keycloak/template.lock` | The template's release and commit |
| `scripts/move-postgres-volume.sh` | The one-time handover of an existing database volume |
| `scripts/measure.sh` | The CVE counts by Trivy and Docker Scout |
| `tests/` | The four tests above, and `sabotage.py`, which removes one change from the override |
| `ci-images.pins` | Every tool image, pinned by digest |

## Questions, bugs and changes

Open an [issue](https://github.com/heyvaldemar/docker-hardened-images-migration/issues) for a bug, a question or an idea. Security reports go privately, as [SECURITY.md](SECURITY.md) describes.

## How this is built

One maintainer and an AI agent. The agent writes most of the code; the decisions are mine, and so is the verification. Nothing merges on the agent's report that it works: it merges on the checks above, and each of them has been shown the failure it exists to catch. The rules the agent works under are in [AGENTS.md](AGENTS.md).

## License

[MIT](LICENSE).
