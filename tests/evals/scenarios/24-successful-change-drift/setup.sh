#!/usr/bin/env bash
set -euo pipefail
source "$PK_ROOT/tests/evals/fixture.sh"
fixture_outcome_programme
git update-ref refs/eval/fixture HEAD
