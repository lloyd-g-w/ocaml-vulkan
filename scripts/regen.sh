#!/usr/bin/env bash
# Regenerate lib/generated/*.ml from registry/vk.xml.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 gen/gen.py --registry registry/vk.xml --out lib/generated "$@"
