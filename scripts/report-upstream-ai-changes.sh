#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <integrated-upstream-ref> <new-upstream-ref>" >&2
  exit 2
fi

base_ref="$1"
upstream_ref="$2"

git rev-parse --verify "${base_ref}^{commit}" >/dev/null
git rev-parse --verify "${upstream_ref}^{commit}" >/dev/null

base_sha="$(git rev-parse "$base_ref")"
upstream_sha="$(git rev-parse "$upstream_ref")"
commit_count="$(git rev-list --count "${base_sha}..${upstream_sha}")"
changed_count="$(git diff --name-only "${base_sha}..${upstream_sha}" | wc -l | tr -d ' ')"

relevant_files="$({
  git diff --name-only "${base_sha}..${upstream_sha}" | awk '
    /^Sources\/PalmierPro\/Resources\/Changelog\// ||
    /^Sources\/PalmierPro\/Generation\// ||
    /^Sources\/PalmierPro\/Agent\/Tools\/ToolDefinitions\.swift$/ ||
    /^Sources\/PalmierPro\/Agent\/Tools\/ToolExecutor\+Generate\.swift$/ ||
    /^Sources\/PalmierPro\/Inspector\/Tabs\/AIEditTab\.swift$/ ||
    /^Sources\/PalmierPro\/Timeline\/TimelineView\+AIEditMenu\.swift$/ {
      print
    }
  '
} || true)"

relevant_commits="$({
  git log --format='- `%h` %s' "${base_sha}..${upstream_sha}" -- \
    Sources/PalmierPro/Resources/Changelog \
    Sources/PalmierPro/Generation \
    Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift \
    Sources/PalmierPro/Agent/Tools/ToolExecutor+Generate.swift \
    Sources/PalmierPro/Inspector/Tabs/AIEditTab.swift \
    Sources/PalmierPro/Timeline/TimelineView+AIEditMenu.swift | sed -n '1,80p'
} || true)"

changelog_additions="$({
  git diff --unified=0 "${base_sha}..${upstream_sha}" -- \
    Sources/PalmierPro/Resources/Changelog/changelog.json |
    awk '/^\+[^+]/ { sub(/^\+/, ""); print }' | sed -n '1,120p'
} || true)"

printf '# Upstream AI parity audit\n\n'
printf 'Generated from the upstream-only delta before merging it into the OnGROW thin fork.\n\n'
printf '## Upstream range\n\n'
printf -- '- Previously integrated upstream: `%s`\n' "$base_sha"
printf -- '- Candidate upstream: `%s`\n' "$upstream_sha"
printf -- '- Upstream commits: %s\n' "$commit_count"
printf -- '- Changed files: %s\n\n' "$changed_count"
printf '## Automated AI-surface report\n\n'
printf '### Relevant upstream commits\n\n'
if [ -n "$relevant_commits" ]; then
  printf '%s\n' "$relevant_commits"
else
  printf 'No commits touched the monitored AI surfaces.\n'
fi
printf '\n### Changed AI-related files\n\n'
if [ -n "$relevant_files" ]; then
  while IFS= read -r path; do
    printf -- '- `%s`\n' "$path"
  done <<< "$relevant_files"
else
  printf 'No monitored AI-related files changed.\n'
fi
printf '\n### Added changelog content\n\n'
if [ -n "$changelog_additions" ]; then
  printf '```json\n%s\n```\n' "$changelog_additions"
else
  printf 'No lines were added to the upstream changelog file.\n'
fi
printf '\n## Required review\n\n'
printf -- '- [ ] Review the upstream changelog for new or changed AI features.\n'
printf -- '- [ ] Review generation models, capabilities, inputs, and settings.\n'
printf -- '- [ ] Review AI Edit actions and their source-media requirements.\n'
printf -- '- [ ] Review Agent generation tools for the same provider parity.\n'
printf -- '- [ ] Review BYOK endpoint mapping, validation, pricing, and tests.\n'
printf -- '- [ ] Complete affected smoke tests, or document why none are required.\n\n'
printf '## Parity decision\n\n'
printf -- '- Decision: TODO\n'
printf -- '- Evidence: TODO\n'
printf -- '- Tests: TODO\n'
