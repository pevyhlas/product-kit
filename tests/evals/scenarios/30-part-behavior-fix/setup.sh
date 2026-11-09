#!/usr/bin/env bash
set -euo pipefail
source "$PK_ROOT/tests/evals/fixture.sh"
fixture_project
mkdir -p src tests
sed 's/| a plain text file |/| a shell script |/' specs/architecture.md > specs/architecture.md.tmp
mv specs/architecture.md.tmp specs/architecture.md
cat > specs/parts/p1-greeting.md <<'EOF2'
# P1 Greeting

**What it is**: a shell script · **Maturity**: hypothesis · **Code**: src/greeting.sh

## Why it exists

R-01: it prints the greeting people see when the tool starts.

## Components

### Greeting producer

- **P1.B-01 Exact output**: `bash src/greeting.sh` prints the R-01 greeting and one trailing newline on standard output, nothing else. Test: tests/check-greeting.sh.
EOF2
cat > src/greeting.sh <<'EOF2'
#!/usr/bin/env bash
# Prints the start-up greeting, then the build tag.
printf 'Welcome\n'
printf 'build %s\n' "${BUILD_TAG:-dev}"
EOF2
cat > tests/check-greeting.sh <<'EOF2'
#!/usr/bin/env bash
# Proves P1.B-01: standard output is exactly the greeting and one newline.
set -euo pipefail
if ! cmp -s <(bash src/greeting.sh 2>/dev/null) <(printf 'Welcome\n'); then
    echo 'FAIL: P1.B-01 standard output is not exactly the greeting line' >&2
    exit 1
fi
echo 'PASS: P1.B-01'
EOF2
if bash tests/check-greeting.sh >/dev/null 2>&1; then echo 'fixture expected a failing test' >&2; exit 1; fi
git add -A && git commit -qm 'fixture: code violates P1.B-01'
# Assertions compare with this commit, so committed edits cannot hide from them.
git update-ref refs/eval/fixture HEAD
