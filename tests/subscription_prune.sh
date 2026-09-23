#!/usr/bin/env bash
set -eo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node "$ROOT_DIR/tests/helpers/subscription_prune.cjs" --ucode
node "$ROOT_DIR/tests/helpers/subscription_prune_generator.cjs"
