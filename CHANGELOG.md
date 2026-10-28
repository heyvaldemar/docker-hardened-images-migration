# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_(no unreleased changes yet)_

## [1.0.0] - 2026-10-28

### Added

- **The Keycloak template on Docker Hardened Images.** `stacks/keycloak/dhi.override.yml` runs heyvaldemar/keycloak-traefik-letsencrypt-docker-compose v1.8.13, unchanged, on DHI PostgreSQL 16, Keycloak 26 and Traefik 3, with the five changes the move needs: the database mounted at the DHI path, Traefik's own healthcheck, Keycloak as uid 65532 with a healthcheck in bash builtins, and the backup sidecar on the `-dev` image without the root-dropping entrypoint.
- **`scripts/move-postgres-volume.sh`.** Hands an existing database volume from uid 999 to uid 70, once, after checking that nothing is using it and that it holds a PostgreSQL data directory.
- **Tests on every change and every Monday.** A new install, the move of an install that runs on the official images, the data-loss trap on the database alone, and each of the five changes taken out to show the failure it fixes.
- **CVE counts by two scanners.** Trivy without VEX and Docker Scout with Docker's VEX, for each official image and its hardened counterpart.

[Unreleased]: https://github.com/heyvaldemar/docker-hardened-images-migration/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/heyvaldemar/docker-hardened-images-migration/releases/tag/v1.0.0
