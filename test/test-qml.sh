#!/bin/bash
# Does the overlay still parse?
#
# WHAT THIS COVERS THAT NOTHING ELSE DID
#
# Every other suite reads the QML as TEXT: the wiring assertions grep it for the
# strings that prove a feature is connected, which is the honest tool for
# checking that a chord is taken from the model rather than hardcoded. None of
# them can tell whether the file is valid QML. A missing brace or a stray comma
# was found by launching the game and watching a blank screen, which is a slow
# way to learn about a typo and a bad way to find out during a launch.
#
# WHAT IT DOES NOT COVER
#
# Only syntax. The qmllint on this machine is the Qt5-era one, and without
# Quickshell's own qmltypes it reports every Quickshell and QtQuick type as "not
# found", so its unqualified-identifier mode is unusable noise. A binding that
# assigns undefined to a bool still needs a running compositor to notice. That
# gap is real and is why ./test/smoke exists.
#
# SKIPPED, NOT FAILED, when qmllint is absent. This suite has to pass for
# somebody who cloned the public repo and has Quickshell but not Qt's dev tools.

set -uo pipefail
cd "$(dirname "$0")" || exit 1

run=0; failed=0
ok()  { run=$((run+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { run=$((run+1)); failed=$((failed+1)); printf '  \033[31mFAIL\033[0m %s\n       %s\n' "$1" "$2"; }

printf 'qml:\n'

if ! command -v qmllint >/dev/null 2>&1; then
  printf '  \033[33mskip\033[0m qmllint is not installed (pacman -S qt6-declarative)\n\n'
  printf '\033[32mqml: 0 checked\033[0m\n'
  exit 0
fi

shopt -s nullglob
files=(../qml/*.qml)
if (( ${#files[@]} == 0 )); then
  bad "there are QML files to check" "../qml/ is empty"
else
  for f in "${files[@]}"; do
    if out=$(qmllint "$f" 2>&1); then
      ok "$(basename "$f") parses"
    else
      # This qmllint reports a syntax error by exit code alone and prints
      # nothing at all, so there is no detail to pass on and pretending
      # otherwise would print an empty reason under a red FAIL.
      bad "$(basename "$f") parses" \
        "${out:-qmllint rejected it and this build prints no detail; a newer Qt qmllint gives a line number}"
    fi
  done
fi

printf '\n'
if (( failed )); then
  printf '\033[31mqml: %d of %d FAILED\033[0m\n' "$failed" "$run"
  exit 1
fi
printf '\033[32mqml: %d passed\033[0m\n' "$run"
