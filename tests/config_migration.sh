#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRAFIRA_LIB="$ROOT_DIR/trafira/files/usr/lib"
RUNTIME_MIGRATION="$TRAFIRA_LIB/config/migration.uc"
INSTALLER="$ROOT_DIR/install.sh"
WORK_DIR="$(mktemp -d)"
MIGRATION="$RUNTIME_MIGRATION"
MIGRATIONS_DIR="$TRAFIRA_LIB/config/migrations"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

if grep -n -E 'TRAFIRA_CONFIG_MIGRATION_EOF|installer_config_migration_path' "$INSTALLER" >/dev/null 2>&1; then
  fail "install.sh must not embed configuration migration logic"
fi
[ -s "$MIGRATION" ] || fail "runtime configuration migration module is missing"
[ ! -e "$MIGRATIONS_DIR" ] || fail "configuration migrations must stay in one migration.uc file"

if grep -n -E 'require\("uci"\)\.cursor|uci -q|uci", "-q"' "$MIGRATION" >/dev/null 2>&1; then
  fail "installer config migration must use core.uci instead of direct UCI cursor or CLI access"
fi
grep -Fq 'require("core.uci")' "$MIGRATION" ||
  fail "installer config migration must import core.uci"
grep -Fq '{ id: "interface_sections", run: migrate_interface_sections }' "$MIGRATION" ||
  fail "interface section migration must have a stable named marker"
grep -Fq '{ id: "enable_component_checks", run: migrate_enable_component_checks }' "$MIGRATION" ||
  fail "component check migration must have a stable named marker"
grep -Fq '{ id: "http_connection_urls", run: migrate_http_connection_urls }' "$MIGRATION" ||
  fail "HTTP connection URL migration must have a stable named marker"
grep -Fq 'release_at_most(ctx, "1.0.1")' "$MIGRATION" ||
  fail "release-specific migrations must use the source release only as a condition"
grep -Fq 'release_at_most(ctx, "1.0.4")' "$MIGRATION" ||
  fail "HTTP connection URLs must only migrate from Trafira 1.0.4 and below"

cat >"$WORK_DIR/trafira-1.0.1.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "config_version": "1.0.1",
    "component_update_check_enabled": "0"
  },
  "section": [
    {
      ".name": "main",
      ".type": "section",
      "action": "connection",
      "interfaces": [ "awg0", "tun0" ]
    }
  ]
}
JSON

TRAFIRA_LIB="$TRAFIRA_LIB" ucode -L "$TRAFIRA_LIB" "$MIGRATION" migrate-fixture "$WORK_DIR/trafira-1.0.1.json" >"$WORK_DIR/trafira-1.0.2.json"

node - "$WORK_DIR/trafira-1.0.2.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const section = out.config.section[0];
const interfaces = out.config.section_interface || [];

function assert(condition, message) {
  if (!condition) {
    console.error(message);
    process.exit(1);
  }
}

assert(out.changed === true, '1.0.1 config should require migration');
assert(out.config.settings.config_version === '1.0.5', 'config schema version should advance to 1.0.5');
assert(out.config.settings.component_update_check_enabled === '1', 'updates from 1.0.1 and below should enable component update checks');
assert(JSON.stringify(out.config.settings.applied_migrations) === JSON.stringify(['interface_sections', 'enable_component_checks', 'http_connection_urls']), 'named migrations should be recorded');
assert(!Object.prototype.hasOwnProperty.call(section, 'interfaces'), 'parent interface list should be removed');
assert(JSON.stringify(interfaces.map(item => item.name)) === JSON.stringify(['awg0', 'tun0']), 'interfaces should keep their order');
for (const item of interfaces) {
  assert(item.section === 'main', 'interface child should reference its parent');
  assert(item.domain_resolver_enabled === '0', 'resolver should default to disabled');
  assert(item.domain_resolver_dns_type === 'udp', 'resolver protocol default');
  assert(item.domain_resolver_dns_server === '8.8.8.8', 'resolver server default');
}
NODE

cat >"$WORK_DIR/trafira-1.0.2-disabled.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "config_version": "1.0.2",
    "component_update_check_enabled": "0"
  },
  "section": []
}
JSON

TRAFIRA_LIB="$TRAFIRA_LIB" ucode -L "$TRAFIRA_LIB" "$MIGRATION" migrate-fixture "$WORK_DIR/trafira-1.0.2-disabled.json" >"$WORK_DIR/trafira-1.0.2-disabled-output.json"

node - "$WORK_DIR/trafira-1.0.2-disabled-output.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));

function assert(condition, message) {
  if (!condition) {
    console.error(message);
    process.exit(1);
  }
}

assert(out.config.settings.component_update_check_enabled === '0', '1.0.2 config must preserve an explicitly disabled component check');
assert(out.config.settings.config_version === '1.0.5', '1.0.2 config should advance through the HTTP URL migration schema');
assert(JSON.stringify(out.config.settings.applied_migrations) === JSON.stringify(['interface_sections', 'enable_component_checks', 'http_connection_urls']), 'newer configs should mark skipped migrations');
NODE

cat >"$WORK_DIR/trafira-1.0.4-http.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "config_version": "1.0.4"
  },
  "section": [
    {
      ".name": "main",
      ".type": "section",
      "action": "connection",
      "selector_proxy_links": [
        "https://user:p%2540ss@[2001:db8::1]:8443/#Secure%20HTTP",
        "vless://00000000-0000-4000-8000-000000000001@example.com:443",
        "http://proxy.example:8080",
        "https://invalid.example/no-port"
      ],
      "outbound_jsons": [
        "{\"type\":\"direct\",\"tag\":\"http\"}"
      ]
    }
  ]
}
JSON

TRAFIRA_LIB="$TRAFIRA_LIB" ucode -L "$TRAFIRA_LIB" "$MIGRATION" migrate-fixture "$WORK_DIR/trafira-1.0.4-http.json" >"$WORK_DIR/trafira-1.0.4-http-output.json"

node - "$WORK_DIR/trafira-1.0.4-http-output.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const section = out.config.section[0];
const jsonOutbounds = section.outbound_jsons.map(JSON.parse);

function assert(condition, message) {
  if (!condition) {
    console.error(message);
    process.exit(1);
  }
}

assert(out.config.settings.config_version === '1.0.5', '1.0.4 config should advance to schema 1.0.5');
assert(JSON.stringify(section.selector_proxy_links) === JSON.stringify([
  'vless://00000000-0000-4000-8000-000000000001@example.com:443',
  'https://invalid.example/no-port',
]), 'only valid native HTTP proxy links should leave Connection URLs');
assert(jsonOutbounds.length === 3, 'migrated HTTP outbounds should precede the existing JSON list');
assert(JSON.stringify(jsonOutbounds[0]) === JSON.stringify({
  type: 'http',
  tag: 'Secure HTTP',
  server: '2001:db8::1',
  server_port: 8443,
  username: 'user',
  password: 'p@ss',
  tls: { enabled: true },
}), 'HTTPS URL should preserve its name, credentials, IPv6 server, port, and TLS');
assert(JSON.stringify(jsonOutbounds[1]) === JSON.stringify({
  type: 'http',
  tag: 'http-1',
  server: 'proxy.example',
  server_port: 8080,
}), 'unnamed HTTP URL should receive a unique http tag');
assert(jsonOutbounds[2].type === 'direct' && jsonOutbounds[2].tag === 'http', 'existing JSON outbounds should remain unchanged');
assert(JSON.stringify(out.config.settings.applied_migrations) === JSON.stringify(['interface_sections', 'enable_component_checks', 'http_connection_urls']), 'HTTP URL migration should be recorded');
NODE

cat >"$WORK_DIR/trafira-1.0.5-http.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "config_version": "1.0.5"
  },
  "section": [
    {
      ".name": "main",
      ".type": "section",
      "action": "connection",
      "selector_proxy_links": [ "http://proxy.example:8080" ]
    }
  ]
}
JSON

TRAFIRA_LIB="$TRAFIRA_LIB" ucode -L "$TRAFIRA_LIB" "$MIGRATION" migrate-fixture "$WORK_DIR/trafira-1.0.5-http.json" >"$WORK_DIR/trafira-1.0.5-http-output.json"

node - "$WORK_DIR/trafira-1.0.5-http-output.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const section = out.config.section[0];

if (JSON.stringify(section.selector_proxy_links) !== JSON.stringify(['http://proxy.example:8080']) || section.outbound_jsons) {
  console.error('1.0.5 and newer configs must not run the legacy HTTP URL conversion');
  process.exit(1);
}
NODE

cat >"$WORK_DIR/runtime-version.state" <<'EOF_UCI'
trafira.settings=settings
trafira.settings.config_version=1.0.1
trafira.settings.component_update_check_enabled=0
trafira.main=section
trafira.main.enabled=1
trafira.main.action=connection
trafira.main.interfaces=awg0
trafira.main.selector_proxy_links=http://proxy.example:8080
EOF_UCI
: >"$WORK_DIR/runtime-version.log"
TRAFIRA_UCI_STATE_FILE="$WORK_DIR/runtime-version.state" \
TRAFIRA_UCI_LOG_FILE="$WORK_DIR/runtime-version.log" \
TRAFIRA_CONFIG_NAME="trafira" \
TRAFIRA_INTERNAL_CONFIG_TRIGGER_GUARD="$WORK_DIR/internal-config-change" \
ucode -L "$TRAFIRA_LIB" "$MIGRATION" migrate

grep -Fxq 'trafira.settings.config_version=1.0.5' "$WORK_DIR/runtime-version.state" ||
  fail "runtime version migration must advance config_version"
grep -Fxq 'trafira.settings.component_update_check_enabled=1' "$WORK_DIR/runtime-version.state" ||
  fail "runtime version migration must enable component update checks"
grep -Fq 'trafira.settings.applied_migrations=interface_sections enable_component_checks http_connection_urls' "$WORK_DIR/runtime-version.state" ||
  fail "runtime migration must record stable migration names"
grep -Eq '^trafira\.main\.outbound_jsons=\{ "type": "http", "tag": "http", "server": "proxy\.example", "server_port": 8080 \}$' "$WORK_DIR/runtime-version.state" ||
  fail "runtime migration must convert native HTTP proxy links to JSON outbounds"
if grep -Fq 'trafira.main.selector_proxy_links=' "$WORK_DIR/runtime-version.state"; then
  fail "runtime migration must remove converted HTTP connection URLs"
fi
grep -Eq '^trafira\.cfg[0-9a-f]+=section_interface$' "$WORK_DIR/runtime-version.state" ||
  fail "runtime version migration must create interface child settings"
if grep -Fq 'trafira.main.interfaces=' "$WORK_DIR/runtime-version.state"; then
  fail "runtime version migration must remove the parent interface list"
fi

: >"$WORK_DIR/runtime-version.log"
TRAFIRA_UCI_STATE_FILE="$WORK_DIR/runtime-version.state" \
TRAFIRA_UCI_LOG_FILE="$WORK_DIR/runtime-version.log" \
TRAFIRA_CONFIG_NAME="trafira" \
TRAFIRA_INTERNAL_CONFIG_TRIGGER_GUARD="$WORK_DIR/internal-config-change" \
ucode -L "$TRAFIRA_LIB" "$MIGRATION" migrate
if grep -Fq 'commit trafira' "$WORK_DIR/runtime-version.log"; then
  fail "completed named migrations must be idempotent"
fi

mkdir -p \
  "$WORK_DIR/cache-migration/runtime/section-cache" \
  "$WORK_DIR/cache-migration/runtime/subscription-links" \
  "$WORK_DIR/cache-migration/persistent"
printf '7\n' >"$WORK_DIR/cache-migration/runtime/cache-format"
printf 'stale\n' >"$WORK_DIR/cache-migration/runtime/section-cache/stale.json"
printf 'stale\n' >"$WORK_DIR/cache-migration/runtime/subscription-links/stale.json"
printf '7\n' >"$WORK_DIR/cache-migration/persistent/cache-format"
cat >"$WORK_DIR/cache-migration/persistent/proxy-subscription-1.json" <<'JSON'
{
  "version": 1,
  "format": "sing-box-json",
  "outbounds": [
    {
      "type": "vless",
      "tag": "stable-cache-node",
      "server": "stable.example",
      "server_port": 443,
      "uuid": "00000000-0000-4000-8000-000000000001"
    }
  ]
}
JSON

TRAFIRA_UCI_STATE_FILE="$WORK_DIR/runtime-version.state" \
TRAFIRA_UCI_LOG_FILE="$WORK_DIR/runtime-version.log" \
TRAFIRA_CONFIG_NAME="trafira" \
TMP_SUBSCRIPTION_FOLDER="$WORK_DIR/cache-migration/tmp-subscriptions" \
TRAFIRA_RUNTIME_STATE_DIR="$WORK_DIR/cache-migration/runtime" \
TRAFIRA_PERSISTENT_SUBSCRIPTION_CACHE_DIR="$WORK_DIR/cache-migration/persistent" \
TRAFIRA_INTERNAL_CONFIG_TRIGGER_GUARD="$WORK_DIR/internal-config-change" \
ucode -L "$TRAFIRA_LIB" "$MIGRATION" migrate

[ "$(sed -n '1p' "$WORK_DIR/cache-migration/runtime/cache-format")" = "8" ] ||
  fail "package migration must advance the runtime cache format"
[ ! -e "$WORK_DIR/cache-migration/runtime/section-cache/stale.json" ] ||
  fail "package migration must clear the legacy section cache"
[ ! -d "$WORK_DIR/cache-migration/runtime/subscription-links" ] ||
  fail "package migration must remove the retired subscription link cache"
node - "$WORK_DIR/cache-migration/persistent/proxy-subscription-1.json" <<'NODE'
const fs = require('fs');
const subscription = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const outbound = subscription.outbounds[0];
if (outbound.server !== 'stable.example' || !outbound.share_link?.startsWith('vless://')) {
  console.error('package migration must preserve stable subscription data and backfill its direct link');
  process.exit(1);
}
NODE

: >"$WORK_DIR/uci-commit.log"
: >"$WORK_DIR/uci-commit.state"
TRAFIRA_UCI_STATE_FILE="$WORK_DIR/uci-commit.state" \
TRAFIRA_UCI_LOG_FILE="$WORK_DIR/uci-commit.log" \
TRAFIRA_CONFIG_NAME="trafira" \
TRAFIRA_INTERNAL_CONFIG_TRIGGER_GUARD="$WORK_DIR/internal-config-change" \
ucode -L "$TRAFIRA_LIB" "$MIGRATION" commit

grep -Fxq 'commit trafira' "$WORK_DIR/uci-commit.log" ||
  fail "commit mode must commit trafira through core.uci"

printf 'installer config migration checks passed\n'
