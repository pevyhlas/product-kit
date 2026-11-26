#!/usr/bin/env python3
"""Emit doctor slot tokens and local anchors (maintainer-only; no runtime Python).

Regenerate with:
  python3 scripts/maintainer/generate-template-residue.py > scripts/template-residue.tsv
"""

import argparse
from collections import defaultdict
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
# Single-word/symbol tokens are generic by default. The few exceptions are
# here, not in the runtime. Record evidence must be the entire reason field;
# the stage labels are common notation even though they contain spaces.
DISTINCTIVE = {"<components>"}
GENERIC = {"<evidence link>", "<Now stage>", "<Next stage>", "<Later stage>"}
MARK = "@slot@"
ITEM = "[0-9][0-9]+"
PART = r"P[0-9]+(\.[0-9]+)?"
JOURNEY_PATH = rf"product/journeys/j-{ITEM}-"
FIELD_LABEL = re.compile(r"(?P<label>\*\*[^*]+\*\*:|[A-Z][a-zA-Z ]*:|next:) $")


def normalize(text):
    return " ".join(text.replace(r"\<", "<").split())


def logical_rows(lines):
    """Join a soft-wrapped stock token so the catalog carries its whole text."""
    pending = []
    for raw in lines:
        if not raw.strip():
            if pending:
                yield normalize(" ".join(pending))
            yield ""
            pending = []
            continue
        pending.append(raw)
        joined = normalize(" ".join(pending))
        if "<" not in SLOT.sub("", joined) or len(pending) == 3:
            yield joined
            pending = []
    if pending:
        yield normalize(" ".join(pending))


def source_rows(family, text):
    copied = []

    def take_comment(match):
        for selector in COPY_FROM_COMMENT.get(family, ()):
            copied.extend(re.findall(selector, match[1].strip(), re.M))
        return "\n" * match[0].count("\n")

    text = COMMENT.sub(take_comment, text)
    yield from ((family, normalize(row)) for row in copied)
    yield family, ""

    frontmatter = False
    mark = ""
    pending = []
    group = family

    def flush():
        return ((group, row) for row in logical_rows(pending))

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


def generic(token):
    return token not in DISTINCTIVE and (token in GENERIC or " " not in token)


def link_anchor(before, after):
    """Match the caption or destination of this link; never its neighbours."""
    if re.search(r"\[J-[0-9]+ $", before) and after.startswith("](product/journeys/"):
        return rf"\[J-{ITEM} $", rf"^\]\({JOURNEY_PATH}[^)]*\.md\)"
    if re.search(r"\]\(product/journeys/j-[0-9]+-$", before):
        return rf"\]\({JOURNEY_PATH}$", r"^\.md\)"
    if after.startswith("](parts/") and re.search(r"\[p[0-9]+-$", before):
        return r"\[p[0-9]+(\.[0-9]+)?-$", r"^\]\(parts/p[0-9]+(\.[0-9]+)?-[^)]*\.md\)"
    if re.search(r"\]\(parts/p[0-9]+-$", before):
        return r"\]\(parts/p[0-9]+(\.[0-9]+)?-$", r"^\.md\)"
    return None


def diagram_anchor(before, after, diagram):
    if diagram == "sequenceDiagram":
        left = re.fullmatch(r"(\w+)(-+>>)(\w+): ", before)
        prefix = rf"{left[1]} *{left[2]} *{left[3]} *: *" if left else escape(before)
        return "diagram", diagram, "^" + prefix + "$", "^$"
    edge = re.search(r"(\w+)(?:\(\[.*\]\))? *--> *\|$", before)
    if edge:
        target = re.match(r"\| *(\w+)", after)[1]
        return "diagram", diagram, (
            rf"(^|(-->|\|) *){edge[1]}(\(\[[^]]*\]\))? *--> *\|$"
        ), rf"^\| *{target}($|[^A-Za-z0-9_])"
    node = re.search(r"\w+(?:\(\[|\[\(|\[)(?:\w+(?:-\d+)? )?$", before)
    if node:
        closing = re.match(r"[\])]+", after)[0]
        return "diagram", diagram, r"(^|(-->|\|) *)" + escape(node[0]) + "$", "^" + escape(closing)
    raise ValueError(f"unrecognized Mermaid slot: {before}{MARK}{after}")


def line_anchor(before, after):
    """Anchor a common token to its own label, heading or definition position."""
    heading = re.match(r"^(#+) ", before)
    if heading:
        prefix = before[heading.end():]
        if prefix.endswith(" — "):
            prefix = ".* — "
        else:
            prefix = {"D-NN ": f"(D-NN|D-{ITEM}) ", "J-<NN> ": f"J-(<NN>|{ITEM}) "}.get(
                prefix, escape(prefix)
            )
        # Keep local heading punctuation, not the value of the next slot.
        tail = re.match(r"^(?: constitution| — | \(| )", after)
        return "^" + heading[1] + " " + prefix + "$", "^" + (escape(tail[0]) if tail else "$")

    label = FIELD_LABEL.search(before)
    if label and "<" not in label["label"]:
        prefix = r"(^(- )?|[.;] | · )" + escape(label["label"]) + " $"
        return prefix, r"^($|[.;]| · | \(| since )"
    if before == "**Now**: <stage> since ":
        return r"^\*\*Now\*\*: .+ since $", r"^($| · )"
    if before == "- <C-01>: holds: ":
        return rf"^- (<C-01>|C-{ITEM}): holds: $", r"^(\.|$)"
    if before == "- " and after.startswith(": holds: "):
        return "^- $", "^: holds: "
    if before.startswith("- **"):
        item = re.match(r"- \*\*((?:[JRQCN]|P<n>\.[BI])-\d+) ", before)
        if item:
            kind = item[1].rsplit("-", 1)[0]
            definition = (rf"({PART}|P<n>)\.[BI]" if kind.startswith("P") else kind) + "-" + ITEM
            begin = r"^- \*\*" + definition + " "
            if before == item[0]:
                return begin + "$", r"^\*\*"
            body = begin + r"[^*]+\*\*( \([^)]*\))?: "
            local = re.search(r" (?:wants|in|is) $", before)
            left = r".*" + escape(local[0]) if local else ""
            right = re.match(r"^(\.| wants | in |; success is )", after)
            return body + left + "$", "^" + (escape(right[0]) if right else "$")
        if before == "- **P":
            return r"^- \*\*P$", rf"^\.[BI]-{ITEM} "
        if before == "- **":
            tail = rf"^\*\* \(D-(NN|{ITEM})\):" if after.startswith("** (D-") else r"^\*\*:"
            return r"^- \*\*$", tail
    if before == "- " and after.startswith(":"):
        return "^- $", "^:"
    if before == "- " and after.startswith(" — "):
        return "^- $", "^ — "
    if not before and not after:
        return "^$", "^$"
    if before == "- " and not after:
        return "^- $", "^$"
    raise ValueError(f"unrecognized generic slot: {before}{MARK}{after}")


def contexts(group, rows):
    header, diagram = [], ""
    for i, row in enumerate(rows):
        if group.endswith("@mermaid") and row.startswith(("flowchart ", "sequenceDiagram")):
            diagram = row.split()[0]
        divider = row.startswith("|") and i + 1 < len(rows) and re.fullmatch(
            r"\|(?: *:?-+:? *\|)+", rows[i + 1]
        )
        if divider:
            header = [c.strip().lower() for c in row.split("|")[1:-1]]
        if not row.startswith("|"):
            header = []
        stage = group == "product" and any("<now stage>" in col for col in header)
        for start, end, token in slot_spans(group, row):
            before, after = row[:start], row[end:]
            if group.endswith("@mermaid"):
                anchor = diagram_anchor(before, after, diagram)
            elif group.endswith("@commands"):
                anchor = ("line", "", "^$", "^$")
            elif not token.startswith("<"):
                anchor = ("plain", "", "^" + escape(before) + "$", "^" + (r" · " if group == "inbox" else "$"))
            elif not generic(token):
                anchor = ("prose", "", ".*", ".*")
            elif header:
                column = before.count("|") - 1
                left = before.rsplit("|", 1)[1].lstrip()
                right = after.split("|", 1)[0].rstrip()
                link = link_anchor(left, right)
                if stage:
                    selector = "header" if divider else "area" if header[column] == "area" else "link"
                else:
                    selector = header[0] + ":" + header[column]
                if token == "<name>" and left == "P1 ":
                    link = (rf"^{PART} $", "^$")
                if stage and divider and right == " (now)":
                    link = ("^$", r"^( \(now\))?$")
                anchor = ("stage" if stage else "table", selector, *(link or ("^$", "^$")))
            elif group == "product" and (link := link_anchor(before, after)):
                anchor = ("journey-link", "", *link)
            elif group == "records":
                kind = before.split()[0]
                if before.endswith(" — "):
                    anchor = ("record-reason", kind, " — $", "^$")
                elif key := re.search(r" \w+=$", before):
                    anchor = ("record-field", kind, escape(key[0]) + "$", "^($| )")
                else:
                    anchor = ("record-field", kind, "^" + kind + " $", "^($| )")
            else:
                anchor = ("line", "", *line_anchor(before, after))
            yield (group, token), anchor


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("templates", type=Path, nargs="?",
                        default=Path(__file__).resolve().parents[2] / "templates")
    args = parser.parse_args()
    catalog = defaultdict(set)
    for path in args.templates.glob("*-template.md"):
        family = path.name.removesuffix("-template.md")
        if family not in NON_SEEDS:
            groups = defaultdict(list)
            for group, row in source_rows(family, path.read_text(encoding="utf-8")):
                groups[group].append(row)
            for group, lines in groups.items():
                for key, anchor in contexts(group, lines):
                    catalog[key].add(anchor)
    print("# Generated by scripts/maintainer/generate-template-residue.py; do not edit.")
    print("# Fields: template, token, then one or more (surface, selector, left ERE, right ERE) tuples.")
    for (group, token), anchors in sorted(catalog.items()):
        fields = [field for anchor in sorted(anchors) for field in anchor]
        # Keep a significant final regex space without trailing TSV whitespace.
        if fields[-1].endswith(" "):
            fields[-1] = fields[-1][:-1] + "[ ]"
        print("\t".join((group, token, *fields)))


if __name__ == "__main__":
    main()
