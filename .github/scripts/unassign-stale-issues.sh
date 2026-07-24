#!/usr/bin/env bash
# Unassign stale auto-assigned issues with no qualifying linked PR activity
# for 2 weeks. Invoked by .github/workflows/assign-stale-cleanup.yml.
#
# Uses targeted DELETE endpoints (never whole-array PATCH) to preserve
# concurrent human state and comma-bearing label names. Only the exact
# automation assignee and auto-assigned label are removed.
#
# acoliver is never unassigned. Timeline/API failures preserve state and
# cause a nonzero exit (never destructive cleanup).
set -euo pipefail

AUTO_ASSIGNED_LABEL='auto-assigned'
AUTO_ASSIGNED_COLOR='0E8A16'
AUTO_ASSIGNED_DESC='Assigned via /assign automation'
STALE_DAYS=14
EXEMPT_LOGIN='acoliver'
BOT_LOGIN='github-actions[bot]'
ASSIGN_RETRY_DELAY="${ASSIGN_RETRY_DELAY:-5}"

: "${GITHUB_REPOSITORY:?Missing GITHUB_REPOSITORY}"

EXPECTED_REPO_URL="https://api.github.com/repos/${GITHUB_REPOSITORY}"

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
      sleep "${ASSIGN_RETRY_DELAY}"
    fi
  done
  echo "All retries exhausted for: $*" >&2
  return 1
}

threshold_iso() {
  if [[ -n "${ASSIGN_NOW:-}" ]]; then
    local now_epoch
    now_epoch="$(iso_to_epoch "${ASSIGN_NOW}")" || return 1
    local threshold_epoch
    threshold_epoch=$((now_epoch - STALE_DAYS * 86400))
    date -u -d "@${threshold_epoch}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
      date -u -r "${threshold_epoch}" +%Y-%m-%dT%H:%M:%SZ
    return 0
  fi
  if date -u -d "${STALE_DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null; then
    return 0
  fi
  date -u -v-"${STALE_DAYS}"d +%Y-%m-%dT%H:%M:%SZ
}

iso_to_epoch() {
  local iso="$1"
  local normalized="${iso%Z}"
  normalized="${normalized%%.*}"
  if date -u -d "${normalized}Z" +%s 2>/dev/null; then
    return 0
  fi
  date -u -j -f "%Y-%m-%dT%H:%M:%S" "${normalized}" +%s 2>/dev/null
}

# gh api --paginate emits one JSON array per page; jq -s merges them.
fetch_issue_timeline() {
  local issue_number="$1"
  gh api "repos/${REPO}/issues/${issue_number}/timeline?per_page=100" \
    --paginate 2>/dev/null \
    | jq -s 'if all(.[]; type == "array") then add else error("non-array page in timeline") end'
}

# Read current assignees as a raw JSON array.
get_issue_assignees_json() {
  local issue_number="$1"
  gh api "repos/${REPO}/issues/${issue_number}" \
    --jq '.assignees // []' 2>/dev/null
}


# Provenance extraction from a pre-fetched timeline snapshot.
# Args: assignees_json, timeline_json.
# Output: "LOGIN TIMESTAMP" or empty. Returns nonzero on error/ambiguity.
find_provenance_from_timeline() {
  local assignees_json="$1"
  local timeline_json="$2"

  local result
  result="$(echo "${timeline_json}" | jq -r \
    --argjson current_assignees "${assignees_json}" \
    --arg label "${AUTO_ASSIGNED_LABEL}" \
    --arg bot "${BOT_LOGIN}" '
    if type != "array" then error("timeline is not an array") else . end
    | to_entries as $all_entries
    | ($all_entries | map(select(.value.event == "assigned" or .value.event == "unassigned"))) as $assign_entries
    | ($all_entries | map(select(.value.event == "labeled" or .value.event == "unlabeled"))) as $label_entries
    | ($current_assignees | map(.login)) as $logins
    | $logins[]
    | . as $login
    | ($assign_entries | map(select(.value.assignee.login == $login))) as $login_transitions
    | ($login_transitions | last // null) as $last_entry
    | ($login_transitions[-2] // null) as $boundary_entry
    | if $last_entry != null and $last_entry.value.event == "assigned" and $last_entry.value.actor.login == $bot then
        $last_entry.value.created_at as $assigned_at
        | $last_entry.key as $assigned_pos
        | ($boundary_entry.key // -1) as $boundary_pos
        | ($label_entries | map(select(
            .value.label.name == $label
            and (.key > $boundary_pos)
            and (.key <= $assigned_pos)
            and .value.actor.login == $bot
            and .value.event == "labeled"
          )) | last // null) as $qualifying_entry
        | if $qualifying_entry != null then
            ($label_entries | map(select(
              .value.label.name == $label
              and (.key > $qualifying_entry.key)
              and .value.event == "unlabeled"
            )) | length > 0) as $has_invalidating_unlabel
            | if $has_invalidating_unlabel then
                empty
              else
                "\($login) \($assigned_at)"
              end
          else
            empty
          end
      else
        empty
      end
  ' 2>/dev/null)" || return 1

  local line_count
  line_count="$(echo "${result}" | grep -c . || true)"
  if [[ "${line_count}" -gt 1 ]]; then
    echo "Multiple automated provenance records found" >&2
    return 1
  fi

  echo "${result}"
}

# Qualifying linked PR requires the same repository and assignee author, with
# linkage at or after assignment. Returns nonzero for malformed snapshots.
has_qualifying_linked_pr_from_timeline() {
  local assignee="$1"
  local assigned_at="$2"
  local timeline_json="$3"

  local result
  result="$(echo "${timeline_json}" | jq -r --arg assignee "${assignee}" --arg assigned_at "${assigned_at}" --arg repo_url "${EXPECTED_REPO_URL}" '
    if type != "array" then error("timeline is not an array") else . end
    | map(select(
        (.event == "cross-referenced") and
        (.source.issue.pull_request != null) and
        (.source.issue.user.login == $assignee) and
        (.created_at >= $assigned_at) and
        (.source.issue.repository_url == $repo_url)
      ))
    | length > 0
  ' 2>/dev/null)" || return 1

  echo "${result}"
}

# Discover candidates: open issues with auto-assigned label.
# GitHub /issues includes PRs; filter to issues only.
discover_candidates() {
  gh api "repos/${REPO}/issues?state=open&labels=${AUTO_ASSIGNED_LABEL}&per_page=100" \
    --paginate 2>/dev/null \
    | jq -sr 'if all(.[]; type == "array") then add else error("non-array page") end
             | .[]? | select(.pull_request == null) | "\(.number)\t\(.assignees)"'
}

# Remove only the auto-assigned label via targeted DELETE. Uses jq @uri.
# On DELETE failure (including 404 from a race that already removed the
# label), re-reads the issue to verify the label is actually absent. Only an
# issue read confirming absence allows treating the failure as success.
remove_label_targeted() {
  local issue_number="$1"
  local label_name="$2"
  local encoded
  encoded="$(printf '%s' "${label_name}" | jq -sRr '@uri' | sed 's/%0A$//;s/%0a$//')"
  if retry_gh gh api --method DELETE "repos/${REPO}/issues/${issue_number}/labels/${encoded}" \
    --silent >/dev/null 2>&1; then
    return 0
  fi
  # DELETE failed — verify whether the label is actually absent via issue read.
  local verify_labels
  if ! verify_labels="$(gh api "repos/${REPO}/issues/${issue_number}" --jq '.labels // []' 2>/dev/null)"; then
    echo "   Warning: Label-removal DELETE failed and verification read failed for #${issue_number}" >&2
    return 1
  fi
  if echo "${verify_labels}" | jq -e --arg lbl "${label_name}" '[.[].name] | index($lbl) != null' >/dev/null 2>&1; then
    echo "   Warning: Label-removal DELETE failed and label still present for #${issue_number}" >&2
    return 1
  fi
  # Label is confirmed absent — desired state achieved despite DELETE failure.
  return 0
}

# Remove only a specific assignee via targeted DELETE.
remove_assignee_targeted() {
  local issue_number="$1"
  local login="$2"
  if ! retry_gh gh api --method DELETE "repos/${REPO}/issues/${issue_number}/assignees" \
    -f "assignees[]=${login}" --silent >/dev/null 2>&1; then
    echo "   Warning: Assignee-removal DELETE failed for #${issue_number}" >&2
    return 1
  fi
  return 0
}

# Remove auto-assigned label only (no assignees to clean).
remove_label_only() {
  local issue_number="$1"
  remove_label_targeted "${issue_number}" "${AUTO_ASSIGNED_LABEL}"
}

# Validate the canonical auto-assigned label definition before any candidate
# discovery or mutation (fail-closed, matching assign-issue.sh).
# Returns: 0 = exists with correct definition; 1 = absent (clean no-op);
# 2 = conflicting definition; 3 = API error.
validate_marker_label() {
  local _stderr_file raw
  _stderr_file="$(mktemp)"
  raw="$(gh api "repos/${REPO}/labels/${AUTO_ASSIGNED_LABEL}" --jq '.' 2>"${_stderr_file}")" || {
    local _diag
    _diag="$(cat "${_stderr_file}" 2>/dev/null || true)"
    rm -f "${_stderr_file}"
    if echo "${_diag}" | grep -qE 'HTTP.?404|404.*not found'; then
      return 1
    fi
    return 3
  }
  rm -f "${_stderr_file}"
  local color desc
  color="$(echo "${raw}" | jq -r '.color // ""')" || return 3
  desc="$(echo "${raw}" | jq -r '.description // ""')" || return 3
  if [[ "${color}" != "${AUTO_ASSIGNED_COLOR}" ]] || [[ "${desc}" != "${AUTO_ASSIGNED_DESC}" ]]; then
    return 2
  fi
  return 0
}

process_issue() {
  local issue_number="$1"
  local assignees_json="$2"
  local threshold_epoch="$3"

  local assignee_count
  assignee_count="$(echo "${assignees_json}" | jq 'length' 2>/dev/null || echo '?')"

  echo "🔄 Checking auto-assigned issue #${issue_number} (assignees: ${assignee_count})"

  if [[ "${assignee_count}" == "0" ]]; then
    echo "   No assignees; removing stale ${AUTO_ASSIGNED_LABEL} label"
    remove_label_only "${issue_number}"
    return $?
  fi

  local bot_assignment=""
  local initial_timeline_json=""
  # Fetch ONE initial timeline snapshot per issue and use it for BOTH
  # initial provenance extraction and the initial linked-PR check. This
  # avoids a duplicate timeline fetch (a separate fresh pre-delete snapshot
  # is still mandatory before destructive DELETE for race safety).
  initial_timeline_json="$(fetch_issue_timeline "${issue_number}")" || {
    echo "   Warning: Initial timeline read failed for #${issue_number}; preserving state" >&2
    return 1
  }

  bot_assignment="$(find_provenance_from_timeline "${assignees_json}" "${initial_timeline_json}")" || {
    echo "   Warning: Provenance check failed for #${issue_number} (ambiguous or error); preserving state" >&2
    return 1
  }

  if [[ -z "${bot_assignment}" ]]; then
    echo "   No automated assignment provenance for #${issue_number}; removing label only"
    remove_label_only "${issue_number}"
    return $?
  fi

  local bot_login bot_assigned_at
  bot_login="${bot_assignment%% *}"
  bot_assigned_at="${bot_assignment#* }"

  echo "   Bot-assigned @${bot_login} at ${bot_assigned_at}"

  if [[ "${bot_login}" == "${EXEMPT_LOGIN}" ]]; then
    echo "   Keeping @${EXEMPT_LOGIN} on #${issue_number} (exempt)"
    return 0
  fi

  local bot_assigned_epoch
  bot_assigned_epoch="$(iso_to_epoch "${bot_assigned_at}" || true)"
  if [[ -z "${bot_assigned_epoch}" ]]; then
    echo "   Warning: Could not parse assignment time '${bot_assigned_at}' for #${issue_number}; preserving state" >&2
    return 1
  fi

  if [[ "${bot_assigned_epoch}" -gt "${threshold_epoch}" ]]; then
    echo "   Assignment for #${issue_number} is newer than ${STALE_DAYS} days; keeping"
    return 0
  fi

  # Use the same initial timeline snapshot for the initial linked-PR check
  # (a separate fresh pre-delete snapshot is taken before DELETE).
  local has_pr="false"
  has_pr="$(has_qualifying_linked_pr_from_timeline "${bot_login}" "${bot_assigned_at}" "${initial_timeline_json}")" || {
    echo "   Warning: Linked PR query failed for #${issue_number}; preserving state" >&2
    return 1
  }

  if [[ "${has_pr}" == "true" ]]; then
    echo "   @${bot_login} has qualifying linked PR activity for #${issue_number}; keeping"
    return 0
  fi

  # Re-read current assignees and fetch ONE fresh timeline snapshot immediately
  # before destructive DELETE. Both provenance revalidation and linked-PR
  # revalidation run against this single snapshot, so a qualifying PR that
  # appears between the initial check and the pre-delete revalidation is
  # detected (race protection).
  local pre_delete_assignees_json=""
  pre_delete_assignees_json="$(get_issue_assignees_json "${issue_number}")" || {
    echo "   Warning: Pre-delete assignee read failed for #${issue_number}; preserving state" >&2
    return 1
  }

  local pre_delete_timeline_json=""
  pre_delete_timeline_json="$(fetch_issue_timeline "${issue_number}")" || {
    echo "   Warning: Pre-delete timeline read failed for #${issue_number}; preserving state" >&2
    return 1
  }

  local pre_delete_assignment=""
  pre_delete_assignment="$(find_provenance_from_timeline "${pre_delete_assignees_json}" "${pre_delete_timeline_json}")" || {
    echo "   Warning: Pre-delete revalidation failed for #${issue_number}; preserving state" >&2
    return 1
  }

  if [[ -z "${pre_delete_assignment}" ]]; then
    echo "   Provenance changed before DELETE for #${issue_number}; human may have reassigned; removing label only"
    remove_label_only "${issue_number}"
    return $?
  fi

  local revalidated_login revalidated_ts
  revalidated_login="${pre_delete_assignment%% *}"
  revalidated_ts="${pre_delete_assignment#* }"
  if [[ "${revalidated_login}" != "${bot_login}" ]]; then
    echo "   Warning: Provenance login mismatch for #${issue_number}; preserving state" >&2
    return 0
  fi
  if [[ "${revalidated_ts}" != "${bot_assigned_at}" ]]; then
    echo "   Warning: Provenance timestamp changed for #${issue_number}; preserving state" >&2
    return 0
  fi

  # Re-run the linked-PR predicate against the same fresh pre-delete snapshot.
  # A qualifying PR that appeared between the initial check and this pre-delete
  # revalidation must block deletion (race protection).
  local pre_delete_has_pr="false"
  pre_delete_has_pr="$(has_qualifying_linked_pr_from_timeline "${bot_login}" "${bot_assigned_at}" "${pre_delete_timeline_json}")" || {
    echo "   Warning: Pre-delete linked-PR revalidation failed for #${issue_number}; preserving state" >&2
    return 1
  }

  if [[ "${pre_delete_has_pr}" == "true" ]]; then
    echo "   @${bot_login} has qualifying linked PR activity (detected before DELETE) for #${issue_number}; keeping"
    return 0
  fi

  # Verify bot_login is still assigned using exact jq index.
  if ! echo "${pre_delete_assignees_json}" | jq -e --arg login "${bot_login}" '[.[].login] | index($login) != null' >/dev/null 2>&1; then
    echo "   @${bot_login} no longer assigned before DELETE for #${issue_number}; nothing to do"
    return 0
  fi

  echo "   Unassigning stale @${bot_login} from #${issue_number}"

  # Remove assignee first via targeted DELETE.
  if ! remove_assignee_targeted "${issue_number}" "${bot_login}"; then
    return 1
  fi

  # Immediately re-read and verify login is absent BEFORE label DELETE.
  # If still present (successful no-op or post-handler race), retain marker.
  local mid_delete_assignees_json=""
  if ! mid_delete_assignees_json="$(get_issue_assignees_json "${issue_number}")"; then
    echo "   Warning: Post-assignee-DELETE verification read failed for #${issue_number}" >&2
    return 1
  fi

  if echo "${mid_delete_assignees_json}" | jq -e --arg login "${bot_login}" '[.[].login] | index($login) != null' >/dev/null 2>&1; then
    echo "   Warning: @${bot_login} still assigned after DELETE (no-op or race); retaining marker for #${issue_number}" >&2
    return 1
  fi

  # Remove auto-assigned label via targeted DELETE.
  if ! remove_label_targeted "${issue_number}" "${AUTO_ASSIGNED_LABEL}"; then
    # Assignee was already removed but label DELETE failed. Report honestly
    # that assignment was removed and leave the marker for a later retry.
    echo "   Assignment removed for #${issue_number}, but label remains for retry" >&2
    return 1
  fi

  # Re-read and verify final state using exact jq index.
  local post_delete_assignees_json=""
  post_delete_assignees_json="$(get_issue_assignees_json "${issue_number}")" || {
    echo "   Warning: Post-delete verification read failed for #${issue_number}" >&2
    return 1
  }

  if echo "${post_delete_assignees_json}" | jq -e --arg login "${bot_login}" '[.[].login] | index($login) != null' >/dev/null 2>&1; then
    echo "   Warning: @${bot_login} still assigned after DELETE for #${issue_number}" >&2
    return 1
  fi

  # Verify co-assignees were preserved using exact jq index.
  local other_logins
  other_logins="$(echo "${pre_delete_assignees_json}" | jq -r --arg bot "${bot_login}" '[.[].login] | map(select(. != $bot)) | .[]' 2>/dev/null || true)"
  if [[ -n "${other_logins}" ]]; then
    while IFS= read -r co_login; do
      [[ -z "${co_login}" ]] && continue
      if ! echo "${post_delete_assignees_json}" | jq -e --arg login "${co_login}" '[.[].login] | index($login) != null' >/dev/null 2>&1; then
        echo "   Warning: Co-assignee @${co_login} was unexpectedly removed from #${issue_number}" >&2
        return 1
      fi
    done <<<"${other_logins}"
  fi

  retry_gh gh api --method POST "repos/${REPO}/issues/${issue_number}/comments" \
    -f body="⏱️ Automatically unassigned @${bot_login} from this issue.

This issue was auto-assigned via \`/assign\` more than **${STALE_DAYS} days** ago with no qualifying linked PR activity. Comment \`/assign\` again if you still plan to work on it (subject to eligibility and the 3-issue cap)." \
    --silent 2>/dev/null || true

  return 0
}

echo " Scanning open issues with label:${AUTO_ASSIGNED_LABEL}"

# Validate the canonical marker label definition before any discovery or
# mutation. A missing marker label means no automation-provenance issues can
# exist (discover_candidates would find none) — clean no-op. A conflicting
# definition or API error must fail closed with no mutation.
validate_marker_label || _marker_rc=$?
case ${_marker_rc:-0} in
  0) ;;  # correct definition — proceed
  1)
    echo "[OK] Marker label '${AUTO_ASSIGNED_LABEL}' is absent; nothing to clean"
    exit 0
    ;;
  2)
    echo "‼ Marker label '${AUTO_ASSIGNED_LABEL}' has a conflicting definition; aborting" >&2
    exit 1
    ;;
  *)
    echo "‼ Failed to validate marker label '${AUTO_ASSIGNED_LABEL}' (API error); aborting" >&2
    exit 1
    ;;
esac

THRESHOLD_ISO="$(threshold_iso)"
THRESHOLD_EPOCH="$(iso_to_epoch "${THRESHOLD_ISO}")"
echo "   Stale threshold: ${THRESHOLD_ISO} (epoch ${THRESHOLD_EPOCH})"

GLOBAL_FAIL=0

if ! CANDIDATES_RAW="$(discover_candidates)"; then
  echo "‼️ Candidate discovery failed" >&2
  exit 1
fi

if [[ -z "${CANDIDATES_RAW}" || "${CANDIDATES_RAW}" == $'\n' ]]; then
  echo "✅ No auto-assigned open issues found"
  exit 0
fi

CANDIDATES=()
while IFS= read -r _line; do
  [[ -n "${_line}" ]] && CANDIDATES+=("${_line}")
done <<<"${CANDIDATES_RAW}"

for row in "${CANDIDATES[@]}"; do
  [[ -z "${row}" ]] && continue
  issue_number="${row%%$'\t'*}"
  assignees_json="${row#*$'\t'}"

  if ! process_issue "${issue_number}" "${assignees_json}" "${THRESHOLD_EPOCH}"; then
    echo "   Warning: Error processing #${issue_number}; continuing" >&2
    GLOBAL_FAIL=1
  fi
done

if [[ "${GLOBAL_FAIL}" -ne 0 ]]; then
  echo "⚠️ Cleanup completed with errors (some issues preserved)" >&2
  exit 1
fi

echo "✅ Stale auto-assignment cleanup finished"
exit 0
