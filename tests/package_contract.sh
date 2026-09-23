#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRAFIRA_MAKEFILE="$ROOT_DIR/trafira/Makefile"
TRAFIRA_CONFIG="$ROOT_DIR/trafira/files/etc/config/trafira"
BUILD_SCRIPT="$ROOT_DIR/build.sh"
BUILD_WORKFLOW="$ROOT_DIR/.github/workflows/build.yml"
TRAFIRA_LIB="$ROOT_DIR/trafira/files/usr/lib"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

require_file() {
  local file="$1"

  [ -r "$file" ] || fail "required file is missing: $file"
}

require_make_dep() {
  local package="$1"

  grep -Eq "DEPENDS:=.*(^|[[:space:]])\\+$package([[:space:]]|$)" "$TRAFIRA_MAKEFILE" ||
    fail "trafira/Makefile DEPENDS is missing +$package"
}

require_build_dep() {
  local variable="$1"
  local package="$2"

  grep -Eq "^${variable}=.*(^|[[:space:],])${package}([[:space:],\"]|$)" "$BUILD_SCRIPT" ||
    fail "build.sh ${variable} is missing $package"
}

require_package_dependency() {
  local package="$1"

  require_make_dep "$package"
  require_build_dep "BACKEND_DEPENDS_IPK" "$package"
  require_build_dep "BACKEND_DEPENDS_APK" "$package"
}

require_file "$TRAFIRA_MAKEFILE"
require_file "$TRAFIRA_CONFIG"
require_file "$BUILD_SCRIPT"
require_file "$BUILD_WORKFLOW"
require_file "$TRAFIRA_LIB"

bash "$BUILD_SCRIPT" --help >/dev/null ||
  fail "build.sh must provide command-line usage"
if bash "$BUILD_SCRIPT" 1.2 >/dev/null 2>&1; then
  fail "build.sh must reject invalid release versions before building"
fi
if grep -Eq 'WSL_|WINDOWS_ARTIFACTS_DIR|SOURCE_ROOT_DIR|\.wsl-build|apt-get|sudo' "$BUILD_SCRIPT"; then
  fail "build.sh must remain a portable unprivileged Linux build entrypoint"
fi
grep -Fq 'SDK_DIR="${SDK_DIR:-$SDK_CACHE_DIR/extracted}"' "$BUILD_SCRIPT" ||
  fail "build.sh must reuse the prepared SDK cache independently of BUILD_DIR"
grep -Fq 'flock -n 9' "$BUILD_SCRIPT" ||
  fail "build.sh must reject concurrent package builds"
grep -Fq '[[ ! -f "$luci_src_dir/po2lmo.c" ]]' "$BUILD_SCRIPT" ||
  fail "build.sh must recover from an interrupted LuCI feed checkout"
[ "$(grep -Fc 'fakeroot sh -c' "$BUILD_SCRIPT")" -eq 1 ] ||
  fail "build.sh must use fakeroot for IPK ownership"
[ "$(grep -Fc 'unshare -r sh -c' "$BUILD_SCRIPT")" -eq 1 ] ||
  fail "build.sh must use a user namespace for APK ownership"
grep -Fq 'sudo apt-get install -y' "$BUILD_WORKFLOW" ||
  fail "build workflow must own host dependency installation"
grep -Fq 'sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0' "$BUILD_WORKFLOW" ||
  fail "Ubuntu 24.04 build workflow must allow unprivileged user namespaces"
grep -Fq './build.sh "$VERSION"' "$BUILD_WORKFLOW" ||
  fail "build workflow must invoke the public build entrypoint"
grep -Fq "replace('\\\\n', '\\n')" "$BUILD_WORKFLOW" ||
  fail "build workflow must normalize escaped release-note line breaks"
grep -Fq 'body: ${{ needs.preparation.outputs.release_notes }}' "$BUILD_WORKFLOW" ||
  fail "release action must receive normalized Markdown notes"

for conflict in https-dns-proxy nextdns luci-app-passwall luci-app-passwall2 forkop podkop-plus podkop; do
  grep -E 'CONFLICTS:=' "$TRAFIRA_MAKEFILE" | grep -Fq "$conflict" ||
    fail "trafira/Makefile conflicts are missing $conflict"
  grep -E '^BACKEND_CONFLICTS_IPK=' "$BUILD_SCRIPT" | grep -Fq "$conflict" ||
    fail "manual IPK conflicts are missing $conflict"
  grep -E '^BACKEND_DEPENDS_APK=' "$BUILD_SCRIPT" | grep -Fq "!$conflict" ||
    fail "manual APK conflicts are missing $conflict"
done

if grep -Fq 'coreutils-sort' "$TRAFIRA_MAKEFILE" "$BUILD_SCRIPT"; then
  fail "unused coreutils-sort runtime dependency must not be packaged"
fi

grep -Fq "must use x.y.z format" "$TRAFIRA_MAKEFILE" ||
  fail "trafira/Makefile must enforce the three-part release version contract"
grep -Fq 'APK_INTERNAL_VERSION="$RELEASE_VERSION"' "$BUILD_SCRIPT" ||
  fail "build.sh must use the exact three-part release version for APK metadata"
grep -Fq 'USERID:=trafirabyedpi:trafirabyedpi' "$TRAFIRA_MAKEFILE" ||
  fail "Trafira package must create a dedicated ByeDPI runtime user"
grep -Fq 'BACKEND_REQUIRE_USER="trafirabyedpi:trafirabyedpi"' "$BUILD_SCRIPT" ||
  fail "manual release builds must preserve the ByeDPI runtime user contract"
grep -Fq 'Require-User: ${BACKEND_REQUIRE_USER}' "$BUILD_SCRIPT" ||
  fail "manual IPK metadata must declare the ByeDPI runtime user"
grep -Fq '${package_name}.rusers' "$BUILD_SCRIPT" ||
  fail "manual APK metadata must carry the ByeDPI runtime user"
grep -Fq 'export pkgname="trafira"' "$BUILD_SCRIPT" ||
  fail "manual backend package scripts must initialize Trafira user metadata"
grep -Fq "option component_update_check_enabled '1'" "$TRAFIRA_CONFIG" ||
  fail "new installations must enable component update checks by default"
grep -Fq "option config_version '1.0.5'" "$TRAFIRA_CONFIG" ||
  fail "new installations must start at the current configuration schema version"
grep -Fq "list applied_migrations 'interface_sections'" "$TRAFIRA_CONFIG" ||
  fail "new installations must mark the interface section migration as applied"
grep -Fq "list applied_migrations 'enable_component_checks'" "$TRAFIRA_CONFIG" ||
  fail "new installations must mark the component check migration as applied"
grep -Fq "list applied_migrations 'http_connection_urls'" "$TRAFIRA_CONFIG" ||
  fail "new installations must mark the HTTP connection URL migration as applied"
grep -Fq '/usr/lib/trafira/config/migration.uc migrate' "$TRAFIRA_MAKEFILE" ||
  fail "OpenWrt package postinst must run configuration migrations"
[ "$(grep -Fc '/usr/lib/trafira/config/migration.uc migrate' "$BUILD_SCRIPT")" -ge 3 ] ||
  fail "manual IPK/APK package scripts must run configuration migrations after install and upgrade"

if grep -Rqs 'require("uci")' "$TRAFIRA_LIB"; then
  require_package_dependency "ucode-mod-uci"
fi

if grep -Rqs 'require("fs")' "$TRAFIRA_LIB"; then
  require_package_dependency "ucode-mod-fs"
fi

if grep -Rqs 'trafira_dnsmasq_failsafe_restore_raw' \
  "$ROOT_DIR/trafira/files/usr/bin" \
  "$ROOT_DIR/trafira/files/usr/lib" \
  "$ROOT_DIR/trafira/files/etc/init.d"; then
  fail "duplicated raw dnsmasq failsafe restore shell owner is present"
fi

printf 'package contract checks passed\n'
