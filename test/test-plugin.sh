#!/bin/bash
# The Omarchy plugin manifest, and the one widget it declares.
#
# WHY THIS SUITE EXISTS AT ALL. `omarchy plugin add` clones the repo, runs
# `omarchy-plugin-validate` on it, and refuses the whole thing if the manifest
# is wrong. That refusal happens on a stranger's machine, after the clone, with
# no way for them to tell a typo from a broken plugin. Every check below is one
# that validator makes, run here instead, where it is our problem.
#
# It is reimplemented rather than shelled out to on purpose: this suite has to
# pass on a machine with no Omarchy on it, which is the whole rule for
# ./test/all. python3 is already required by the runner, so nothing new is
# needed to read JSON.

set -uo pipefail
cd "$(dirname "$0")" || exit 1
source ./helpers.sh

M=../manifest.json
W=../qml/BarWidget.qml

# `--` before the pattern, for the same reason test-wiring.sh does it: a needle
# that begins with a dash is read by grep as an option and matches nothing, so
# the assertion fails on code that is perfectly correct.
has_in() { grep -qF -- "$3" "$2" && _pass "$1" || _fail "$1" "$3" "absent"; }

# --- the manifest ----------------------------------------------------------

if [[ ! -r $M ]]; then
  _fail "manifest.json exists" "$M" "missing"
  suite_summary "plugin manifest"
  exit 1
fi
_pass "manifest.json exists"

# ONE PASS, MANY ANSWERS. Reading the file once and emitting key=value keeps
# the assertions below in bash where the rest of the suite lives, without
# starting a python for each one.
facts=$(python3 - "$M" <<'PY'
import json, sys

try:
    m = json.load(open(sys.argv[1]))
except Exception as e:
    print(f"parsed=no\nwhy={e}")
    sys.exit(0)

print("parsed=yes")
# `is` on the type, because JSON true is an int in python and would otherwise
# satisfy a check for the number 1. The registry compares with ===, which does
# not.
print(f"schema_is_one={'yes' if type(m.get('schemaVersion')) is int and m['schemaVersion'] == 1 else 'no'}")
for field in ("id", "name", "version", "kinds", "entryPoints"):
    print(f"has_{field}={'yes' if field in m else 'no'}")
print(f"id={m.get('id', '')}")
print(f"kinds={','.join(m.get('kinds') or [])}")
for kind, key in (("bar-widget", "barWidget"), ("bar", "bar"), ("menu", "menu"),
                  ("overlay", "overlay"), ("panel", "panel"), ("service", "service")):
    if kind in (m.get("kinds") or []):
        print(f"entry_for_{key}={(m.get('entryPoints') or {}).get(key, '')}")
print(f"section={((m.get('barWidget') or {}).get('defaultSection', ''))}")
# Every entry point, so the shell asserts each one is a real relative file.
for key, value in (m.get("entryPoints") or {}).items():
    print(f"entrypoint={value}")
PY
)

get() { sed -n "s/^$1=//p" <<<"$facts" | head -1; }

assert_eq "the manifest is valid JSON"           "yes" "$(get parsed)"
assert_eq "schemaVersion is the number 1"        "yes" "$(get schema_is_one)"
for field in id name version kinds entryPoints; do
  assert_eq "the manifest declares $field"       "yes" "$(get "has_$field")"
done

# THE ID IS THE INSTALL PATH AND THE LOOKUP KEY. It becomes the directory under
# ~/.config/omarchy/plugins/, so a slash or a dot-dot in it is a path escape,
# and the omarchy.* namespace is reserved for first-party plugins.
id=$(get id)
assert_eq "the id is reverse domain, from the repo owner" "io.github.omashift.omashift" "$id"
assert_eq "the id is not in the reserved namespace" 0 "$(grep -c '^omarchy\.' <<<"$id")"
assert_eq "and carries nothing that walks a path"   0 \
  "$(grep -cE '/|\.\.' <<<"$id")"

# A DRIFT HERE IS SILENT. The host looks the widget up by moduleName; a widget
# whose name does not match its manifest loads, draws, and is then never
# addressed by anything again.
has_in "the widget names the same id"            "$W" "moduleName: \"$id\""

# Claiming a kind without the entry point it loads from is accepted everywhere
# except the validator: the widget is simply skipped, and the only trace is a
# line on the shell's console.
assert_eq "the declared kinds are the thin set"  "bar-widget" "$(get kinds)"
assert_eq "and bar-widget names its entry point" "qml/BarWidget.qml" "$(get entry_for_barWidget)"
assert_eq "the default bar section is a real one" 1 \
  "$(grep -cE '^(left|center|right)$' <<<"$(get section)")"

# Entry points are resolved against the plugin directory and must stay inside
# it, so an absolute path or a dot-dot is refused rather than followed.
while IFS= read -r ep; do
  [[ -n $ep ]] || continue
  assert_eq "entry point '$ep' is a relative path" 0 "$(grep -cE '^/|\.\.' <<<"$ep")"
  if [[ -f ../$ep ]]; then
    _pass "entry point '$ep' is a file that exists"
  else
    _fail "entry point '$ep' is a file that exists" "../$ep" "missing"
  fi
done < <(sed -n 's/^entrypoint=//p' <<<"$facts")

# A SYMLINK ANYWHERE IN THE TREE FAILS THE INSTALL. Once the clone lands in the
# trusted plugins directory, a link inside it points the shell at a file
# nobody reviewed, so the validator refuses the whole plugin rather than the
# link. .git is skipped: it is a checkout, and the shell never loads its
# internals.
links=$(cd .. && find . -name .git -prune -o -type l -print 2>/dev/null | wc -l)
assert_eq "no symlinks anywhere in the tree"     0 "$links"

# --- what the widget is allowed to do --------------------------------------
#
# THE SAFETY PROPERTY, PINNED. A pointer that can start a stage is a pointer
# that can take somebody's keyboard by accident, so the widget is allowed
# exactly two commands: the bare launcher, which arms a stage and draws the
# menu, and --stop, which retires one. Both are safe from every state, which is
# also why neither is chosen by reading the state file.
#
# Counted on stripped code so this block's own explanation is not the thing it
# finds. Same helper shape as test-wiring.sh, for the same reason.
runs=$(sed -e 's,//.*,,' "$W" | grep -cF -- "root.launch(")
assert_eq "the widget runs exactly two commands" 2 "$runs"
has_in "the left click only opens the game"      "$W" "root.launch([root.launcher]);"
has_in "the right click retires a stage"         "$W" "root.launch([root.launcher, \"--stop\"]);"

# AND BOTH GO THROUGH THE DEBOUNCE. A click wired straight to execArgv would
# skip it, which is the only way this guard can be lost: it fails open, and a
# lost debounce looks exactly like a working widget until two launchers stage
# the engine on top of each other.
assert_eq "and neither click bypasses the debounce" 1 \
  "$(sed -e 's,//.*,,' "$W" | grep -cF -- "Util.execArgv(")"
has_in "the debounce covers the staging window"  "$W" "now - root.lastLaunchAt < 2500"

# --go and --again fire an armed stage, which is the moment the submap engages.
# Neither belongs behind a pointer.
for forbidden in "--go" "--again" "--menu"; do
  assert_eq "the widget cannot fire a stage with $forbidden" 0 \
    "$(sed -e 's,//.*,,' "$W" | grep -cF -- "\"$forbidden\"")"
done

# THE LAUNCHER IS FOUND RELATIVE TO THE PLUGIN, NOT ON PATH. Arriving through
# `omarchy plugin add` is exactly the case where ./install has not been run, so
# a widget that shells out to a bare `omashift` would do nothing at all and say
# nothing about why.
has_in "the launcher is resolved from this file" "$W" 'Qt.resolvedUrl("../bin/omashift")'

# NOTHING OF THE GAME IS IMPORTED INTO THE SHELL'S PROCESS. The standalone
# display is standalone on purpose; pulling any of it in here would put a
# fullscreen game's code inside the bar, which is the thing shell.qml's header
# refuses.
for forbidden in Surface StateReader Theme Wordmark Cabinet Stats; do
  assert_eq "the widget does not pull in $forbidden.qml" 0 \
    "$(sed -e 's,//.*,,' "$W" | grep -cF -- "$forbidden {")"
done

# --- what a marketplace listing needs -------------------------------------
#
# The marketplace checklist is five statements you attest to by hand, and two of
# them are facts about this repository rather than promises about intent. A
# reviewer checks them; so does this.
has_in "the README documents the plugin install" ../README.md "omarchy plugin add"
has_in "and how to remove it again"              ../README.md "omarchy plugin remove"

suite_summary "plugin manifest"
