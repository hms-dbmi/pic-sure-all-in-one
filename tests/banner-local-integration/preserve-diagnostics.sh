#!/usr/bin/env bash
set -euo pipefail

runtime_root=${1:?runtime root is required}
diagnostics_root=${2:?diagnostics destination is required}

mkdir -p "$diagnostics_root"
for name in failed-result.json observed-result.json browser-empty.json browser-published.json; do
  [[ -f "$runtime_root/$name" ]] && cp "$runtime_root/$name" "$diagnostics_root/$name"
done
for name in logs audit-logs owner-diagnostics; do
  [[ -d "$runtime_root/$name" ]] && cp -R "$runtime_root/$name" "$diagnostics_root/$name"
done

printf 'Ticket 22A failure diagnostics retained at %s\n' "$diagnostics_root" >&2
