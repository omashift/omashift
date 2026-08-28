#!/usr/bin/env python3
"""Every assertion in a shell suite has to be one complete line.

    python3 test/lint-assertions.py test/test-wiring.sh [...]

WHY THIS EXISTS

An assertion with an unterminated quote does not fail. Bash keeps reading until
it finds a matching quote on some later line, so the needle silently swallows
the assertions that follow and then MATCHES ANYWAY, because `grep -F` treats a
newline in the pattern as an alternative. The suite reports green, one check is
testing nonsense, and the ones it ate are simply gone.

That happened three times in one day, in this file, and care was not catching
it. `bash -n` on the whole file cannot catch it either: the result is
syntactically valid, because the quote does eventually close.

HOW IT CHECKS

Not by demanding that every assertion fit on one line: a legitimate one can span
several, when the argument is a multi-line jq program inside a quoted command
substitution. That is valid and common in these suites, and an earlier version
of this file flagged it, which is how a linter loses its audience.

The rule is narrower and is exactly the failure mode: AN ASSERTION MAY NOT
SWALLOW ANOTHER ASSERTION. Each one is extended forward, line by line, until
bash can parse it. If anything inside that span begins another assertion, the
quotes closed in the wrong place and everything between has silently stopped
running.

Prints one line per problem and nothing when clean.
"""
import subprocess
import sys
import pathlib

HELPERS = ("has ", "has_in ", "says ", "body ", "assert_eq ", "assert_ne ",
           "assert_ge ", "assert_contains ", "code_count ")

# Far beyond any real assertion. Without it, one broken quote near the top would
# drag the reader to the end of the file.
MAX_SPAN = 30


def starts_assertion(line: str) -> bool:
    return any(line.lstrip().startswith(h) for h in HELPERS)


def parses(text: str) -> bool:
    return subprocess.run(["bash", "-n"], input=text, text=True,
                          capture_output=True).returncode == 0


problems = 0
for path in sys.argv[1:]:
    lines = pathlib.Path(path).read_text().split("\n")

    for i, line in enumerate(lines):
        if not starts_assertion(line):
            continue

        # Extend until bash is satisfied, which is where the quotes close.
        span, text = 0, line
        while span < MAX_SPAN and not parses(text):
            span += 1
            if i + span >= len(lines):
                break
            text += "\n" + lines[i + span]

        eaten = [(i + k + 1, lines[i + k])
                 for k in range(1, span + 1)
                 if i + k < len(lines) and starts_assertion(lines[i + k])]
        if eaten:
            print(f"{path}:{i + 1}: this assertion's quotes close "
                  f"{span} line(s) down, swallowing {len(eaten)} more")
            print(f"    {line.strip()[:100]}")
            for n, swallowed in eaten:
                print(f"    line {n} never runs: {swallowed.strip()[:80]}")
            problems += 1
        elif span >= MAX_SPAN:
            print(f"{path}:{i + 1}: quotes never close within {MAX_SPAN} lines")
            print(f"    {line.strip()[:100]}")
            problems += 1

sys.exit(1 if problems else 0)
