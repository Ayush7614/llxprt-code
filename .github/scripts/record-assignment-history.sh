#!/usr/bin/env bash
# Create or verify a per-user assignment history label.
#
# Used by both assign-issue.sh (direct durability) and the record-history
# workflow job (issues:assigned events). Uses the same short-prefix exact
# label definition validation (name, normalized color, description) and
# collision failure as assign-issue.sh.
set -euo pipefail

HISTORY_PREFIX='asnhist--'
HISTORY_COLOR='0E8A16'
HISTORY_DESC='Issue assignment history index'

: "${GITHUB_REPOSITORY:?Missing GITHUB_REPOSITORY}"
: "${ASSIGNEE_LOGIN:?Missing ASSIGNEE_LOGIN}"

if [[ -n "${GH_TOKEN:-}" ]]; then
  export GH_TOKEN
elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
  export GH_TOKEN="${GITHUB_TOKEN}"
else
  echo "‼ Missing \$GH_TOKEN / \$GITHUB_TOKEN" >&2
  exit 1
fi

REPO="${GITHUB_REPOSITORY}"
LOGIN="${ASSIGNEE_LOGIN}"
LABEL_NAME="${HISTORY_PREFIX}${LOGIN}"

validate_history_label() {
  local label_name="$1"
  local _stderr_file raw
  _stderr_file="$(mktemp)"
  raw="$(gh api "repos/${REPO}/labels/${label_name}" --jq '.' 2>"${_stderr_file}")" || {
    local _diag
    _diag="$(cat "${_stderr_file}" 2>/dev/null || true)"
    rm -f "${_stderr_file}"
    # Distinguish 404 (absence) from other API failures (error).
    if echo "${_diag}" | grep -qE 'HTTP.?404|404.*not found'; then
      return 1
    fi
    # Non-404 API error — log sanitized diagnostics and signal error.
    echo "‼ validate_history_label: API error for '${label_name}': $(echo "${_diag}" | head -1)" >&2
    return 2
  }
  rm -f "${_stderr_file}"
  local color desc
  color="$(echo "${raw}" | jq -r '.color // ""')" || return 2
  desc="$(echo "${raw}" | jq -r '.description // ""')" || return 2
  if [[ "${color}" != "${HISTORY_COLOR}" ]] || [[ "${desc}" != "${HISTORY_DESC}" ]]; then
    return 1
  fi
  return 0
}

validate_history_label "${LABEL_NAME}" || rc=$?
case ${rc:-0} in
  0)
    echo "Label ${LABEL_NAME} already exists with correct definition"
    exit 0
    ;;
  1) ;;  # absent — proceed to create
  2)
    echo "‼ Failed to check label ${LABEL_NAME} (API error)" >&2
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
      echo "Label ${LABEL_NAME} already exists (created concurrently)"
      exit 0
      ;;
    1)
      echo "‼ Label '${LABEL_NAME}' exists with conflicting definition" >&2
      exit 1
      ;;
    *)
      echo "‼ Failed to create label ${LABEL_NAME}" >&2
      exit 1
      ;;
  esac
fi

echo "Created label ${LABEL_NAME}"
