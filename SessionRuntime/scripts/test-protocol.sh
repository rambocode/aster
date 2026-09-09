#!/usr/bin/env bash
set -euo pipefail
runtime_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$runtime_dir"
if [[ ! -x .build/schema-env/bin/python ]]; then
  echo 'Run scripts/setup-protocol-tests.sh to prepare isolated schema test dependencies.' >&2
  exit 1
fi
.build/schema-env/bin/python tests/protocol_schema.py
zig build test --summary all
