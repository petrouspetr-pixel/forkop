#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
# Exercise the actual orchestration; external system work is recorded, never run.
source <(sed '$d' "$ROOT_DIR/install.sh")
check_root() { :; }
cleanup() { :; }
for operation in init_tmp_dir detect_fetcher sync_time check_system decide_i18n_installation select_sing_box_installation pkg_list_update ensure_bootstrap_ucode_runtime resolve_trafira_release download_trafira_packages verify_trafira_packages prepare_trafira_installation install_backend_package install_ui_packages install_selected_sing_box post_install; do
  eval "$operation() { printf '%s\\n' '$operation' >>\"$WORK_DIR/actions\"; }"
done
for package in forkop podkop podkop-plus luci-app-forkop luci-app-podkop luci-app-podkop-plus luci-i18n-forkop-ru luci-i18n-podkop-plus-ru; do
  pkg_is_installed() { [ "$1" = "$package" ]; }
  : >"$WORK_DIR/actions"
  if (main) >"$WORK_DIR/output" 2>&1; then fail "$package must block installation"; fi
  [ ! -s "$WORK_DIR/actions" ] || fail "$package allowed mutation before rejection"
  grep -qi 'backup' "$WORK_DIR/output" || fail 'manual backup instruction missing'
  grep -qi 'remove' "$WORK_DIR/output" || fail 'manual removal instruction missing'
done
for package in none trafira; do
  pkg_is_installed() { [ "$1" = "$package" ]; }
  : >"$WORK_DIR/actions"
  (main) >"$WORK_DIR/output" 2>&1 || fail "$package installation unexpectedly blocked"
  grep -Fxq install_backend_package "$WORK_DIR/actions" || fail 'normal installation did not proceed'
done
printf 'Manual legacy transition guard checks passed\n'
