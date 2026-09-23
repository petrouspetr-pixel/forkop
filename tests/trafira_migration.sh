#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
INSTALLER="$ROOT_DIR/install.sh"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
msg() { :; }
pkg_is_installed() { [ "$1" = "forkop" ]; }
TRAFIRA_MIGRATION_ROOT="$WORK_DIR/router"
mkdir -p "$TRAFIRA_MIGRATION_ROOT/etc/config"
printf 'config settings\n' >"$TRAFIRA_MIGRATION_ROOT/etc/config/forkop"
LEGACY_BRAND=podkop
LEGACY_BACKEND_PACKAGE=podkop-plus
for name in detect_forkop_migration prepare_forkop_migration finish_forkop_migration verify_trafira_packages; do
  eval "$(sed -n "/^$name()/,/^}/p" "$INSTALLER")"
done
detect_forkop_migration
[ "$FORKOP_MIGRATION_DETECTED" = 1 ] || fail 'Forkop installation was not detected'
printf 'existing Trafira config\n' >"$TRAFIRA_MIGRATION_ROOT/etc/config/trafira"
if (detect_forkop_migration); then fail 'existing Trafira configuration must stop migration'; fi
grep -Fxq 'existing Trafira config' "$TRAFIRA_MIGRATION_ROOT/etc/config/trafira"
rm "$TRAFIRA_MIGRATION_ROOT/etc/config/trafira"
pkg_is_installed() { [ "$1" = podkop ] || [ "$1" = forkop ]; }
if (detect_forkop_migration); then fail 'independent podkop package must stop installation'; fi
pkg_is_installed() { [ "$1" = forkop ]; }
detect_forkop_migration

awk '/cat > "\$helper_path" <<'\''EOF'\''/ { capture = 1; next } capture && /^EOF$/ { exit } capture { print }' "$INSTALLER" >"$WORK_DIR/helper.uc"
[ -s "$WORK_DIR/helper.uc" ] || fail 'missing embedded helper'
digest="$(printf 'verified package' | sha256sum | awk '{print $1}')"
printf '{"assets":[{"name":"trafira_2.0.0.ipk","digest":"sha256:%s"}]}' "$digest" |
  ucode "$WORK_DIR/helper.uc" release-asset-sha256 trafira_2.0.0.ipk | grep -Fxq "$digest"
if printf '{"assets":[]}' | ucode "$WORK_DIR/helper.uc" release-asset-sha256 missing.ipk; then
  fail 'missing release digest was accepted'
fi
mkdir -p "$TRAFIRA_MIGRATION_ROOT/etc/forkop/tailscale" "$WORK_DIR/backup/references"
printf 'private state\n' >"$TRAFIRA_MIGRATION_ROOT/etc/forkop/tailscale/node.state"
printf 'custom certificate\n' >"$WORK_DIR/custom-cert.pem"
cat >"$WORK_DIR/legacy-config" <<EOF
config settings
 option dns_mtls_client_certificate '$WORK_DIR/custom-cert.pem'
 option cache_path '/etc/forkop/cache.db'
 option hostname 'forkop.example.net'
 option unrelated '/etc/forkop-other/file'
EOF
ucode "$WORK_DIR/helper.uc" forkop-config "$WORK_DIR/legacy-config" "$WORK_DIR/converted" "$WORK_DIR/backup"
grep -Fq "option cache_path '/etc/trafira/cache.db'" "$WORK_DIR/converted"
grep -Fq 'forkop.example.net' "$WORK_DIR/converted"
grep -Fq '/etc/forkop-other/file' "$WORK_DIR/converted"
cmp "$WORK_DIR/custom-cert.pem" "$WORK_DIR/backup/references$WORK_DIR/custom-cert.pem"

# A partial uninstall must not discard the persistent backup or replace the new config.
TMP_DIR="$WORK_DIR/tmp"
mkdir -p "$TMP_DIR"
install_json_ucode() {
  case "$1" in
    forkop-config) shift; ucode "$WORK_DIR/helper.uc" forkop-config "$@" ;;
    installer-stop-forkop) printf 'FORKOP_WAS_ENABLED=1\nFORKOP_WAS_RUNNING=1\n' ;;
    installer-remove-forkop) return 1 ;;
    *) fail "unexpected installer action $1" ;;
  esac
}
if (prepare_forkop_migration); then fail 'failed package removal must stop migration'; fi
backup_config="$(find "$TRAFIRA_MIGRATION_ROOT/etc/trafira-migration-backups" -name forkop.config | head -n 1)"
[ -s "$backup_config" ] || fail 'persistent configuration backup missing after failure'
cmp "$backup_config" "$TRAFIRA_MIGRATION_ROOT/etc/config/forkop"
[ ! -e "$TRAFIRA_MIGRATION_ROOT/etc/config/trafira" ] || fail 'failed removal published target config'
find "$TRAFIRA_MIGRATION_ROOT/etc/trafira-migration-backups" -name node.state | grep -q . || fail 'Tailscale state was not backed up'

# Full mocked package lifecycle: old prerm deletes shared sing-box, then the
# installer restores it and publishes persistent data before the new postinst.
TRAFIRA_MIGRATION_ROOT="$WORK_DIR/success-router"
mkdir -p "$TRAFIRA_MIGRATION_ROOT/etc/config" "$TRAFIRA_MIGRATION_ROOT/etc/forkop/tailscale" \
  "$TRAFIRA_MIGRATION_ROOT/etc/init.d" "$TRAFIRA_MIGRATION_ROOT/usr/bin"
cp "$WORK_DIR/legacy-config" "$TRAFIRA_MIGRATION_ROOT/etc/config/forkop"
printf 'persisted node identity\n' >"$TRAFIRA_MIGRATION_ROOT/etc/forkop/tailscale/node.state"
printf '# Forkop managed sing-box service\nconfig_load forkop\n' >"$TRAFIRA_MIGRATION_ROOT/etc/init.d/sing-box"
printf 'shared binary\n' >"$TRAFIRA_MIGRATION_ROOT/usr/bin/sing-box"
REMOVED=0
pkg_is_installed() { [ "$1" = forkop ] && [ "$REMOVED" = 0 ]; }
install_json_ucode() {
  case "$1" in
    forkop-config) shift; ucode "$WORK_DIR/helper.uc" forkop-config "$@" ;;
    installer-stop-forkop) printf 'FORKOP_WAS_ENABLED=1\nFORKOP_WAS_RUNNING=1\n' ;;
    installer-remove-forkop)
      REMOVED=1
      rm "$TRAFIRA_MIGRATION_ROOT/etc/init.d/sing-box" "$TRAFIRA_MIGRATION_ROOT/usr/bin/sing-box"
      ;;
    *) fail "unexpected installer action $1" ;;
  esac
}
detect_forkop_migration
prepare_forkop_migration
[ "$FORKOP_WAS_ENABLED:$FORKOP_WAS_RUNNING" = 1:1 ] || fail 'service state was lost'
grep -Fq 'config_load trafira' "$TRAFIRA_MIGRATION_ROOT/etc/init.d/sing-box"
grep -Fq 'Trafira managed sing-box' "$TRAFIRA_MIGRATION_ROOT/etc/init.d/sing-box"
grep -Fxq 'shared binary' "$TRAFIRA_MIGRATION_ROOT/usr/bin/sing-box"
cmp "$FORKOP_SOURCE_DATA/tailscale/node.state" "$TRAFIRA_TARGET_DATA/tailscale/node.state"
[ -f "$FORKOP_SOURCE_CONFIG" ] || fail 'source configuration retired before installation completed'
finish_forkop_migration
[ -f "$FORKOP_MIGRATION_BACKUP/retired-forkop.config" ] || fail 'source configuration was not archived'
[ -f "$FORKOP_MIGRATION_BACKUP/retired-persistent/tailscale/node.state" ] || fail 'source identity was not archived'
detect_forkop_migration
[ "$FORKOP_MIGRATION_DETECTED" = 0 ] || fail 'completed migration broke subsequent upgrades'

# Digest mismatch must fail before any migration action can be called.
FORKOP_MIGRATION_DETECTED=1
TRAFIRA_BACKEND_FILE="$WORK_DIR/new.ipk"
TRAFIRA_APP_FILE="$WORK_DIR/ui.ipk"
TRAFIRA_I18N_FILE=""
TRAFIRA_RELEASE_JSON='{}'
printf 'damaged package' >"$TRAFIRA_BACKEND_FILE"
cp "$TRAFIRA_BACKEND_FILE" "$TRAFIRA_APP_FILE"
install_json_ucode() { printf '%064d\n' 0; }
if (verify_trafira_packages); then fail 'incorrect package digest was accepted'; fi

# Keep the irreversible package transition after all downloads and verification.
awk '
  /^main\(\)/ { inside = 1 }
  inside && /^    download_trafira_packages$/ { downloaded = NR }
  inside && /^    verify_trafira_packages$/ { verified = NR }
  inside && /^    prepare_forkop_migration$/ { prepared = NR }
  inside && /^    install_backend_package$/ { installed = NR }
  inside && /^    post_install$/ { post = NR }
  inside && /^    finish_forkop_migration$/ { finished = NR }
  END { exit !(downloaded < verified && verified < prepared && prepared < installed && installed < post && post < finished) }
' "$INSTALLER" || fail 'migration lifecycle ordering changed'
printf 'Trafira migration safety checks passed\n'
