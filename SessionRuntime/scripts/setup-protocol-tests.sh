#!/usr/bin/env bash
set -euo pipefail
runtime_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$runtime_dir"
python3 -m venv .build/schema-env
.build/schema-env/bin/python -m pip --isolated install --index-url https://pypi.org/simple -r protocol/requirements-test.txt
