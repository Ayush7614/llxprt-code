#!/usr/bin/env bash
# Assign an issue to a commenter who posted an exact `/assign` command.
# Invoked by .github/workflows/assign.yml.
set -euo pipefail

MARKER='<!-- llxprt-assign-feedback -->'
AUTO_ASSIGNED_LABEL='auto-assigned'
MAX_ASSIGNMENTS=3
TRUSTED_FILE='.github/trusted-contributors.txt'

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "‼️ Missing \$${name} - this must be run from GitHub Actions" >&2
    exit 1
  fi
}

require_env GITHUB_REPOSITORY
require_env ISSUE_NUMBER
require_env COMMENTER_LOGIN

# Prefer GH_TOKEN when both are set (gh CLI convention).
if [[ -n "${GH_TOKEN:-}" ]]; then
  export GH_TOKEN
elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
  export GH_TOKEN="${GITHUB_TOKEN}"
else
  echo "‼️ Missing \$GH_TOKEN / \$GITHUB_TOKEN" >&2
  exit 1
fi

USER_LOGIN="${COMMENTER_LOGIN}"
ISSUE_NUMBER="${ISSUE_NUMBER}"
REPO="${GITHUB_REPOSITORY}"

post_sticky_feedback() {
  local message="$1"
  local body
  body="$(printf '%s\n%s\n' "${MARKER}" "${message}")"

  local existing_id=""
  existing_id="$(
    gh api "repos/${REPO}/issues/${ISSUE_NUMBER}/comments" --paginate \
      --jq ".[] | select(.body != null and (.body | contains(\"${MARKER}\"))) | .id" 2>/dev/null \
      | head -n 1 || true
  )"

  if [[ -n "${existing_id}" ]]; then
    if ! gh api --method PATCH "repos/${REPO}/issues/comments/${existing_id}" \
      -f body="${body}" >/dev/null 2>&1; then
      echo "   ⚠️ Failed to update sticky feedback comment" >&2
    fi
  else
    if ! gh issue comment "${ISSUE_NUMBER}" --repo "${REPO}" --body "${body}" >/dev/null 2>&1; then
      echo "   ⚠️ Failed to post sticky feedback comment" >&2
    fi
  fi
}

echo "🔄 Processing /assign for issue #${ISSUE_NUMBER} by @${USER_LOGIN}"

# --- Guard: already assigned ---
assignee_count="$(
  gh issue view "${ISSUE_NUMBER}" --repo "${REPO}" --json assignees \
    --jq '.assignees | length' 2>/dev/null || echo "0"
)"

if [[ "${assignee_count}" -gt 0 ]]; then
  current="$(
    gh issue view "${ISSUE_NUMBER}" --repo "${REPO}" --json assignees \
      --jq '[.assignees[].login] | join(", ")' 2>/dev/null || echo "someone"
  )"
  echo "⚠️ Issue #${ISSUE_NUMBER} is already assigned to: ${current}"
  post_sticky_feedback "❌ Could not assign @${USER_LOGIN}: this issue is already assigned to **${current}**."
  exit 0
fi

# --- Cap: max concurrent open assignments ---
open_assigned_count="$(
  gh search issues --repo "${REPO}" --assignee "${USER_LOGIN}" --state open \
    --json number --jq 'length' 2>/dev/null || echo "0"
)"

if [[ "${open_assigned_count}" -ge "${MAX_ASSIGNMENTS}" ]]; then
  echo "⚠️ @${USER_LOGIN} already has ${open_assigned_count} open assigned issues (max ${MAX_ASSIGNMENTS})"
  post_sticky_feedback "❌ Could not assign @${USER_LOGIN}: you already have **${open_assigned_count}** open assigned issues (maximum is **${MAX_ASSIGNMENTS}** per CONTRIBUTING.md)."
  exit 0
fi

# --- Eligibility ---
is_eligible=false
eligibility_reason=""

merged_pr_count="$(
  gh search prs --repo "${REPO}" --author "${USER_LOGIN}" --merged \
    --json number --jq 'length' 2>/dev/null || echo "0"
)"

if [[ "${merged_pr_count}" -gt 0 ]]; then
  is_eligible=true
  eligibility_reason="prior merged PR(s)"
fi

if [[ "${is_eligible}" != "true" ]]; then
  prior_assigned_count="$(
    gh search issues --repo "${REPO}" --assignee "${USER_LOGIN}" --state all \
      --json number --jq 'length' 2>/dev/null || echo "0"
  )"
  if [[ "${prior_assigned_count}" -gt 0 ]]; then
    is_eligible=true
    eligibility_reason="prior issue assignment"
  fi
fi

if [[ "${is_eligible}" != "true" && -f "${TRUSTED_FILE}" ]]; then
  if grep -Fqx "${USER_LOGIN}" "${TRUSTED_FILE}"; then
    is_eligible=true
    eligibility_reason="trusted contributor list"
  fi
fi

# Owners/members/collaborators are always eligible (author_association not
# always available here; treat repository permission via association env).
AUTHOR_ASSOCIATION="${AUTHOR_ASSOCIATION:-}"
case "${AUTHOR_ASSOCIATION}" in
  OWNER | MEMBER | COLLABORATOR)
    is_eligible=true
    eligibility_reason="repository ${AUTHOR_ASSOCIATION}"
    ;;
esac

if [[ "${is_eligible}" != "true" ]]; then
  echo "⚠️ @${USER_LOGIN} is not eligible for self-assignment"
  post_sticky_feedback "❌ Could not assign @${USER_LOGIN}: eligibility requires at least one merged PR in this repository, a prior issue assignment, or membership in \`.github/trusted-contributors.txt\`. Please open a PR first or ask a maintainer to assign you."
  exit 0
fi

echo "✅ Eligible via: ${eligibility_reason}"

# --- Assign ---
if ! gh issue edit "${ISSUE_NUMBER}" --repo "${REPO}" --add-assignee "${USER_LOGIN}" >/dev/null 2>&1; then
  echo "⚠️ gh issue edit --add-assignee failed for @${USER_LOGIN}"
fi

# Verify assignment took effect (GitHub silently ignores non-collaborators).
assigned_logins="$(
  gh issue view "${ISSUE_NUMBER}" --repo "${REPO}" --json assignees \
    --jq '[.assignees[].login] | join(",")' 2>/dev/null || echo ""
)"

IFS=',' read -ra ASSIGNED_ARRAY <<<"${assigned_logins}"
is_assigned=false
for login in "${ASSIGNED_ARRAY[@]}"; do
  if [[ "${login}" == "${USER_LOGIN}" ]]; then
    is_assigned=true
    break
  fi
done

if [[ "${is_assigned}" != "true" ]]; then
  echo "❌ Assignment did not take effect for @${USER_LOGIN} (likely lacks write access)"
  post_sticky_feedback "❌ Could not assign @${USER_LOGIN}: GitHub only allows assigning users with write access to the repository. A maintainer may need to add you as a collaborator or assign the issue manually. Eligibility check passed (${eligibility_reason})."
  exit 0
fi

# --- Tracking label ---
gh label create "${AUTO_ASSIGNED_LABEL}" \
  --repo "${REPO}" \
  --color "0E8A16" \
  --description "Assigned via /assign automation" \
  >/dev/null 2>&1 || true

if ! gh issue edit "${ISSUE_NUMBER}" --repo "${REPO}" --add-label "${AUTO_ASSIGNED_LABEL}" >/dev/null 2>&1; then
  echo "   ⚠️ Failed to add ${AUTO_ASSIGNED_LABEL} label" >&2
fi

echo "✅ Assigned @${USER_LOGIN} to issue #${ISSUE_NUMBER}"
post_sticky_feedback "✅ Assigned @${USER_LOGIN} to this issue via \`/assign\` (${eligibility_reason}).

Please open a linked PR within **2 weeks**, or the automation may unassign stale auto-assignments (maintainers are exempt)."
exit 0
