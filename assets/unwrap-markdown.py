#!/usr/bin/env python3
"""Join hard-wrapped prose back into one line per paragraph.

    python3 assets/unwrap-markdown.py README.md

Kept because the wrapping will come back otherwise: it is a habit, and this is
the tool for undoing it in one pass rather than by hand.

The wrapping was a convention I applied, not a requirement of anything. GitHub
soft-wraps regardless, and a hard wrap means changing one word reflows the
paragraph, so an editor that reflows differently produces a diff the size of the
document. That is exactly what happened.

Left alone: fenced code, tables, headings, HTML blocks, and anything indented,
because in all of those a line break is content rather than formatting. List
items keep their bullet and absorb their own continuation lines.
"""
import sys
import pathlib

FENCE = ("```", "~~~")


def unwrap(text: str) -> str:
    out, para = [], []

    def flush():
        if para:
            out.append(" ".join(line.strip() for line in para))
            para.clear()

    in_fence = False
    for raw in text.split("\n"):
        stripped = raw.strip()

        if stripped.startswith(FENCE):
            flush()
            in_fence = not in_fence
            out.append(raw)
            continue
        if in_fence:
            out.append(raw)
            continue

        structural = (
            not stripped                       # blank
            or stripped.startswith("#")        # heading
            or stripped.startswith("|")        # table
            or stripped.startswith(">")        # quote
            or stripped.startswith("<")        # html
            or stripped.startswith("---")      # rule
            or raw.startswith(("    ", "\t"))  # indented block
        )
        bullet = stripped.startswith(("- ", "* ", "+ ")) or (
            stripped[:2].rstrip(".").isdigit() and ". " in stripped[:4])

        if structural:
            flush()
            out.append(raw)
        elif bullet:
            flush()
            para.append(raw)
        else:
            para.append(raw)

    flush()
    return "\n".join(out)


for path in sys.argv[1:]:
    p = pathlib.Path(path)
    p.write_text(unwrap(p.read_text()))
    print(f"unwrapped {path}")
