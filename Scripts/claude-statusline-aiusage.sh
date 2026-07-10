#!/bin/zsh

set -u
umask 077

input="$(cat)"
cache="$HOME/.claude/usage-cache.json"
error_file="$HOME/.claude/usage-cache.error.json"
lock="$HOME/.claude/usage-cache.lock"
captured_at="$(date +%s)"
lock_stale_after=30

write_error() {
  local code="$1"
  local temporary="$error_file.$$.tmp"
  printf '{"code":"%s","observed_at":%s}\n' "$code" "$captured_at" > "$temporary" 2>/dev/null \
    && /bin/mv -f "$temporary" "$error_file" 2>/dev/null
  /bin/rm -f "$temporary"
}

write_cache() {
  local payload="$1"
  local temporary="$cache.$$.tmp"
  if ! printf '%s\n' "$payload" > "$temporary" \
    || ! /usr/bin/plutil -convert json -o /dev/null "$temporary" >/dev/null 2>&1 \
    || ! /bin/mv -f "$temporary" "$cache"; then
    /bin/rm -f "$temporary"
    write_error "cache_write_failed"
    return 1
  fi
  /bin/rm -f "$error_file"
}

acquire_lock() {
  local modified_at

  if /bin/mkdir "$lock" 2>/dev/null; then
    return 0
  fi

  modified_at="$(/usr/bin/stat -f %m "$lock" 2>/dev/null)" || return 1
  [[ "$modified_at" == <-> ]] || return 1
  (( captured_at - modified_at > lock_stale_after )) || return 1

  /bin/rmdir "$lock" 2>/dev/null || return 1
  /bin/mkdir "$lock" 2>/dev/null
}

extract_input_number() {
  local key="$1"
  local value
  value="$(printf '%s' "$input" | /usr/bin/plutil -extract "$key" raw -o - - 2>/dev/null)" \
    || return 1
  [[ "$value" == <-> || "$value" == <->.<-> ]] || return 1
  printf '%s' "$value"
}

extract_cache_number() {
  local key="$1"
  local value
  [[ -f "$cache" ]] || return 1
  value="$(/usr/bin/plutil -extract "$key" raw -o - "$cache" 2>/dev/null)" \
    || return 1
  [[ "$value" == <-> || "$value" == <->.<-> ]] || return 1
  printf '%s' "$value"
}

if ! printf '%s' "$input" \
  | /usr/bin/plutil -convert json -o /dev/null - >/dev/null 2>&1; then
  write_error "invalid_statusline_json"
  exit 0
fi

# Serialize writers from multiple Claude Code sessions. An abandoned empty lock
# is recovered after a short grace period; an active writer keeps ownership.
if ! acquire_lock; then
  exit 0
fi
trap '/bin/rmdir "$lock" 2>/dev/null' EXIT

five_used="$(extract_input_number rate_limits.five_hour.used_percentage || true)"
five_reset="$(extract_input_number rate_limits.five_hour.resets_at || true)"
week_used="$(extract_input_number rate_limits.seven_day.used_percentage || true)"
week_reset="$(extract_input_number rate_limits.seven_day.resets_at || true)"

has_five=0
has_week=0
[[ -n "$five_used" && -n "$five_reset" ]] && has_five=1
[[ -n "$week_used" && -n "$week_reset" ]] && has_week=1

if (( ! has_five && ! has_week )); then
  old_status="$(/usr/bin/plutil -extract status raw -o - "$cache" 2>/dev/null || true)"
  old_five_reset="$(extract_cache_number rate_limits.five_hour.resets_at || true)"
  if [[ "$old_status" == "ready" && -n "$old_five_reset" ]] \
    && (( old_five_reset > captured_at )); then
    exit 0
  fi

  current_usage="$(
    printf '%s' "$input" \
      | /usr/bin/plutil -extract context_window.current_usage json -o - - 2>/dev/null \
      || true
  )"
  if [[ -n "$current_usage" && "$current_usage" != "null" ]]; then
    cache_status="unsupported_account"
  else
    cache_status="waiting_for_first_response"
  fi
  write_cache "{\"captured_at\":$captured_at,\"status\":\"$cache_status\",\"rate_limits\":null}"
  exit 0
fi

old_captured="$(extract_cache_number captured_at || true)"
old_five_used="$(extract_cache_number rate_limits.five_hour.used_percentage || true)"
old_five_reset="$(extract_cache_number rate_limits.five_hour.resets_at || true)"
old_week_used="$(extract_cache_number rate_limits.seven_day.used_percentage || true)"
old_week_reset="$(extract_cache_number rate_limits.seven_day.resets_at || true)"

selected_five_used="$five_used"
selected_five_reset="$five_reset"
selected_week_used="$week_used"
selected_week_reset="$week_reset"
fresh_five_observation=0
fresh_week_observation=0

if (( has_five )); then
  if [[ -n "$old_five_used" && -n "$old_five_reset" ]]; then
    if (( five_reset < old_five_reset \
      || (five_reset == old_five_reset && five_used < old_five_used) )); then
      selected_five_used="$old_five_used"
      selected_five_reset="$old_five_reset"
    else
      fresh_five_observation=1
    fi
  else
    fresh_five_observation=1
  fi
elif [[ -n "$old_five_used" && -n "$old_five_reset" ]] \
  && (( old_five_reset > captured_at )); then
  selected_five_used="$old_five_used"
  selected_five_reset="$old_five_reset"
fi

if (( has_week )); then
  if [[ -n "$old_week_used" && -n "$old_week_reset" ]]; then
    if (( week_reset < old_week_reset \
      || (week_reset == old_week_reset && week_used < old_week_used) )); then
      selected_week_used="$old_week_used"
      selected_week_reset="$old_week_reset"
    else
      fresh_week_observation=1
    fi
  else
    fresh_week_observation=1
  fi
elif [[ -n "$old_week_used" && -n "$old_week_reset" ]] \
  && (( old_week_reset > captured_at )); then
  selected_week_used="$old_week_used"
  selected_week_reset="$old_week_reset"
fi

if [[ -n "$selected_five_reset" ]] && (( selected_five_reset <= captured_at )); then
  selected_five_used=""
  selected_five_reset=""
  fresh_five_observation=0
fi
if [[ -n "$selected_week_reset" ]] && (( selected_week_reset <= captured_at )); then
  selected_week_used=""
  selected_week_reset=""
  fresh_week_observation=0
fi

if (( fresh_five_observation )) \
  || { [[ -z "$selected_five_reset" ]] && (( fresh_week_observation )); } \
  || [[ -z "$old_captured" ]]; then
  cache_captured_at="$captured_at"
else
  cache_captured_at="$old_captured"
fi

five_json="null"
week_json="null"
if [[ -n "$selected_five_used" && -n "$selected_five_reset" ]]; then
  five_json="{\"used_percentage\":$selected_five_used,\"resets_at\":$selected_five_reset}"
fi
if [[ -n "$selected_week_used" && -n "$selected_week_reset" ]]; then
  week_json="{\"used_percentage\":$selected_week_used,\"resets_at\":$selected_week_reset}"
fi

write_cache "{\"captured_at\":$cache_captured_at,\"status\":\"ready\",\"rate_limits\":{\"five_hour\":$five_json,\"seven_day\":$week_json}}"
exit 0
