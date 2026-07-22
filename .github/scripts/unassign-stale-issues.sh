#!/usr/bin/env bash
# Unassign stale auto-assigned issues with no linked PR activity for 2 weeks.
# Invoked by .github/workflows/assign-stale-cleanup.yml.
# Never unassigns acoliver.
set -euo pipefail

AUTO_ASSIGNED_LABEL='auto-assigned'
STALE_DAYS=14
EXEMPT_LOGIN='acoliver'

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "‼️ Missing \$${name} - this must be run from GitHub Actions" >&2
    exit 1
  fi
}

require_env GITHUB_REPOSITORY

if [[ -n "${GH_TOKEN:-}" ]]; then
  export GH_TOKEN
elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
  export GH_TOKEN="${GITHUB_TOKEN}"
else
  echo "‼️ Missing \$GH_TOKEN / \$GITHUB_TOKEN" >&2
  exit 1
fi

REPO="${GITHUB_REPOSITORY}"

retry_gh() {
  local attempt
  for attempt in 1 2 3 4; do
    if "$@"; then
      return 0
    fi
    if [[ "${attempt}" -lt 4 ]]; then
      echo "Attempt ${attempt} failed, retrying: $*" >&2
      sleep 5
    fi
  done
  echo "All retries exhausted for: $*" >&2
  return 1
}

# ISO-8601 UTC timestamp STALE_DAYS ago (GNU date on ubuntu-latest; BSD fallback).
threshold_iso() {
  if date -u -d "${STALE_DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null; then
    return 0
  fi
  date -u -v-"${STALE_DAYS}"d +%Y-%m-%dT%H:%M:%SZ
}

iso_to_epoch() {
  local iso="$1"
  # Normalize fractional seconds / Z for date parsing.
  local normalized="${iso%Z}"
  normalized="${normalized%%.*}"
  if date -u -d "${normalized}Z" +%s 2>/dev/null; then
    return 0
  fi
  date -u -j -f "%Y-%m-%dT%H:%M:%S" "${normalized}" +%s 2>/dev/null
}

assignment_age_ok_to_unassign() {
  local issue_number="$1"
  local assignee="$2"
  local threshold_epoch="$3"

  # Prefer the most recent "assigned" timeline event for this assignee.
  local assigned_at=""
  assigned_at="$(
    gh api "repos/${REPO}/issues/${issue_number}/timeline" --paginate \
      --jq "[.[] | select(.event == \"assigned\" and .assignee.login == \"${assignee}\") | .created_at] | last // empty" \
      2>/dev/null || true
  )"

  if [[ -z "${assigned_at}" ]]; then
    # Fall back to issue updatedAt when timeline is unavailable.
    assigned_at="$(
      gh issue view "${issue_number}" --repo "${REPO}" --json updatedAt \
        --jq '.updatedAt' 2>/dev/null || true
    )"
  fi

  if [[ -z "${assigned_at}" ]]; then
    echo "   ⚠️ Could not determine assignment time for #${issue_number}; skipping" >&2
    return 1
  fi

  local assigned_epoch
  assigned_epoch="$(iso_to_epoch "${assigned_at}" || true)"
  if [[ -z "${assigned_epoch}" ]]; then
    echo "   ⚠️ Could not parse assignment time '${assigned_at}' for #${issue_number}; skipping" >&2
    return 1
  fi

  if [[ "${assigned_epoch}" -gt "${threshold_epoch}" ]]; then
    echo "   ⏳ Assignment for #${issue_number} is newer than ${STALE_DAYS} days; keeping"
    return 1
  fi
  return 0
}

has_linked_pr_activity() {
  local issue_number="$1"
  local assignee="$2"

  # Any PR by the assignee that mentions this issue number in title/body.
  local pr_hits
  pr_hits="$(
    gh search prs \
      --repo "${REPO}" \
      --author "${assignee}" \
      --json number \
      --jq 'length' \
      "#${issue_number} in:title,body" \
      2>/dev/null || echo "0"
  )"

  if [[ "${pr_hits}" == "0" || -z "${pr_hits}" ]]; then
    pr_hits="$(
      gh pr list --repo "${REPO}" --author "${assignee}" --state all --limit 50 \
        --json number,title,body \
        --jq "[.[] | select((.title // \"\" | contains(\"#${issue_number}\")) or (.body // \"\" | test(\"(?i)(closes?|fixes?|resolves?)?\\s*#${issue_number}\\b\")))] | length" \
        2>/dev/null || echo "0"
    )"
  fi

  [[ "${pr_hits}" =~ ^[0-9]+$ ]] && [[ "${pr_hits}" -gt 0 ]]
}

process_issue() {
  local issue_number="$1"
  local assignees_csv="$2"
  local threshold_epoch="$3"

  echo "🔄 Checking auto-assigned issue #${issue_number} (assignees: ${assignees_csv})"

  if [[ -z "${assignees_csv}" ]]; then
    echo "   No assignees; removing stale ${AUTO_ASSIGNED_LABEL} label"
    retry_gh gh issue edit "${issue_number}" --repo "${REPO}" \
      --remove-label "${AUTO_ASSIGNED_LABEL}" >/dev/null 2>&1 || true
    return 0
  fi

  IFS=',' read -ra ASSIGNEES <<<"${assignees_csv}"

  # Exempt: never unassign acoliver (ticket exception).
  for login in "${ASSIGNEES[@]}"; do
    if [[ "${login}" == "${EXEMPT_LOGIN}" ]]; then
      echo "   🛡️ Skipping #${issue_number}: assignee @${EXEMPT_LOGIN} is exempt"
      return 0
    fi
  done

  local keep=false
  local assignee
  for assignee in "${ASSIGNEES[@]}"; do
    [[ -z "${assignee}" ]] && continue

    if ! assignment_age_ok_to_unassign "${issue_number}" "${assignee}" "${threshold_epoch}"; then
      keep=true
      continue
    fi

    if has_linked_pr_activity "${issue_number}" "${assignee}"; then
      echo "   ✅ @${assignee} has linked PR activity for #${issue_number}; keeping"
      keep=true
      continue
    fi

    echo "   🧹 Unassigning stale @${assignee} from #${issue_number}"
    if retry_gh gh issue edit "${issue_number}" --repo "${REPO}" \
      --remove-assignee "${assignee}" >/dev/null 2>&1; then
      retry_gh gh issue comment "${issue_number}" --repo "${REPO}" --body "$(cat <<EOF
⏱️ Automatically unassigned @${assignee} from this issue.

This issue was auto-assigned via \`/assign\` more than **${STALE_DAYS} days** ago with no linked PR activity. Comment \`/assign\` again if you still plan to work on it (subject to eligibility and the 3-issue cap).
EOF
)" >/dev/null 2>&1 || true
    else
      echo "   ⚠️ Failed to unassign @${assignee} from #${issue_number}" >&2
      keep=true
    fi
  done

  if [[ "${keep}" != "true" ]]; then
    # Re-check assignees after removals.
    local remaining
    remaining="$(
      gh issue view "${issue_number}" --repo "${REPO}" --json assignees \
        --jq '.assignees | length' 2>/dev/null || echo "1"
    )"
    if [[ "${remaining}" -eq 0 ]]; then
      retry_gh gh issue edit "${issue_number}" --repo "${REPO}" \
        --remove-label "${AUTO_ASSIGNED_LABEL}" >/dev/null 2>&1 || true
    fi
  fi
}

echo "📥 Scanning open issues with label:${AUTO_ASSIGNED_LABEL}"

THRESHOLD_ISO="$(threshold_iso)"
THRESHOLD_EPOCH="$(iso_to_epoch "${THRESHOLD_ISO}")"
echo "   Stale threshold: ${THRESHOLD_ISO} (epoch ${THRESHOLD_EPOCH})"

# List candidates: open + auto-assigned label.
mapfile -t CANDIDATES < <(
  gh issue list --repo "${REPO}" --state open --label "${AUTO_ASSIGNED_LABEL}" \
    --limit 200 \
    --json number,assignees \
    --jq '.[] | "\(.number)\t\([.assignees[].login] | join(","))"' \
    2>/dev/null || true
)

if [[ "${#CANDIDATES[@]}" -eq 0 ]]; then
  echo "✅ No auto-assigned open issues found"
  exit 0
fi

for row in "${CANDIDATES[@]}"; do
  [[ -z "${row}" ]] && continue
  issue_number="${row%%$'\t'*}"
  assignees_csv="${row#*$'\t'}"
  # Isolate per-issue failures so one bad issue does not abort the run.
  if ! process_issue "${issue_number}" "${assignees_csv}" "${THRESHOLD_EPOCH}"; then
    echo "   ⚠️ Error processing #${issue_number}; continuing" >&2
  fi
done

echo "✅ Stale auto-assignment cleanup finished"
exit 0
