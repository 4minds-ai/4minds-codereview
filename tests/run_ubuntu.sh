#!/usr/bin/env bash
# Runs the gencr test suite inside a clean Ubuntu container as an unprivileged user, like a
# GitHub-hosted runner (requires Docker). Usage: bash tests/run_ubuntu.sh [image] (default ubuntu:24.04)
set -euo pipefail
image="${1:-ubuntu:24.04}"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
docker run --rm -v "$repo:/src:ro" "$image" bash -c '
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null
  apt-get install -y -qq git zsh shellcheck python3 >/dev/null 2>&1
  useradd -m tester
  cp -R /src /home/tester/work
  chown -R tester /home/tester/work
  su tester -c "
    set -e
    cd ~/work
    git config --global user.email ci@example.com
    git config --global user.name CI
    git config --global --add safe.directory \"*\"
    bash --version | head -n 1
    python3 --version
    awk -W version 2>/dev/null | head -n 1 || true
    bash tests/test_gencr.sh
    bash tests/test_gencr_ci.sh
    bash tests/test_gencr_dup.sh
    bash tests/test_gencr_scope.sh
    bash tests/test_gencr_format.sh
    bash tests/test_gencr_summary.sh
    bash tests/test_gencr_peer.sh
    bash tests/test_gencr_notes.sh
    bash tests/test_gencr_values.sh
    bash tests/test_gencrclaude.sh
    bash tests/test_gencr_auto.sh
    bash tests/test_gencr_adjudication.sh
  "
'
