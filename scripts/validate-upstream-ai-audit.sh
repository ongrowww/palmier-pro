#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -eq 0 ]; then
  echo "usage: $0 <audit-file> [...]" >&2
  exit 2
fi

failed=0

for audit_file in "$@"; do
  if [ ! -f "$audit_file" ]; then
    echo "error: audit file not found: $audit_file" >&2
    failed=1
    continue
  fi

  for heading in \
    "## Upstream range" \
    "## Automated AI-surface report" \
    "## Required review" \
    "## Parity decision"; do
    if ! grep -Fqx -- "$heading" "$audit_file"; then
      echo "error: $audit_file is missing '$heading'" >&2
      failed=1
    fi
  done

  if grep -Fq -- '- [ ]' "$audit_file"; then
    echo "error: $audit_file still has unchecked review items" >&2
    failed=1
  fi

  if grep -Eq -- '(^|[[:space:]])(TODO|TBD)([[:space:]]|$)' "$audit_file"; then
    echo "error: $audit_file still contains a placeholder" >&2
    failed=1
  fi

  checked_count="$(grep -Ec -- '^- \[[xX]\] ' "$audit_file" || true)"
  if [ "$checked_count" -lt 6 ]; then
    echo "error: $audit_file must retain all six completed review items" >&2
    failed=1
  fi

  if ! grep -Eq -- '^- Decision: (no BYOK work required|BYOK changes implemented|feature explicitly unavailable)$' "$audit_file"; then
    echo "error: $audit_file has no supported parity decision" >&2
    failed=1
  fi

  for field in Evidence Tests; do
    value="$(sed -n "s/^- ${field}: //p" "$audit_file" | head -n 1)"
    if [ "${#value}" -lt 12 ]; then
      echo "error: $audit_file needs a concrete $field entry" >&2
      failed=1
    fi
  done
done

exit "$failed"
