#!/usr/bin/env bash
# Release-provenance guard: the VERSION file (which init.sh stamps into every
# consumer's install manifest and reports from --check) must match the newest
# released version header in CHANGELOG.md. The 0.2.0 release shipped with
# VERSION still reading 0.1.0 because nothing enforced this; this test makes a
# lagging VERSION fail CI at release time.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

cd "$PK_ROOT" || exit 1

it "VERSION matches the newest CHANGELOG release header"

version_file="$(head -n 1 VERSION | tr -d '[:space:]')"
changelog_latest="$(grep -oE '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' CHANGELOG.md \
    | head -n 1 | tr -d '#[] ')"

if [ -z "$version_file" ]; then
    _no "VERSION file is missing or empty"
elif [ -z "$changelog_latest" ]; then
    _no "CHANGELOG.md has no '## [X.Y.Z]' release header to compare against"
elif [ "$version_file" = "$changelog_latest" ]; then
    _ok "VERSION ($version_file) matches newest CHANGELOG release ($changelog_latest)"
else
    _no "VERSION reads $version_file but the newest CHANGELOG release is $changelog_latest — bump VERSION in the release PR"
fi

finish
