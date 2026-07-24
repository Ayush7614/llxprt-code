#!/usr/bin/env bash
# Create or verify a per-user assignment history label.
#
# Used by both assign-issue.sh (direct durability) and the record-history
# workflow job (issues:assigned events). Uses the same short-prefix exact
# label definition validation (name, normalized color, description) and
# collision failure as assign-issue.sh.
set -euo pipefail

# Source shared constants (history-label policy values + login validation).
# shellcheck source-path=SCRIPTDIR
source "$(dirname "${BASH_SOURCE[0]}")/assign-constants.sh"

# Check required tool availability with clear diagnostics before use.
for _tool in gh jq; do
  if ! command -v "${_tool}" >/dev/null 2>&1; then
    printf '‼ Missing required tool: %s\n' "${_tool}" >&2
    exit 1
  fi
done
unset _tool

: "${GITHUB_REPOSITORY:?Missing GITHUB_REPOSITORY}"
: "${ASSIGNEE_LOGIN:?Missing ASSIGNEE_LOGIN}"

if [[ -n "${GH_TOKEN:-}" ]]; then
  export GH_TOKEN
elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
  export GH_TOKEN="${GITHUB_TOKEN}"
else
  printf '‼ Missing %s / %s\n' "\$GH_TOKEN" "\$GITHUB_TOKEN" >&2
  exit 1
fi

REPO="${GITHUB_REPOSITORY}"
LOGIN="${ASSIGNEE_LOGIN}"

# Validate login syntax before label construction.
if ! validate_github_login "${LOGIN}"; then
  printf '‼ Invalid GitHub login: %q\n' "${LOGIN}" >&2
  exit 1
fi

LABEL_NAME="${HISTORY_PREFIX}${LOGIN}"

# Track temp files for cleanup on signals/exit.
_HISTORY_TMPFILES=()

_history_cleanup() {
  for _f in "${_HISTORY_TMPFILES[@]:-}"; do
    [[ -n "${_f}" ]] && rm -f "${_f}" 2>/dev/null || true
  done
}
trap _history_cleanup EXIT
trap 'trap - EXIT; _history_cleanup; exit 130' INT TERM

validate_history_label() {
  local label_name="$1"
  local _stderr_file raw
  _stderr_file="$(mktemp)"
  _HISTORY_TMPFILES+=("${_stderr_file}")
  raw="$(gh api "repos/${REPO}/labels/${label_name}" --jq '.' 2>"${_stderr_file}")" || {
    local _diag
    _diag="$(cat "${_stderr_file}" 2>/dev/null || true)"
    rm -f "${_stderr_file}"
    # Distinguish 404 (absence) from other API failures (error).
    if printf '%s' "${_diag}" | grep -qE 'HTTP.?404|404.*not found'; then
      return 1
    fi
    # Non-404 API error — log sanitized diagnostics and signal error.
    printf '‼ validate_history_label: API error for %q: %s\n' "${label_name}" "$(printf '%s' "${_diag}" | head -1)" >&2
    return 2
  }
  rm -f "${_stderr_file}"
  local color desc
  color="$(printf '%s' "${raw}" | jq -r '.color // ""')" || return 2
  desc="$(printf '%s' "${raw}" | jq -r '.description // ""')" || return 2
  if [[ "${color}" != "${HISTORY_COLOR}" ]] || [[ "${desc}" != "${HISTORY_DESC}" ]]; then
    return 1
  fi
  return 0
}

validate_history_label "${LABEL_NAME}" || rc=$?
case ${rc:-0} in
  0)
    printf 'Label %s already exists with correct definition\n' "${LABEL_NAME}"
    exit 0
    ;;
  1) ;;  # absent — proceed to create
  2)
    printf '‼ Failed to check label %s (API error)\n' "${LABEL_NAME}" >&2
    exit 1
    ;;
  *)
    printf '‼ Unexpected label validation status: %s\n' "${rc:-0}" >&2
    exit 1
    ;;
esac

if ! gh api --method POST "repos/${REPO}/labels" \
  -f name="${LABEL_NAME}" \
  -f color="${HISTORY_COLOR}" \
  -f description="${HISTORY_DESC}" \
  --silent >/dev/null 2>&1; then
  # POST failed — re-check whether it was created concurrently. Capture the
  # return code directly (not via if/else, which loses $? of the condition).
  rc=0
  validate_history_label "${LABEL_NAME}" || rc=$?
  case ${rc} in
    0)
      printf 'Label %s already exists (created concurrently)\n' "${LABEL_NAME}"
      exit 0
      ;;
    1)
      printf '‼ Label %q exists with conflicting definition\n' "${LABEL_NAME}" >&2
      exit 1
      ;;
    *)
      printf '‼ Failed to create label %s\n' "${LABEL_NAME}" >&2
      exit 1
      ;;
  esac
fi

printf 'Created label %s\n' "${LABEL_NAME}"
