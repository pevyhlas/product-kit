"""Seeded black-box fixtures. Invoke via tests/lib/states.sh (Python 3.11+, -I)."""

from dataclasses import dataclass
import hashlib
import os
from pathlib import Path
import random
import secrets
import shutil
import stat
import subprocess
import sys
import tempfile


# Each row guarantees a distinct layout even on a short CI run. Extra states
# sample the same structural constraints with independent worktree contents.
CLEANUP = (
    "old-git", "absorbed", "absorbed remote-ref", "absorbed stale",
    "absorbed stale unrelated", "embedded force", "linked force",
    "absorbed ignored", "locked force", "dirty untracked intent staged force",
    "intent", "spool-link force", "detached", "untracked", "detached closed",
    "reflog-only",
)
CLOSE = ("", "inside", "escaping", "nested", "staged", "dirty untracked", "staged detached")
ID = "701-generated"
SUB = "vendor/sub"
KIT = Path(".prdkit/scripts/bash")


def plan(lane):
    extra = int(os.environ.get("PRDKIT_EXTRA_STATES", 0))
    if not 0 <= extra <= 200:
        raise ValueError("PRDKIT_EXTRA_STATES must be 0..200 per suite")
    seed = int(os.environ.get("PRDKIT_STATE_SEED", secrets.randbits(48) if extra else 701))
    rng = random.Random(seed)
    rows = CLEANUP if lane == "cleanup" else CLOSE
    for n, row in enumerate([*rows, *rng.choices(rows, k=extra)]):
        features = row.split()
        if n >= len(rows) and not {"stale", "closed"}.intersection(features):
            modifiers = ("intent", "force", "locked", "old-git") if lane == "cleanup" else ("staged",)
            for feature in ("dirty", "untracked", *modifiers):
                if rng.randrange(2) and feature not in features:
                    features.append(feature)
        # Guarantee both encodings/paths, including in the baseline corpus.
        features += [f for i, f in enumerate(("space", "unicode", "crlf", "unterminated"))
                     if n == i or rng.randrange(2)]
        print(seed, n, *features)


def git(cwd, *args):
    return subprocess.run(["git", "-C", cwd, *args], stdout=subprocess.PIPE, check=True).stdout


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def tree(root, skip=()):
    """Compare bytes, links, modes and empty directories without following links."""
    result = {}

    def walk(parent):
        for p in parent.iterdir():
            key = p.relative_to(root).as_posix()
            if key in skip:
                continue
            mode = p.lstat().st_mode
            value = None
            if stat.S_ISLNK(mode):
                value = os.readlink(p)
            elif stat.S_ISDIR(mode):
                walk(p)
            else:
                value = hashlib.sha256(p.read_bytes()).digest()
            result[key] = (mode, value)
    if root.is_dir():
        walk(root)
    return result


def same(before, after, label):
    changed = [p for p in before.keys() | after.keys() if before.get(p) != after.get(p)]
    require(not changed, f"{label} changed: {sorted(changed)[:10]}")


def invoke(repo, script, *args, env=None):
    result = subprocess.run(["bash", repo / KIT / script, *args], cwd=repo,
                            capture_output=True, text=True, env=env)
    require(result.returncode in (0, 1), f"unexpected exit {result.returncode}: {result.stderr}")
    return result.returncode, result.stdout + result.stderr


def sample(features, token):
    name = ("some " if "space" in features else "") + ("λ" if "unicode" in features else "x")
    eol = b"\r\n" if "crlf" in features else b"\n"
    return name, token.encode() + eol + b"last" + (b"" if "unterminated" in features else eol)


def contents(work, tracked, features, token):
    name, payload = sample(features, token)
    saved = {}
    for f in ("untracked", "dirty", "intent", "staged"):
        if f not in features:
            continue
        path = tracked if f == "dirty" else f"{name}-{f}"
        (work / path).write_bytes(payload)
        if f == "intent":
            git(work, "add", "-N", "--", path)
        if f == "staged":
            git(work, "add", "--", path)
            (work / path).write_bytes(b"edited again\n")
        saved[path] = (work / path).read_bytes()
    return saved


def module(work, src, linked, features):
    mod = work / SUB
    if "embedded" in features:
        git(work, "clone", "-q", "--no-local", src, mod)
    else:
        git(work, "-c", "protocol.file.allow=always", "submodule", "update", "-q", "--init")
    if "ignored" in features:
        git(work, "config", f"submodule.{SUB}.ignore", "all")
    if "linked" in features:
        git(mod, "worktree", "add", "-q", "--detach", linked)
        mod = linked
    git(mod, "commit", "-qm", "only local copy", "--allow-empty")
    tip = git(mod, "rev-parse", "HEAD").strip().decode()
    if "remote-ref" in features:
        git(mod, "update-ref", "refs/remotes/origin/old", tip)
    git(work, "add", "-f", "--", SUB, ".gitmodules")
    git(work, "commit", "--allow-empty", "-qm", "record pin")
    if "linked" not in features:
        require(git(work, "rev-parse", f"HEAD:{SUB}").strip().decode() == tip,
                "fixture did not record the new module pin")
    return tip


@dataclass
class Checkout:
    repo: Path
    work: Path
    admin: Path
    target: Path
    args: list
    head: bytes
    reflog_tip: bytes | None
    module_tip: str | None
    files: dict


def build_cleanup(root, scripts, features, token):
    repo, linked, src = root / "repo", root / "linked", root / "upstream"
    repo.mkdir()
    git(repo, "init", "-q")
    name, original = sample(features, "original")
    tracked = f"{name}-tracked"
    (repo / tracked).write_bytes(original)
    (repo / ".gitignore").write_text(f"/{KIT}/\n.prdkit/ledger/\n.worktrees/\n")
    has_module = features & {"absorbed", "embedded", "linked"}
    if has_module:
        src.mkdir()
        git(src, "init", "-q")
        git(src, "commit", "--allow-empty", "-qm", "upstream")
        git(repo, "-c", "protocol.file.allow=always", "submodule", "add", "-q", src, SUB)
        git(repo, "config", "-f", ".gitmodules", f"submodule.{SUB}.url", "../upstream")
    git(repo, "add", ".")
    git(repo, "commit", "-qm", "base")
    shutil.copytree(scripts, repo / KIT)
    work = repo / ".worktrees" / ID
    branch = ["--detach"] if "detached" in features else ["-b", ID]
    git(repo, "worktree", "add", "-q", *branch, work)
    tip = None
    if has_module:
        tip = module(work, src, linked, features)
    git(work, "commit", "--allow-empty", "-qm", token)
    head = git(work, "rev-parse", "HEAD").strip()
    reflog_tip = None
    if "reflog-only" in features:
        git(work, "checkout", "-q", "--detach")
        git(work, "commit", "-qm", f"private reflog {token}", "--allow-empty")
        reflog_tip = git(work, "rev-parse", "HEAD").strip()
        git(work, "checkout", "-q", head.decode() if "detached" in features else ID)
        require(git(work, "rev-parse", "HEAD@{1}").strip() == reflog_tip and
                reflog_tip not in git(repo, "rev-list", "--all").splitlines(),
                "fixture commit must be reachable only from the private HEAD reflog")
    admin = Path(git(work, "rev-parse", "--absolute-git-dir").decode().strip())
    saved = contents(work, tracked, features, token)
    if "locked" in features:
        git(repo, "worktree", "lock", work)
    if "spool-link" in features:
        spool = work / ".prdkit/ledger/events.jsonl"
        spool.parent.mkdir(parents=True)
        (root / "sample").write_text("fixture line\n")
        spool.symlink_to(root / "sample")
    if "stale" in features:
        shutil.rmtree(work)
    target = work
    args = (["--force"] if "force" in features else []) + [ID]
    if features & {"unrelated", "closed"}:
        target = work.with_name("702-other")
        git(repo, "worktree", "add", "-qb", target.name, target)
        args = [target.name]
        if "closed" in features:
            log = repo / ".prdkit/history/log.md"
            log.parent.mkdir(parents=True)
            log.write_text(f"- 2026-01-01 {ID}: closed\n- 2026-01-01 {target.name}: closed\n")
            git(repo, "add", str(log.relative_to(repo)))
            git(repo, "commit", "-qm", "close changes")
            git(repo, "update-ref", "refs/remotes/origin/main", "HEAD")
            git(repo, "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main")
            args = ["--closed"]
    elif "stale" in features:
        args = ["--prune"]
    return Checkout(repo, work, admin, target, args, head, reflog_tip, tip, saved)


def cleanup(root, scripts, features, token):
    state = build_cleanup(root, scripts, features, token)
    repo, work, admin = state.repo, state.work, state.admin
    env = os.environ.copy()
    if "old-git" in features:
        shim = root / "git"
        shim.write_text('#!/bin/sh\ncase " $* " in *" worktree list --porcelain -z "*) '
                        'exit 129;; esac\nexec "$REAL_GIT" "$@"\n')
        shim.chmod(0o755)
        env.update(REAL_GIT=shutil.which("git"), PATH=f"{root}:{env['PATH']}")

    main_tree = tree(repo, (".git", ".worktrees"))
    before = tree(work)
    index = (admin / "index").read_bytes()
    staged_path = sample(features, token)[0] + "-staged"
    staged = git(work, "rev-parse", ":" + staged_path).strip().decode() if "staged" in features else None
    head_file = (admin / "HEAD").read_bytes()
    registrations = git(repo, "worktree", "list", "--porcelain")
    rc, output = invoke(repo, "cleanup-change.sh", *state.args, env=env)
    after = git(repo, "worktree", "list", "--porcelain")
    if rc:
        require(after == registrations, "refusal changed registrations")
        require((admin / "index").read_bytes() == index, "refusal changed index")
        require((admin / "HEAD").read_bytes() == head_file, "refusal changed HEAD")
        same(before, tree(work), "refused checkout")
        same(main_tree, tree(repo, (".git", ".worktrees")), "main checkout")
    else:
        require(not state.target.exists() and os.fsencode(state.target) not in after,
                "successful cleanup left the change registered")
    # Verify recoverability before checking the expected outcome: a historical
    # failure should identify lost work, not just a different retirement policy.
    slots = list((repo / ".git/prdkit-retired").glob(ID + ".*"))
    surviving = slots[0] / "checkout" if slots else work
    for path, data in state.files.items():
        require((surviving / path).is_file() and (surviving / path).read_bytes() == data,
                f"lost working bytes: {path}")
    if "unrelated" in features:
        require(admin.is_dir() and os.fsencode(work) in after,
                "cleanup pruned an unrelated stale registration and its only module store")
    if "closed" in features:
        require(os.fsencode(work) in after, "sweep retired a nonmatching detached checkout")
        same(before, tree(work), "detached checkout")
    tip = state.module_tip
    if tip:
        if "linked" in features:
            require(git(root / "linked", "rev-parse", "--verify", "HEAD^{commit}").strip().decode() == tip,
                    "linked checkout lost its detached HEAD")
        else:
            store = (surviving / SUB / ".git" if "embedded" in features else
                     (slots[0] / "admin" if slots else admin) / "modules" / SUB)
            require(store.is_dir(), f"only store for unpushed module commit {tip} disappeared")
            git(repo, f"--git-dir={store}", "--work-tree=.", "cat-file", "-e", tip + "^{commit}")
    # After a refusal (or an unrelated retirement), don't destroy the live
    # private reflog in the test itself. A retired checkout gets full expiry.
    if state.reflog_tip and admin.is_dir():
        # The generator uses a fixed, old commit date; even default GC expires
        # a live log's unreachable entries when they are over 30 days old.
        git(repo, "-c", "gc.reflogExpire=never", "-c", "gc.reflogExpireUnreachable=never",
            "gc", "--prune=now", "-q")
    else:
        git(repo, "reflog", "expire", "--expire=now", "--all")
        git(repo, "gc", "--prune=now", "-q")
    git(repo, "cat-file", "-e", state.head.decode() + "^{commit}")
    if state.reflog_tip:
        git(repo, "cat-file", "-e", state.reflog_tip.decode() + "^{commit}")
        retained_admin = slots[0] / "admin" if slots else admin
        log = git(repo, f"--git-dir={retained_admin}", "--work-tree=.",
                  "reflog", "show", "--format=%H", "HEAD")
        require(state.reflog_tip in log.splitlines(), "lost private HEAD reflog entry")
    if staged:
        archived = slots[0] / "admin" if slots else admin
        require((archived / "index").read_bytes() == index, "lost or replaced staged index")
        require(git(repo, "cat-file", "blob", staged) == sample(features, token)[1],
                "lost staged-only bytes")
    if rc:
        require(git(repo, f"--git-dir={admin}", "rev-parse", "HEAD").strip() == state.head,
                "refusal moved the branch")
    refuse = bool(features & {"locked", "embedded", "linked", "spool-link"} or
                  (state.files and "force" not in features))
    # A release may safely refuse a unique module store rather than archive it.
    # Ordinary clean/forced controls still have to succeed.
    if rc and tip and not refuse and "unrelated" not in features:
        return
    require(rc == int(refuse), f"expected exit {int(refuse)}, got {rc}: {output}")


def build_close(root, template, features, token):
    # A reviewed change and its exact-head host fixture come from the Bash suite.
    repo = root / "repo"
    shutil.copytree(template, repo, symlinks=True)
    change = git(repo, "branch", "--show-current").decode().strip()
    if "detached" in features:
        git(repo, "checkout", "-q", "--detach")
    # Keep an unrelated change beside the open record so Git retains the directory.
    (repo / "specs/changes/702-other.md").write_text("# other\n")
    outside = root / "elsewhere"
    outside.mkdir()
    if "nested" in features:
        (repo / "specs/changes").rename(outside / "changes")
        (repo / "specs/changes").symlink_to(outside / "changes")
    elif "inside" in features:
        (repo / ".prdkit/history/other-log").mkdir(parents=True)
        (repo / ".prdkit/history/log").symlink_to("other-log")
    elif "escaping" in features:
        (repo / ".prdkit/history").mkdir(exist_ok=True)
        (repo / ".prdkit/history/log").symlink_to(outside)
    contents(repo, f"src/{change}.txt", features | {"untracked"}, token)
    return repo, change, outside


def close(root, template, features, token):
    repo, change, outside = build_close(root, template, features, token)
    record, entry = f"specs/changes/{change}.md", f".prdkit/history/log/{change}.md"
    before, guard = tree(repo, (".git",)), tree(outside)
    head = git(repo, "rev-parse", "HEAD")
    # Full branch ref when attached, literal HEAD when detached.
    attachment = git(repo, "rev-parse", "--symbolic-full-name", "HEAD")
    # Git may refresh stat-cache timestamps in the copied checkout. Compare
    # actual index entries and staged content rather than that cache.
    def index():
        return (git(repo, "ls-files", "-zv", "--stage"), git(repo, "diff", "--cached", "--raw", "-z"))

    staged = index()
    rc, output = invoke(repo, "close-change.sh", "--pr", "https://github.com/owner/repo/pull/7",
                        change, "generated close")
    same(guard, tree(outside), "adjacent directory")
    if rc:
        require(git(repo, "rev-parse", "HEAD") == head, "refusal moved HEAD")
        require(git(repo, "rev-parse", "--symbolic-full-name", "HEAD") == attachment,
                "refusal changed HEAD attachment")
        require(index() == staged, "refusal changed index")
        same(before, tree(repo, (".git",)), "refused checkout")
    else:
        require(git(repo, "rev-parse", "HEAD^") == head, "close replaced local history")
        delta = git(repo, "diff", "--no-renames", "--name-only", "HEAD^", "HEAD").splitlines()
        require(set(delta) == {record.encode(), entry.encode()}, "unexpected close commit")
        after = tree(repo, (".git",))
        del before[record], after[entry]
        after.pop(".prdkit/history/log", None)  # created to hold the new entry
        if ".prdkit/history" not in before:
            after.pop(".prdkit/history", None)
        same(before, after, "unrelated work")
    refuse = bool(features & {"staged", "inside", "escaping", "nested"})
    require(rc == int(refuse), f"expected exit {int(refuse)}, got {rc}: {output}")


if __name__ == "__main__":
    if sys.argv[1] == "plan":
        plan(sys.argv[2])
    else:
        args = sys.argv[1:]
        build = args[0] == "build"
        if build:
            _, directory, *args = args
        lane, source, seed, number, *flags = args
        print(f"{lane}: seed={seed} case={number} features={','.join(flags) or '(plain)'}",
              flush=True)
        os.environ.update(GIT_OPTIONAL_LOCKS="0", GIT_AUTHOR_NAME="Test", GIT_COMMITTER_NAME="Test",
                          GIT_AUTHOR_EMAIL="t@example.invalid", GIT_COMMITTER_EMAIL="t@example.invalid",
                          GIT_AUTHOR_DATE="2026-01-01T00:00:00Z", GIT_COMMITTER_DATE="2026-01-01T00:00:00Z")
        fixture = (Path(source).resolve(), set(flags), f"{seed}-{number}")
        if build:
            root = Path(directory).resolve()
            root.mkdir()  # never reuse an existing directory
            {"cleanup": build_cleanup, "close": build_close}[lane](root, *fixture)
        else:
            with tempfile.TemporaryDirectory() as directory:
                {"cleanup": cleanup, "close": close}[lane](Path(directory).resolve(), *fixture)
