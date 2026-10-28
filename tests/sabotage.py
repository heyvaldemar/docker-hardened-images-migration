#!/usr/bin/env python3
"""Print dhi.override.yml without one of its changes.

    python3 tests/sabotage.py stacks/keycloak/dhi.override.yml keycloak user

Removes the key, with its value and the comment lines right above it, from
the named service. The template's own setting for that key then applies
again, which is exactly the stack the change was written to fix. Exits 1 if
the service or the key is not there, so a renamed change cannot pass by
sabotaging nothing.
"""
import sys

path, service, key = sys.argv[1:4]
lines = open(path).read().split("\n")
out, i, in_service, removed = [], 0, False, False
while i < len(lines):
    line = lines[i]
    if line.startswith("  ") and not line.startswith("   ") and line.strip().endswith(":"):
        in_service = line.strip() == service + ":"
    if in_service and line.startswith("    " + key + ":"):
        while out and out[-1].startswith("    #"):
            out.pop()
        i += 1
        while i < len(lines) and (lines[i].startswith("     ") or lines[i].strip() == ""):
            i += 1
        removed = True
        continue
    out.append(line)
    i += 1
if not removed:
    sys.exit("no %s under %s in %s" % (key, service, path))
sys.stdout.write("\n".join(out))
