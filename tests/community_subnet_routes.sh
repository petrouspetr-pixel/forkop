#!/usr/bin/env bash
set -eo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/trafira/files/usr/lib"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
cat >"$WORK_DIR/fixture.json" <<'JSON'
{"settings":{"dns_server":"1.1.1.1"},"section":[
 {".name":"telegram_proxy",".type":"section","enabled":"1","action":"outbound","outbound_json":"{\"type\":\"direct\"}","community_lists":["telegram"],"source_ip_cidr":["192.0.2.0/24"],"ports":["443"]},
 {".name":"telegram_block",".type":"section","enabled":"1","action":"block","community_lists":["telegram"]},
 {".name":"dns_only",".type":"section","enabled":"1","action":"dns","dns_type":"udp","dns_server":"9.9.9.9","community_lists":["meta"]}
]}
JSON
ucode -L "$LIB" "$LIB/singbox/generator.uc" generate-config-fixture \
  "$WORK_DIR/fixture.json" "$WORK_DIR/config.json" 127.0.0.1 0 1
node - "$WORK_DIR/config.json" <<'JS'
const fs = require('fs'), assert = require('assert/strict');
const config = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const sets = config.route.rule_set.filter(s => s.type === 'local' && s.tag.startsWith('community-telegram-'));
assert.equal(sets.length, 2, 'both downloaded address families need local routing rule sets');
const tags = sets.map(s => s.tag);
const array = v => Array.isArray(v) ? v : [v];
const proxy = config.route.rules.find(r => r.outbound === 'telegram_proxy-out' && r.rule_set);
assert(proxy && tags.every(t => array(proxy.rule_set).includes(t)));
assert.deepEqual(array(proxy.source_ip_cidr), ['192.0.2.0/24']);
assert.deepEqual(proxy.port, [443]);
assert(config.route.rules.some(r => r.action === 'reject' && tags.every(t => array(r.rule_set).includes(t))));
for (const rule of config.dns.rules) assert(!tags.some(t => array(rule.rule_set).includes(t)), 'subnet-only sets must not select DNS');
assert(!config.route.rule_set.some(s => s.type === 'local' && s.tag.startsWith('community-meta-')), 'DNS-only actions do not intercept subnets');
for (const set of sets) assert.deepEqual(JSON.parse(fs.readFileSync(set.path, 'utf8')), {version:3,rules:[]});
JS
printf 'community subnet routing checks passed\n'
