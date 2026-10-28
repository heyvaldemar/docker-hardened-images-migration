# Working on this repository as an agent

Most of the code here is written by an AI agent, and the decisions and the verification are the maintainer's. This file is what the agent is held to. A reviewer can hold it to the same rules.

## What this repository claims

Every change in `stacks/keycloak/dhi.override.yml` exists because the template failed without it on these images, and its comment says how. `tests/e2e-sabotage.sh` takes each change out on its own and requires that failure; a change it cannot show is removed or its comment corrected. Every number in the README comes from a named CI run on amd64, and the run is linked.

## Before changing anything

- A new change in the override ships with a case in `tests/e2e-sabotage.sh`: the service, the key, and the exact failure text it fixes.
- Moving a DHI image to a new digest runs Verify on a branch first; a new major line is a new decision, written down in the README.
- The template is used as it is, at the commit in `template.lock`. Nothing here edits it. A newer template release is a lock change, proven by Verify like any other.

## A check is trusted only after it has failed

The data-loss trap is shown happening (`tests/e2e-trap.sh`), and the refusal of an unmoved volume is shown before the move (`tests/e2e-upgrade.sh`). A check that has never been seen to fail proves nothing.

## Shell traps that have bitten here

`| grep -q` under `set -o pipefail` reports a failure when grep stops reading early: match in bash instead (`[[ $x == *text* ]]`). A command substitution that greps for a line which is not there ends a `set -e` script in silence: keep the whole output and say what was missing.
