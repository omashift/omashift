#!/bin/bash
# The linters, over everything they can read.
#
# WHY THESE THREE
#
# Each one is here because of a bug this project actually shipped, not because
# it is a linter and linters are good.
#
#   the Lua one: in Lua, using a local ABOVE the line that declares it reads a
#               nil global instead. No error, no warning, just wrong behavior.
#               It has happened four times here: `kmh` and `round` in stats.lua,
#               `idle_generation` in engine.lua, and `safe_match` in core.lua,
#               which cost a live debugging session.
#
#   the shell one: `out=$(cmd)` followed by `if (( $? == 0 ))` tests the assignment,
#               which always succeeds. Written in test-qml.sh and caught only by
#               injecting a fault. Also unterminated quotes, which swallowed six
#               assertions in test-wiring.sh and reported green.
#
#   the Python one: the Python is small, and every piece of it is something the
#               suite depends on being correct.
#
# SKIPPED, NOT FAILED, when a tool is absent. This has to pass for somebody who
# cloned the public repo and wants to run the tests, not only for a machine set
# up to develop it.

set -uo pipefail
cd "$(dirname "$0")" || exit 1

run=0; failed=0; skipped=0
ok()   { run=$((run+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { run=$((run+1)); failed=$((failed+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; sed 's/^/       /' <<<"$2"; }
skip() { skipped=$((skipped+1)); printf '  \033[33mskip\033[0m %s (%s)\n' "$1" "$2"; }

printf 'lint:\n'

# --- lua ---------------------------------------------------------------------
if command -v luacheck >/dev/null 2>&1; then
  if out=$(cd .. && luacheck lib test --no-color 2>&1); then
    ok "luacheck is clean over lib/ and test/"
  else
    bad "luacheck is clean over lib/ and test/" "$(tail -40 <<<"$out")"
  fi
else
  skip "luacheck" "pacman -S luacheck"
fi

# --- shell -------------------------------------------------------------------
if command -v shellcheck >/dev/null 2>&1; then
  shopt -s nullglob
  # `install` and `publish` have no extension, and bin/ scripts do not either,
  # so they are named rather than globbed by suffix.
  #
  # FILTERED TO WHAT EXISTS. `publish` is deliberately withheld from a published
  # tree, so naming it unconditionally made this fail for exactly the person the
  # suite most needs to pass for: somebody who just cloned the public repo.
  targets=()
  for candidate in ../bin/* ../install ../publish ./*.sh ../test/all ../test/smoke; do
    [[ -f $candidate ]] && targets+=("$candidate")
  done
  if out=$(shellcheck --shell=bash --severity=warning "${targets[@]}" 2>&1); then
    ok "shellcheck is clean over every script"
  else
    bad "shellcheck is clean over every script" "$(head -60 <<<"$out")"
  fi
else
  skip "shellcheck" "pacman -S shellcheck"
fi

# --- python ------------------------------------------------------------------
if command -v ruff >/dev/null 2>&1; then
  if out=$(cd .. && ruff check assets test 2>&1); then
    ok "ruff is clean over the python"
  else
    bad "ruff is clean over the python" "$(head -40 <<<"$out")"
  fi
else
  skip "ruff" "pacman -S ruff"
fi

printf '\n'
if (( failed )); then
  printf '\033[31mlint: %d of %d FAILED\033[0m\n' "$failed" "$run"
  exit 1
fi
if (( skipped )); then
  printf '\033[32mlint: %d passed, %d skipped\033[0m\n' "$run" "$skipped"
else
  printf '\033[32mlint: %d passed\033[0m\n' "$run"
fi
