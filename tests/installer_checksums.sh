#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
source <(sed '$d' "$ROOT_DIR/install.sh")
cleanup() { rm -rf "$WORK_DIR"; }
TRAFIRA_BACKEND_FILE="$WORK_DIR/backend.ipk"
TRAFIRA_APP_FILE="$WORK_DIR/app.ipk"
printf backend >"$TRAFIRA_BACKEND_FILE"
printf app >"$TRAFIRA_APP_FILE"
BACKEND_HASH="$(sha256sum "$TRAFIRA_BACKEND_FILE" | cut -d ' ' -f1)"
APP_HASH="$(sha256sum "$TRAFIRA_APP_FILE" | cut -d ' ' -f1)"
install_json_ucode() {
  case "$2" in
    backend.ipk) printf '%s' "$BACKEND_HASH" ;;
    app.ipk) printf '%s' "$APP_HASH" ;;
    *) return 1 ;;
  esac
}
verify_trafira_packages
printf corruption >>"$TRAFIRA_APP_FILE"
if (verify_trafira_packages) >/dev/null 2>&1; then echo 'FAIL: damaged package accepted'; exit 1; fi
printf app >"$TRAFIRA_APP_FILE"
APP_HASH=''
if (verify_trafira_packages) >/dev/null 2>&1; then echo 'FAIL: missing digest accepted'; exit 1; fi
printf 'Installer checksum checks passed\n'
