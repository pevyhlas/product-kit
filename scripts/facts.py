"""Collect exact-head review evidence without making a gate decision."""

import argparse
from datetime import UTC, datetime
from difflib import unified_diff
import fcntl
from fnmatch import fnmatchcase
from hashlib import file_digest, sha256
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import stat
import subprocess
import sys
from tempfile import NamedTemporaryFile


VERSION = 1
SUMMARY_LIMIT = 60
CONFIG = ".prdkit/memory/review-checks.json"
CACHE = ".prdkit/cache/evidence"
SCRIPTS = ".prdkit/scripts/bash"
FILES = ("index.json", "summary.md")
DIFF = ("git", "diff", "--no-ext-diff", "--no-textconv", "--ignore-submodules=none",
        "--no-relative", "--no-color")


class Refusal(Exception):
    pass


def require(condition, reason):
    if not condition:
        raise Refusal(reason)


def digest(data):
    return sha256(data).hexdigest()


def json_bytes(value):
    return (json.dumps(value, sort_keys=True, indent=2, allow_nan=False) + "\n").encode("ascii")


def unique_object(pairs):
    obj = {}
    for key, value in pairs:
        require(key not in obj, f"duplicate JSON key: {key!r}")
        obj[key] = value
    return obj


def one_line(text, limit=220):
    text = " ".join(text.split())
    text = "".join(c if c.isprintable() else ascii(c)[1:-1] for c in text)
    return text if len(text) <= limit else text[:limit - 1] + "…"


def mode(path):
    try:
        return path.lstat().st_mode
    except (FileNotFoundError, NotADirectoryError):
        return 0


def file_stamp(path):
    kind = mode(path)
    if not kind:
        return {"kind": "absent"}
    link = stat.S_ISLNK(kind)
    result = {"kind": "symlink", "link_sha256": digest(os.fsencode(os.readlink(path)))} if link else {"kind": "file"}
    if link:
        try:
            kind = path.stat().st_mode
        except (FileNotFoundError, NotADirectoryError):
            return result
    if stat.S_ISREG(kind):
        with path.open("rb") as stream:
            result["sha256"] = file_digest(stream, "sha256").hexdigest()
        result["executable"] = bool(kind & 0o111)
    else:
        result["target_kind" if link else "kind"] = "directory" if stat.S_ISDIR(kind) else "special"
    return result


def glob_matches(pattern, path):
    # Match slash-separated components. Only an entire ** component crosses directories.
    names = path.split("/")
    positions = {0}
    for part in pattern.split("/"):
        if not positions:
            return False
        if part == "**":
            positions = set(range(min(positions), len(names) + 1))
        else:
            positions = {i + 1 for i in positions if i < len(names) and fnmatchcase(names[i], part)}
    return len(names) in positions


def load_map(root):
    path = root / CONFIG
    if not mode(path):
        return None, {"kind": "absent"}
    require(stat.S_ISREG(mode(path)), f"{CONFIG}: expected a regular JSON file")
    raw = path.read_bytes()
    try:
        rules = json.loads(raw.decode("utf-8"), object_pairs_hook=unique_object)
        require(isinstance(rules, dict), "expected an object mapping globs to check names")
        for pattern, checks in rules.items():
            require(pattern.isprintable() and "\\" not in pattern and all(
                part not in {"", ".", ".."} and ("**" not in part or part == "**")
                for part in pattern.split("/")), f"invalid repository-relative glob {pattern!r}")
            require(isinstance(checks, list) and checks and all(
                isinstance(name, str) and name.strip() and name.isprintable() for name in checks
            ) and len(set(checks)) == len(checks), f"{pattern!r}: expected distinct nonempty check names")
        return {key: sorted(rules[key]) for key in sorted(rules)}, {"kind": "file", "sha256": digest(raw)}
    except (ValueError, Refusal, RecursionError) as exc:
        raise Refusal(f"{CONFIG}: {exc}") from exc


class Collector:
    def __init__(self):
        self.scripts = Path(__file__).parent.resolve()
        self.env = dict(os.environ)
        for name in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR",
                     "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_NAMESPACE",
                     "GIT_GRAFT_FILE", "GIT_SHALLOW_FILE", "GIT_PREFIX", "GIT_CONFIG",
                     "GIT_QUARANTINE_PATH", "BASH_ENV", "ENV"):
            self.env.pop(name, None)
        self.env.update(GIT_NO_LAZY_FETCH="1", GIT_NO_REPLACE_OBJECTS="1", GIT_OPTIONAL_LOCKS="0",
                        GIT_ATTR_NOSYSTEM="1",
                        GIT_ALLOW_PROTOCOL="", GIT_TERMINAL_PROMPT="0", LC_ALL="C", TZ="UTC",
                        PRDKIT_TODAY=self.env.get("PRDKIT_TODAY") or datetime.now(UTC).date().isoformat())
        self.root = self.scripts
        self.root = Path(os.fsdecode(self.git("rev-parse", "--show-toplevel").removesuffix(b"\n"))).resolve()
        require(self.scripts == self.root / SCRIPTS,
                "run the installed copy under the consumer Git root: .prdkit/scripts/bash/facts.sh")

    def run(self, command):
        return subprocess.run(command, cwd=self.root, env=self.env, stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)

    def git(self, *args, allowed=(0,)):
        proc = self.run(("git", *args))
        require(proc.returncode in allowed, f"git {shlex.join(args)}: {one_line(self.text(proc.stderr)) or 'failed'}")
        return proc.stdout

    def rev(self, ref):
        return self.git("rev-parse", "--verify", "--end-of-options", f"{ref}^{{commit}}").decode().strip()

    def clean(self, head):
        require(self.rev("HEAD") == head, "checkout HEAD moved or does not match --head")
        require(not self.git("-c", "core.fsmonitor=false", "status", "--porcelain=v1", "-z",
                             "--untracked-files=all", "--ignore-submodules=none"),
                "exact-head facts require a clean checkout (including non-ignored untracked files and submodules)")

    def text(self, raw):
        # The collector root is stable context, not a useful machine-specific diagnostic prefix.
        return raw.decode("utf-8", "backslashreplace").replace(f"{self.root}/", "").rstrip("\n")

    def stamp(self):
        """Bind committed state and actual working inputs, including ignored kit policy and links."""
        tracked = self.git("ls-files", "-v", "-z").split(b"\0")[:-1]
        require(not any(entry[:1].islower() or entry.startswith(b"S ") for entry in tracked),
                "exact-head facts cannot inspect skip-worktree or assume-unchanged entries")
        files = {}

        def add(path, label):
            if label not in files:
                files[label] = file_stamp(path)

        def scan(path, label, *, skip=(), ancestors=()):
            add(path, label)
            if path.is_dir() and path.resolve() not in ancestors:
                trail = (*ancestors, path.resolve())
                for child in sorted(path.iterdir()):
                    if child.name not in skip:
                        scan(child, f"{label}/{child.name}", skip=skip, ancestors=trail)

        # Committed objects (including non-doc code and assets) are bound by the
        # trees. Doctor also directly reads tracked Markdown and can follow links.
        for entry in tracked:
            name = os.fsdecode(entry[2:])
            if name.endswith((".md", ".gitattributes", ".gitignore")):
                add(self.root / name, name)
        for name in ("specs", ".prdkit", ".claude/commands", ".claude/agents",
                     ".opencode/commands", ".opencode/agents", ".agents/skills"):
            scan(self.root / name, name, skip=(".git", "cache") if name == ".prdkit" else (".git",))
        for name in ("AGENTS.md", "CLAUDE.md", "GEMINI.md", "QWEN.md", "CODEBUDDY.md", "QODER.md", "SHAI.md"):
            add(self.root / name, name)

        # These existing readers can select live files outside the usual Kit
        # directories. Parse their policy the same way as the collectors.
        selected = self.run(("bash", "-c", r'''
            source "$1/install-source-lib.sh"
            source "$1/install-lib.sh"
            source "$1/spec-lib.sh"
            source "$1/agent-tiers-lib.sh"
            config=.prdkit/memory/config.md
            source_path=
            if [ -f "$config" ]; then
                source_path="$(install_config_value "$config" adoption-source)" || source_path=
            fi
            printf '%s\0' "$source_path"
            at_load "$PWD" "$SPEC_SKIP_AWK" && printf '%s\0' "$AT_SNAPSHOT"
        ''', "_", str(self.scripts)))
        source, _, remaining = selected.stdout.partition(b"\0")
        name = os.fsdecode(source)
        name = name or ".product-kit"
        if not name.startswith("/") and ".." not in name:
            add(self.root / name / "VERSION", f"{name}/VERSION")
            commands = self.root / name / "commands"
            add(commands, f"{name}/commands")
            if commands.is_dir():
                for path in sorted(commands.glob("*.md")):
                    add(path, f"{name}/commands/{path.name}")
        if selected.returncode == 0 and remaining.rstrip(b"\0"):
            snapshot = Path(os.fsdecode(remaining[:-1]))
            if snapshot.is_relative_to(self.root):
                for path in (snapshot, snapshot.with_suffix(snapshot.suffix + ".ref")):
                    add(path, path.relative_to(self.root).as_posix())

        config = self.git("config", "--null", "--list", "--includes")
        config_home = Path(self.env.get("XDG_CONFIG_HOME") or Path.home() / ".config")
        for key, default in (("attributesfile", "attributes"), ("excludesfile", "ignore")):
            override = self.git("config", "--path", "--null", "--get", f"core.{key}", allowed=(0, 1))
            path = Path(os.fsdecode(override[:-1])) if override else config_home / "git" / default
            add(self.root / path, f"git:user/{default}")
        for label in ("info/attributes", "info/exclude", "info/grafts", "shallow"):
            path = Path(os.fsdecode(self.git("rev-parse", "--git-path", label).removesuffix(b"\n")))
            add(self.root / path, f"git:{label}")
        worktrees = self.git("worktree", "list", "--porcelain", "-z")
        rows = worktrees.split(b"\0")
        for i, row in enumerate(rows):
            if not row.startswith(b"worktree "):
                continue
            other = Path(os.fsdecode(row[9:]))
            if other == self.root:
                rows[i] = b"worktree ."  # CI's checkout prefix need not be the producer's.
            else:
                scan(other / "specs/changes", f"worktree:{i}/specs/changes", skip=(".git",))

        return {"files": files, "git_config_sha256": digest(config),
                "git_refs_sha256": digest(self.git("for-each-ref", "--format=%(refname) %(objectname) %(symref)")),
                "git_index_sha256": digest(self.git("ls-files", "--stage", "-z")),
                "worktrees_sha256": digest(b"\0".join(rows)), "git_version_sha256": digest(self.git("--version")),
                "head_ref_sha256": digest(self.git("symbolic-ref", "-q", "HEAD", allowed=(0, 1))),
                "doctor_date_sha256": digest(self.env["PRDKIT_TODAY"].encode())}

    def fact(self, command):
        try:
            proc = self.run(command)
        except OSError as exc:
            return {"command": command, "exit_status": None, "result": f"could not start: {exc.strerror}",
                    "details": None}
        return {"command": command, "exit_status": proc.returncode, "result": f"exit {proc.returncode}",
                "details": self.text(proc.stdout), "stderr": self.text(proc.stderr)}

    def script(self, name, *args):
        return self.fact(["bash", f"{SCRIPTS}/{name}.sh", *args])


def local_json(fact, *, doctor):
    try:
        data = json.loads(fact["details"], object_pairs_hook=unique_object)
        result = data["result"]
        findings = data["findings"]
        advisories = data["advisories"] if doctor else []
        require((result, fact["exit_status"]) in {("pass", 0), ("fail", 1)} and
                all(isinstance(rows, list) and all(isinstance(line, str) for line in rows)
                    for rows in (findings, advisories)) and bool(findings) == (result == "fail"),
                "inconsistent collector result")
        # Check that the full payload is safe to serialize, not just the fields summarized.
        json_bytes(data)
        fact["details"] = data
        fact["result"] = f"{result}: {len(findings)} finding(s)"
        fact["result"] += f", {len(advisories)} advisory item(s)" if doctor else " (default installation checks)"
    except (ValueError, TypeError, AttributeError, KeyError, Refusal, RecursionError):
        fact["result"] += ": no valid collector report"
    return fact


def ci_fact(collector, pr, head):
    command = ["bash", f"{SCRIPTS}/pr-state.sh", *([str(pr)] if pr else [])]
    if not pr or not shutil.which("gh", path=collector.env.get("PATH")):
        reason = "no --pr supplied" if not pr else "gh not available on PATH"
        return {"command": command, "exit_status": None, "result": f"not collected: {reason}", "details": None}
    fact = collector.fact(command)
    raw = fact.pop("details")
    fact["details"] = None
    if fact["exit_status"] != 0:
        reason = one_line(fact.get("stderr", "")) or fact["result"]
    else:
        try:
            data = json.loads(raw, object_pairs_hook=unique_object)
            observed = data["head_sha"]
            require(observed == head, f"PR head {observed!r} does not match the checkout head")
            require(data["number"] == pr, "PR number differs")
            require(isinstance(data["required_checks"], list), "missing required check inventory")
            checks = [{key: check[key] for key in ("name", "status", "conclusion", "link")}
                      for check in data["required_checks"]]
            require(all(isinstance(check[key], str) for check in checks for key in ("name", "status")) and
                    all(check[key] is None or isinstance(check[key], str)
                        for check in checks for key in ("conclusion", "link")), "invalid required check")
            checks.sort(key=lambda check: check["name"])
            require(len({check["name"] for check in checks}) == len(checks), "duplicate required check")
            # Keep only the binding and required-check inventory, not fetched_at or reviews.
            observed = {key: data[key] for key in ("repo", "number", "head_sha", "base_ref", "base_sha")}
            observed["required_checks"] = checks
            json_bytes(observed)
            fact["details"] = observed
            green = sum(check["status"] == "COMPLETED" and check["conclusion"] == "SUCCESS" for check in checks)
            fact["result"] = (f"{green}/{len(checks)} required check(s) green" if checks
                              else "no required checks reported")
            return fact
        except (ValueError, TypeError, KeyError, Refusal, RecursionError) as exc:
            reason = f"unusable pr-state report ({one_line(str(exc))})"
    fact["result"] = f"not collected: {reason}"
    return fact


def map_paths(collector, span, rules, ci):
    command = [*DIFF, "--name-only", "-z", "--no-renames", span, "--"]
    proc = collector.run(command)
    paths = []
    complete = proc.returncode == 0 and (not proc.stdout or proc.stdout.endswith(b"\0"))
    if complete:
        paths = sorted(set(os.fsdecode(name) for name in proc.stdout.split(b"\0")[:-1]))
    mapped = {}
    reported = {check["name"]: check for check in (ci["details"] or {}).get("required_checks", [])}
    for path in paths:
        names = sorted({name for pattern, checks in (rules or {}).items()
                        if glob_matches(pattern, path) for name in checks})
        mapped[path] = [{"name": name, "state": ("reported" if name in reported else
                         "not reported as required" if ci["details"] is not None else "not collected"),
                         "status": reported.get(name, {}).get("status"),
                         "conclusion": reported.get(name, {}).get("conclusion")} for name in names]
    configuration = "absent" if rules is None else "present"
    result = (f"configuration {configuration}; {sum(map(bool, mapped.values()))}/{len(paths)} changed paths matched"
              if complete else f"configuration {configuration}; changed paths not collected")
    return {"command": command, "exit_status": proc.returncode, "result": result,
            "stderr": collector.text(proc.stderr), "config": CONFIG, "rules": rules, "paths": mapped}


def summary(pack, index):
    key, facts = pack["key"], pack["facts"]
    lines = [
        f"# Review facts: {pack['change_id']}", "",
        f"Authoritative evidence for base `{key['base']}` and head `{key['head']}` only.",
        "Answers: What did doctor and adoption report? Is the range free of `git diff --check` findings?",
        "Which bounds apply to the diff? Which checks does the path map require, and are required CI checks green at this head?",
        "Use these captured facts; do not rerun the collectors or reread the spec to derive these answers.",
        "Does not answer design fit, correctness, or spec fit, including whether the diff respects the listed bounds. Those are the reviewer's job.",
        "Evidence only — not a gate decision, approval, or merge authorization.", "",
        f"Key: facts v{key['version']} · `{key['base']}..{key['head']}`.",
        f"Full facts and input stamps: [index.json](index.json) (SHA-256 `{digest(index)}`).", "",
    ]
    labels = {"doctor": "Doctor", "bounds": "Bounds", "diff_check": "Diff whitespace",
              "adoption": "Adoption", "ci": "Exact-head CI", "path_checks": "Path → required checks"}
    for name, label in labels.items():
        lines.append(f"- **{label}:** {one_line(facts[name]['result'])}")

    detail = []
    for name in ("bounds", "ci", "path_checks", "doctor", "diff_check", "adoption"):
        label = labels[name]
        fact = facts[name]
        data = fact.get("details")
        if name in {"doctor", "adoption"} and isinstance(data, dict):
            rows = data["findings"] + [f"Advisory: {line}" for line in data.get("advisories", [])]
        elif name == "ci" and data:
            rows = [f"{row['name']}: {row['conclusion'] or row['status']}" for row in data["required_checks"]]
        elif name == "path_checks":
            rows = [f"{path} → " + ", ".join(f"{row['name']}: {row['conclusion'] or row['status'] or row['state']}"
                                            for row in checks)
                    for path, checks in fact["paths"].items() if checks]
        else:
            rows = data.splitlines() if isinstance(data, str) else []
        rows.extend(f"Diagnostic: {line}" for line in fact.get("stderr", "").splitlines())
        detail.extend(f"    {label}: {one_line(line)}" for line in rows if line.strip())
    if detail:
        lines.extend(("", "## Captured details", ""))
        room = SUMMARY_LIMIT - len(lines)
        if len(detail) > room:
            shown = room - 2
            lines.extend(detail[:shown])
            lines.extend(("", f"{len(detail) - shown} more detail line(s): see [index.json](index.json)."))
        else:
            lines.extend(detail)
    # Every short rendering has a full indexed counterpart; clipping per line is explicit.
    text = "\n".join(lines) + "\n"
    require(len(text.splitlines()) <= SUMMARY_LIMIT, "internal error: summary exceeded line limit")
    return text.encode("utf-8")


def cache_dir(collector, change_id, verify):
    directory = collector.root
    rel = Path(CACHE) / change_id / "facts"
    for part in rel.parts:
        directory /= part
        if not mode(directory):
            if verify:
                return None
            directory.mkdir(exist_ok=True)
        require(stat.S_ISDIR(mode(directory)), f"unsafe cache directory: {directory.relative_to(collector.root)}")
    return directory


def compare(directory, new, pack):
    changed = [name for name in FILES if directory is None or not mode(directory / name)
               or (directory / name).read_bytes() != new[name]]
    if not changed:
        return 0
    print("facts drift: " + ", ".join(changed))
    if "index.json" in changed and directory is not None and mode(directory / "index.json"):
        try:
            old = json.loads((directory / "index.json").read_bytes())
            for name in ("key", "change_id", "inputs"):
                if old.get(name) != pack[name]:
                    if name == "key":
                        print(f"- key: {one_line(str(old.get(name)))}\n+ key: {one_line(str(pack[name]))}")
                    else:
                        print(f"  {name} changed")
            for name, fact in pack["facts"].items():
                prior = old.get("facts", {}).get(name, {})
                if prior == fact:
                    continue
                print(f"- {name}: {one_line(str(prior.get('result', '(missing)')))}")
                print(f"+ {name}: {one_line(fact['result'])}")
                if prior.get("result") == fact["result"]:
                    before = json_bytes(prior).decode().splitlines()
                    after = json_bytes(fact).decode().splitlines()
                    diff = unified_diff(before, after, n=0)
                    next(diff, None)  # file labels would repeat index.json
                    next(diff, None)
                    edits = [line for line in diff if line.startswith(("-", "+"))]
                    for line in edits[:4]:
                        print(f"  {one_line(line)}")
                    if len(edits) > 4:
                        print("  … more fact details differ")
        except (ValueError, AttributeError, RecursionError):
            print("  stored index is not a readable facts index")
    return 1


def write_pack(directory, output):
    staged = {}
    try:
        for name, data in output.items():
            with NamedTemporaryFile(dir=directory, prefix=".facts-", delete=False) as tmp:
                staged[name] = Path(tmp.name)
                tmp.write(data)
                tmp.flush()
                os.fsync(tmp.fileno())
        for name in FILES:
            staged[name].replace(directory / name)
    finally:
        for path in staged.values():
            path.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(
        prog="facts.sh", allow_abbrev=False, description="Exact-head review facts; never a gate decision.",
        formatter_class=argparse.RawDescriptionHelpFormatter, epilog=(
            f"Output: {CACHE}/<change-id>/facts/{{summary.md,index.json}}\n"
            "Attach both files (id, base and head must match the pack):\n"
            '  bash .prdkit/scripts/bash/build-review-package.sh "$id" "$base" "$head" '
            f'--evidence "{CACHE}/$id/facts/summary.md" --evidence "{CACHE}/$id/facts/index.json"\n'
            "Exit: 0 pack written or verified, 1 verification drift, 2 refusal."))
    parser.add_argument("change_id")
    parser.add_argument("--base", metavar="REV", help="base commit (default: unique merge base with origin/HEAD)")
    parser.add_argument("--head", metavar="REV", help="require checkout HEAD to resolve to REV (default: HEAD)")
    parser.add_argument("--pr", metavar="N", help="collect required checks via pr-state.sh using gh")
    parser.add_argument("--verify", action="store_true", help="recompute and compare; do not write")
    args = parser.parse_args()
    try:
        require(re.fullmatch(r"[0-9]{3,}-[a-z0-9]+(?:-[a-z0-9]+)*", args.change_id), "invalid change id")
        require(args.pr is None or re.fullmatch(r"[1-9][0-9]{0,8}", args.pr), "--pr expects a positive PR number")
        collector = Collector()
        head = collector.rev("HEAD")
        if args.head is not None:
            require(collector.rev(args.head) == head, "checkout HEAD does not match --head")
        collector.clean(head)
        record = f"specs/changes/{args.change_id}.md"
        require(collector.git("ls-tree", head, "--", record).startswith((b"100644 ", b"100755 ")),
                f"unknown change id at HEAD: {record}")
        if args.base is None:
            try:
                tip = collector.rev("refs/remotes/origin/HEAD")
            except Refusal as exc:
                raise Refusal("no local origin/HEAD; pass --base with the review range's base commit") from exc
            bases = collector.git("merge-base", "--all", tip, head, allowed=(0, 1)).decode().splitlines()
            require(len(bases) == 1, "no unique merge base with origin/HEAD; pass --base")
            base = bases[0]
        else:
            base = collector.rev(args.base)
            require(collector.run(("git", "merge-base", "--is-ancestor", base, head)).returncode == 0,
                    "--base must be an ancestor of HEAD")
        for name in FILES:
            require(collector.run(("git", "check-ignore", "-q", "--",
                                   f"{CACHE}/{args.change_id}/facts/{name}")).returncode == 0,
                    "facts cache must be gitignored and not tracked")

        inputs = collector.stamp()
        rules, config_stamp = load_map(collector.root)
        config_before = inputs["files"].get(CONFIG, {"kind": "absent"})
        require(all(config_before.get(key) == value for key, value in config_stamp.items()),
                f"{CONFIG} changed while reading it")
        span = f"{base}..{head}"
        facts = {}
        facts["doctor"] = local_json(collector.script("doctor", "--json"), doctor=True)
        bounds = collector.script("bounds", args.change_id)
        if (bounds["exit_status"] == 0 and bounds["details"].startswith(f"Bounds for {args.change_id} ") and
                bounds["details"].splitlines()[-1].startswith("Mark each in the record's Bounds:")):
            bounds["result"] = "applicable bounds listed below and in index.json"
        else:
            bounds["result"] = f"bounds not collected ({bounds['result']})"
        facts["bounds"] = bounds
        diff = collector.fact([*DIFF, "--check", span, "--"])
        diff["result"] = {0: "clean", 2: "whitespace or conflict-marker findings"}.get(
            diff["exit_status"], f"diff check failed ({diff['result']})")
        facts["diff_check"] = diff
        facts["adoption"] = local_json(collector.script("check-adoption", "--json"), doctor=False)
        facts["ci"] = ci_fact(collector, int(args.pr) if args.pr else None, head)
        facts["path_checks"] = map_paths(collector, span, rules, facts["ci"])

        pack = {"change_id": args.change_id, "key": {"version": VERSION, "base": base, "head": head},
                "inputs": {**inputs, "base_tree": collector.git("rev-parse", f"{base}^{{tree}}").decode().strip(),
                           "head_tree": collector.git("rev-parse", f"{head}^{{tree}}").decode().strip(),
                           "config": config_stamp, "ci_sha256": digest(json_bytes(facts["ci"]))}, "facts": facts}
        index = json_bytes(pack)
        output = {"index.json": index, "summary.md": summary(pack, index)}
        directory = cache_dir(collector, args.change_id, args.verify)
        if directory is None:
            require(collector.stamp() == inputs, "local inputs changed while collecting facts; retry")
            collector.clean(head)
            return compare(None, output, pack)
        fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            fcntl.flock(fd, fcntl.LOCK_SH if args.verify else fcntl.LOCK_EX)
            require(collector.stamp() == inputs, "local inputs changed while collecting facts; retry")
            collector.clean(head)
            for name in FILES:
                kind = mode(directory / name)
                require(not kind or stat.S_ISREG(kind), f"unsafe facts file: {name}")
            if args.verify:
                return compare(directory, output, pack)
            write_pack(directory, output)
        finally:
            os.close(fd)
        print(directory.relative_to(collector.root))
        return 0
    except (Refusal, OSError, ValueError) as exc:
        print(f"facts.sh: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
