#!/usr/bin/env bash
# Shared constants for assignment automation scripts.
#
# Source-only — do NOT execute this file directly.
# Sourced by assign-issue.sh and record-assignment-history.sh to eliminate
# production drift for history-label policy values.
#
# Must remain shellcheck-clean (enable=all, severity=style).
# shellcheck disable=SC2034

HISTORY_PREFIX='asnhist--'
HISTORY_COLOR='0E8A16'
HISTORY_DESC='Issue assignment history index'

# Validate a GitHub login: nonempty, alphanumeric + hyphen, max 39 chars.
# Returns 0 on valid; nonzero on invalid.
validate_github_login() {
  local login="$1"
  [[ -n "${login}" ]] || return 1
  [[ "${#login}" -le 39 ]] || return 1
  [[ "${login}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
}
