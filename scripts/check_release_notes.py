#!/usr/bin/env python3
"""Check that a release's two note bodies do not contradict each other.

The plain-text notes reach the Sparkle dialog, appcast.xml and latest.json;
the markdown reaches the GitHub release page. They are written separately
because those audiences need different shapes, which leaves room for the same
change to be described with different figures in each. That is the failure this
guards: a reader comparing the update dialog against the release page should
not find two different numbers for one measurement.

The rule is one-directional. Every number in the .txt must appear in the .md,
not the reverse: the markdown legitimately carries figures the dialog omits,
such as table contents or a longer worked example.

Numbers are compared after folding the glyphs the two files spell differently.
The v1.17.0 pair writes the same values as `1.25x` / `-5.9%` / `18-28` in the
text and `1.25x` / `-5.9%` / `18-28` in the markdown using U+00D7, U+2212 and
U+2013 respectively, so a comparison over raw characters would report a
contradiction that is not there. Thousands separators are stripped for the
same reason (`1,144` against `1144`).
"""
import re
import sys
from pathlib import Path

FOLD = str.maketrans({"−": "-", "–": "-", "—": "-", "×": "x"})
NUMBER = re.compile(r"\d+(?:\.\d+)?")


def numbers(path: Path) -> list[str]:
    text = path.read_text(encoding="utf-8").translate(FOLD).replace(",", "")
    return NUMBER.findall(text)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: check_release_notes.py <tag>", file=sys.stderr)
        return 2
    tag = sys.argv[1]
    txt_path = Path("release-notes") / f"{tag}.txt"
    md_path = Path("release-notes") / f"{tag}.md"

    missing = [p for p in (txt_path, md_path) if not p.is_file()]
    if missing:
        for p in missing:
            print(f"error: missing {p}", file=sys.stderr)
        return 1

    txt = numbers(txt_path)
    md = set(numbers(md_path))
    absent = sorted({n for n in txt if n not in md}, key=float)

    if absent:
        print(f"error: {len(absent)} number(s) in {txt_path} do not appear in {md_path}:",
              file=sys.stderr)
        for n in absent:
            for line in txt_path.read_text(encoding="utf-8").splitlines():
                if n in line.translate(FOLD).replace(",", ""):
                    print(f"  {n}  <- {line.strip()[:100]}", file=sys.stderr)
                    break
            else:
                print(f"  {n}", file=sys.stderr)
        print("The Sparkle dialog would state a figure the release page does not.",
              file=sys.stderr)
        return 1

    print(f"{txt_path}: {len(txt)} numbers ({len(set(txt))} distinct), all present in {md_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
