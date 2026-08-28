#!/bin/bash
# Minimal assertion helpers. No framework, no dependencies beyond jq.
# Every assertion prints a one-line result so a failing run says what broke.

TESTS_RUN=0
TESTS_FAILED=0

_pass() { TESTS_RUN=$((TESTS_RUN + 1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
_fail() {
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_FAILED=$((TESTS_FAILED + 1))
  printf '  \033[31mFAIL\033[0m %s\n' "$1"
  [[ -n ${2:-} ]] && printf '       expected: %s\n' "$2"
  [[ -n ${3:-} ]] && printf '       actual:   %s\n' "$3"
  return 0
}

assert_eq() { # <label> <expected> <actual>
  if [[ "$2" == "$3" ]]; then _pass "$1"; else _fail "$1" "$2" "$3"; fi
}

assert_ne() { # <label> <not-expected> <actual>
  if [[ "$2" != "$3" ]]; then _pass "$1"; else _fail "$1" "not $2" "$3"; fi
}

assert_ge() { # <label> <minimum> <actual>
  if (( $3 >= $2 )); then _pass "$1"; else _fail "$1" ">= $2" "$3"; fi
}

assert_contains() { # <label> <needle> <haystack>
  if [[ "$3" == *"$2"* ]]; then _pass "$1"; else _fail "$1" "contains '$2'" "$3"; fi
}

suite_summary() { # <suite name>
  echo
  if (( TESTS_FAILED == 0 )); then
    printf '\033[32m%s: %d passed\033[0m\n' "$1" "$TESTS_RUN"
    return 0
  fi
  printf '\033[31m%s: %d of %d FAILED\033[0m\n' "$1" "$TESTS_FAILED" "$TESTS_RUN"
  return 1
}
