#!/usr/bin/env python3
"""Emit doctor line skeletons from stock templates (maintainer-only; no runtime Python).

Regenerate with:
  python3 scripts/maintainer/generate-template-residue.py > scripts/template-residue.tsv
"""

import argparse
from collections import Counter
from pathlib import Path
import re


# Project-owned seeds only. The omitted templates produce scratch/dispatch text.
NON_SEEDS = {"implementation-plan", "pr-summary", "review-prompt"}

# Illustrative comments and fences are ignored unless they document a literal
# scaffold intended to be copied out. Keep those exceptions here. The first
# two fenced examples are checked as *active text*, never inside example fences.
COPY_FROM_FENCE = {("agents", "text"), ("config", "text")}
KEEP_IN_FENCE = {
    ("constitution", "text"): "commands",
    ("product", "mermaid"): "mermaid",
    ("architecture", "mermaid"): "mermaid",
    ("architecture-topics", "mermaid"): "mermaid",
}
COPY_FROM_COMMENT = {
    "architecture-topics": (r"`(# <[^>]+> — <[^>]+>)`",),
    "authority": (r"^(\*\*(?:Source|Date)\*\*: .+)$",),
    "decision": (
        r"^(## D-NN .+|- \*\*(?:Decision|Alternatives|Revisit when)\*\*: .+)$",
        r"`(# <[^>]+> — <[^>]+> \(D-NN\))`",
    ),
    "inbox": (r"^(\*[A-Z-]+ · .+|\*\*Related\*\*: .+|<.+>)$",),
    "records": (r"^((?:HOLD|WAIVER|ATTEST|DEPLOY) +.+)$",),
}
PLAIN_SLOTS = {
    "agent-definition@frontmatter": r"^(?:name|domain|description): (.+)$",
    "inbox": r"^\*([A-Z-]+) · ",
}

# An outer prompt such as <owner, date: "<words>"; ...> is one fillable field.
SLOT = re.compile(r"<(?:[^<>]|<[^<>]*>)+>")
COMMENT = re.compile(r"<!--(.*?)-->", re.S)
FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})(.*)$")
# Real formats allow a row without its trailing metadata. Generate those
# complete shorter forms from the same source row, not free-standing fragments.
OPTIONAL_TAIL = re.compile(r"\. (?:Journeys|Source|Enforced by|Test|Users see): | · \*\*Next\*\*: ")
# These are example values, not reportable slots. A remainder may keep the
# scaffold while using a different record ID or maturity.
EXAMPLE_VALUE = re.compile(
    r"\b(?:[JRQCN]-0[1-9]|D-(?:01|NN)|P[1-9]|A1|NOT_RUN)\b"
    r"|\bp[1-9](?=-)|\bj-0[1-9](?=-)|(?<=\.)(?:B|I)-01\b| \(hypothesis\)"
)
NUMBER = "[0-9][0-9]*"
ITEM_NUMBER = "[0-9]" + NUMBER
PART_ID = NUMBER + r"(\." + NUMBER + ")?"
ID_SEPARATOR = "( *, *| +)"
RANGE_SEPARATOR = r" *(to|through|-|–|—|\.\.) *"


def citation_list(*ids):
    # spec-lib.sh recognizes numbered citations; bounds.sh and doctor.sh also
    # recognize closed ranges of the same kind. The change metadata reader
    # accepts commas and whitespace as separators, including for subparts.
    citation = "(" + "|".join(f"{id_}({RANGE_SEPARATOR}{id_})?" for id_ in ids) + ")"
    return citation + f"({ID_SEPARATOR}{citation})*"


JOURNEYS = citation_list("J-" + ITEM_NUMBER)
PART = "P" + PART_ID
REFERENCES = citation_list(PART, PART + r"\.[BI]-" + ITEM_NUMBER,
                           *(kind + "-" + ITEM_NUMBER for kind in "JRQCDN"))
# Only expand a sample when it occupies a citation field, never a definition
# ID, a single link's label/path, a reference to one band or decision, or a
# Mermaid node. The literal label/column/delimiter still anchors each field.
CITATION_FIELDS = {
    "requirements": ((rf"(?<=Journeys: ){JOURNEYS}(?=\.)", JOURNEYS),),
    "qualities": ((rf"(?<=Journeys: ){JOURNEYS}(?=\.)", JOURNEYS),),
    "part": ((rf"(?<=Users see: ){JOURNEYS}(?=, Variations\.)", JOURNEYS),),
    "architecture": ((rf"(?<=\| ){REFERENCES}(?= \|)", REFERENCES),),
    "product": ((rf"(?<=\| ){JOURNEYS}(?= \|)", JOURNEYS),),
}
JOURNEY_LINK = rf"\[J-{ITEM_NUMBER}( [^]|]*)?\]\(product/journeys/j-{ITEM_NUMBER}-[^)|]+\.md\)"
LINK_SEPARATOR = " *, *"
LINK_CELL_EDGES = (
    (r"(?<=\| )(?=\[J-[0-9]+ )", f"({JOURNEY_LINK}{LINK_SEPARATOR})*"),
    (r"(?<=\.md\))(?= \|)", f"({LINK_SEPARATOR}{JOURNEY_LINK})*"),
)


def normalize(text):
    return " ".join(text.replace(r"\<", "<").split())


def logical_rows(lines):
    """Join a soft-wrapped placeholder, retaining its full scaffold line."""
    pending = []
    for raw in lines:
        if not raw.strip():
            if pending:
                yield normalize(" ".join(pending)), len(pending) > 1
            pending = []
            continue
        pending.append(raw)
        joined = normalize(" ".join(pending))
        if "<" not in SLOT.sub("", joined) or len(pending) == 3:
            yield joined, len(pending) > 1
            pending = []
    if pending:
        yield normalize(" ".join(pending)), len(pending) > 1


def source_rows(family, text):
    copied = []

    def take_comment(match):
        for selector in COPY_FROM_COMMENT.get(family, ()):
            copied.extend(re.findall(selector, match[1].strip(), re.M))
        return "\n" * match[0].count("\n")

    text = COMMENT.sub(take_comment, text)
    yield from ((family, normalize(row), False) for row in copied)

    frontmatter = False
    mark = ""
    pending = []
    group = family

    def flush():
        return ((group, row, wrapped) for row, wrapped in logical_rows(pending))

    for n, line in enumerate(text.splitlines()):
        fence = FENCE.match(line)
        if family == "agent-definition" and line == "---" and (n == 0 or frontmatter):
            yield from flush()
            pending = []
            frontmatter = n == 0
            group = family + "@frontmatter" if frontmatter else family
        elif fence and (not mark or (fence[1].startswith(mark) and not fence[2].strip())):
            yield from flush()
            pending = []
            if mark:
                mark = ""
                group = family
            else:
                mark, language = fence[1], fence[2].strip()
                key = (family, language)
                context = KEEP_IN_FENCE.get(key)
                group = f"{family}@{context}" if context else family if key in COPY_FROM_FENCE else ""
        elif group and not line.lstrip().startswith(">"):
            pending.append(line)
    yield from flush()


def escape(text):
    """Quote for POSIX ERE (not Python's wider escape set)."""
    return re.sub(r"[][\\.^$*+?(){}|]", r"\\\g<0>", text)


def scalar_regex(text):
    def value(match):
        word = match[0]
        if word == " (hypothesis)":
            return r"( \([^)]*\))?"
        if word == "NOT_RUN":
            return "[A-Z_]+"
        if word == "D-NN":
            return "(D-NN|D-" + NUMBER + ")"
        if "-" in word:
            return word.split("-")[0] + "-" + NUMBER
        if word[0] in "Pp":
            return word[0] + PART_ID
        return word[0] + NUMBER

    parts = []
    start = 0
    for match in EXAMPLE_VALUE.finditer(text):
        parts.extend((escape(text[start:match.start()]), value(match)))
        start = match.end()
    return "".join(parts) + escape(text[start:])


def literal_regex(text, group, linked_table):
    if group.endswith("@mermaid"):
        # Keep the stock node names and edges: a label alone is not a scaffold.
        return escape(text)
    rules = CITATION_FIELDS.get(group, ())
    if linked_table:
        # Stage cells may contain several links; allow filled neighbours on
        # either side of the stock link without crossing into another column.
        rules += LINK_CELL_EDGES
    fields = sorted((match.start(), match.end(), regex)
                    for source, regex in rules for match in re.finditer(source, text))
    pieces = []
    cursor = 0
    for start, end, regex in fields:
        pieces.extend((scalar_regex(text[cursor:start]), regex))
        cursor = end
    return "".join(pieces) + scalar_regex(text[cursor:])


def slot_spans(group, row):
    # Inline-code notation in stock prose is illustrative. A slot that contains
    # an inline-code span (e.g. the platform source prompt) is still an outer slot.
    code = list(re.finditer(r"(`+).*?\1", row))
    for match in SLOT.finditer(row):
        if not any(span.start() < match.start() < span.end() for span in code):
            yield match.start(), match.end(), match[0]
    if group in PLAIN_SLOTS:
        match = re.match(PLAIN_SLOTS[group], row)
        if match and not SLOT.fullmatch(match[1]):
            yield match.start(1), match.end(1), match[1]


def filled_regex(row, end, token, diagram):
    if token in {"<n>", "<NN>"}:
        return "[^ ]*"
    if row[end:].startswith(("](", ".md)", ".md) ")):
        # Link captions/destinations must not swallow the next link's slot.
        return ("[^]]*" if row[end] == "]" else "[^)]*")
    if row.startswith("|") and row.endswith("|"):
        return "[^|]*"
    if diagram and row[end:].startswith(("]", ")", "|")):
        return "[^" + row[end] + "]*"
    return ".*"


def skeletons(group, row, wrapped):
    spans = sorted(slot_spans(group, row))
    if not spans:
        return
    ends = [m.start() + (row[m.start()] == ".") for m in OPTIONAL_TAIL.finditer(row)
            if not any(a <= m.start() < b for a, b, _ in spans)]
    ends.append(len(row))
    seen = Counter()
    diagram = group.endswith("@mermaid")
    linked_table = group == "product" and row.startswith("|") and "(product/journeys/" in row
    for start, end, token in spans:
        seen[token] += 1
        variants = []
        for stop in ends:
            if stop < end:
                continue
            pieces = []
            cursor = 0
            for a, b, slot in spans:
                if b > stop:
                    break
                pieces.append(literal_regex(row[cursor:a], group, linked_table))
                pieces.append(escape(slot) if a == start else filled_regex(row, b, slot, diagram))
                cursor = b
            pieces.append(literal_regex(row[cursor:stop], group, linked_table))
            variants.append("".join(pieces))
        pattern = variants[0] if len(variants) == 1 else "(" + "|".join(variants) + ")"
        # A row may wrap differently after filling a value. Join project
        # lines only for scaffold known to contain a wrapped source row.
        yield "\t".join((group, token, str(seen[token]), str(int(wrapped)), "^" + pattern + "$"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("templates", type=Path, nargs="?",
                        default=Path(__file__).resolve().parents[2] / "templates")
    args = parser.parse_args()
    rows = set()
    for path in args.templates.glob("*-template.md"):
        family = path.name.removesuffix("-template.md")
        if family not in NON_SEEDS:
            for group, row, wrapped in source_rows(family, path.read_text(encoding="utf-8")):
                rows.update(skeletons(group, row, wrapped))
    print("# Generated by scripts/maintainer/generate-template-residue.py; do not edit.")
    for row in sorted(rows):
        print(row)


if __name__ == "__main__":
    main()
