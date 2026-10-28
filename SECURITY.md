# Security policy

## Supported versions

| Version | Supported |
|---|---|
| The latest release | yes |
| `main` | yes |
| Older releases | no |

## Reporting a vulnerability

Report privately through GitHub: **Security → Report a vulnerability** on this repository. Email to v@valdemar.ai also works. The process is described at [heyvaldemar.com/security](https://heyvaldemar.com/security/).

You can expect an acknowledgment within 7 days. There is no bounty program; valid, responsibly disclosed reports are credited in the changelog. Please do not open public issues for security reports.

## What this repository is

A reference, not a hosted service: an override file, a one-time volume move and the tests that prove them. A vulnerability here is most likely a change in `stacks/keycloak/dhi.override.yml` that weakens the template's own hardening, or a step in `scripts/move-postgres-volume.sh` that could damage a database.

## Supply chain

- Every image is pinned by digest: the hardened ones in the override, the tools in `ci-images.pins`, the official ones in the template at the commit in `stacks/keycloak/template.lock`.
- Actions are pinned by commit SHA and moved by Dependabot, merged only after Verify passes.
- Releases carry a signed source archive with build provenance.

## Credentials

Two Actions secrets, `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN`: dhi.io refuses anonymous pulls, and Docker Scout needs an account. The token is a read-only Docker Hub access token, never printed, and pull requests from forks do not receive it. The tests generate their own throwaway passwords for each run.
