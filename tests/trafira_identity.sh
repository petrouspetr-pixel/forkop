#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRAFIRA_LIB="$ROOT_DIR/trafira/files/usr/lib"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# Resolve menu -> view -> UCI/ACL and CLI grants as one installed contract.
# Generate release fixtures using the exact filenames published by build.sh.
node - "$ROOT_DIR" "$WORK_DIR" <<'NODE'
const fs = require('fs');
const path = require('path');
const assert = require('assert/strict');
const [root, work] = process.argv.slice(2);
const read = name => fs.readFileSync(path.join(root, name), 'utf8');
const acl = JSON.parse(read('luci-app-trafira/root/usr/share/rpcd/acl.d/luci-app-trafira.json'));
const menu = JSON.parse(read('luci-app-trafira/root/usr/share/luci/menu.d/luci-app-trafira.json'));
const entry = menu['admin/services/trafira'];
assert(entry && entry.title === 'Trafira');
assert.equal(entry.action.type, 'view');
assert(fs.existsSync(path.join(root, 'luci-app-trafira/htdocs/luci-static/resources/view', entry.action.path + '.js')));
assert.deepEqual(Object.keys(entry.depends.uci), ['trafira']);
assert(fs.existsSync(path.join(root, 'trafira/files/etc/config/trafira')));
for (const group of entry.depends.acl) {
  for (const access of ['read', 'write']) assert(acl[group][access].uci.includes('trafira'));
  for (const executable of ['/usr/bin/trafira', '/etc/init.d/trafira']) {
    assert(acl[group].read.file[executable].includes('exec'));
    assert(fs.existsSync(path.join(root, 'trafira/files', executable)));
  }
  for (const prefix of ['/var/run/trafira', '/tmp/run/trafira']) {
    for (const suffix of ['section-cache/*', 'component-actions/*', 'ui-state/*', 'ui-state/service-actions/*', 'ui-state/latency-actions/*'])
      assert(acl[group].read.file[`${prefix}/${suffix}`].includes('read'));
  }
}
const call = read('fe-app-trafira/src/trafira/methods/shell/callBaseMethod.ts');
const command = call.match(/command: string = '([^']+)'/)[1];
assert(acl['luci-app-trafira'].read.file[command].includes('exec'));

const build = read('build.sh');
const names = [...new Set([...build.matchAll(/\$output_dir\/((?:trafira|luci-app-trafira|luci-i18n-trafira-ru)_\$\{RELEASE_VERSION\}\.(?:ipk|apk))/g)].map(m => m[1].replace('${RELEASE_VERSION}', '2.0.0')))];
assert.equal(names.length, 6, 'build must publish backend, app and Russian locale in both package formats');
const owner = read('install.sh').match(/^REPO_OWNER="([^"]+)"/m)[1];
const repo = read('install.sh').match(/^REPO_NAME="([^"]+)"/m)[1];
assert.equal(`${owner}/${repo}`, 'petrouspetr-pixel/trafira');
const releaseUrl = `https://github.com/${owner}/${repo}/releases/tag/2.0.0`;
const release = {
  tag_name: '2.0.0', html_url: releaseUrl,
  assets: names.map(name => ({name, browser_download_url: `https://github.com/${owner}/${repo}/releases/download/2.0.0/${name}`})),
};
fs.writeFileSync(path.join(work, 'release.json'), JSON.stringify(release));
for (const ext of ['ipk', 'apk']) {
  const asset = name => release.assets.find(a => a.name === `${name}_2.0.0.${ext}`);
  const fields = [releaseUrl];
  for (const name of ['trafira', 'luci-app-trafira', 'luci-i18n-trafira-ru']) fields.push(asset(name).name, asset(name).browser_download_url);
  fs.writeFileSync(path.join(work, `expected-${ext}.tsv`), fields.join('\t') + '\n');
}
const legacy = structuredClone(release);
for (const asset of legacy.assets) asset.name = asset.name.replaceAll('trafira', 'forkop');
fs.writeFileSync(path.join(work, 'legacy.json'), JSON.stringify(legacy));
NODE

for format in ipk apk; do
  ucode "$TRAFIRA_LIB/components/updater.uc" trafira-release-plan 2.0.0 "$format" 1 \
    <"$WORK_DIR/release.json" >"$WORK_DIR/actual.tsv"
  cmp "$WORK_DIR/expected-$format.tsv" "$WORK_DIR/actual.tsv" || fail "published $format artifacts do not match updater selection"
  if ucode "$TRAFIRA_LIB/components/updater.uc" trafira-release-plan 2.0.0 "$format" 1 <"$WORK_DIR/legacy.json" >/dev/null; then
    fail "updater accepted legacy package names as Trafira"
  fi
done

# Exercise the real action endpoint through a fake HTTP transport. No network,
# service changes, package installation or writes outside the fixture directory.
fake_lib="$WORK_DIR/lib"
fake_bin="$WORK_DIR/bin"
mkdir -p "$fake_lib/core" "$fake_lib/components" "$fake_lib/singbox" "$fake_bin"
cp "$TRAFIRA_LIB/core/constants.uc" "$fake_lib/core/constants.uc"
cp "$TRAFIRA_LIB/components/updater.uc" "$fake_lib/components/updater.uc"
printf 'return {};\n' >"$fake_lib/core/uci.uc"
printf 'exit(0);\n' >"$fake_lib/singbox/runtime.uc"
export TRAFIRA_IDENTITY_WORK="$WORK_DIR"
export TRAFIRA_IDENTITY_MKTEMP
TRAFIRA_IDENTITY_MKTEMP="$(command -v mktemp)"
cat >"$fake_bin/curl" <<'SH'
#!/bin/sh
output=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) shift; output="$1" ;;
    https://*) printf '%s\n' "$1" >>"$TRAFIRA_IDENTITY_WORK/http-urls" ;;
  esac
  shift
done
if [ -n "$output" ]; then
  cp "$TRAFIRA_IDENTITY_WORK/release.json" "$output"
else
  cat "$TRAFIRA_IDENTITY_WORK/release.json"
fi
SH
cat >"$fake_bin/mktemp" <<'SH'
#!/bin/sh
if [ "$1" = '-d' ]; then
  exec "$TRAFIRA_IDENTITY_MKTEMP" -d "$TRAFIRA_IDENTITY_WORK/action.XXXXXX"
fi
exec "$TRAFIRA_IDENTITY_MKTEMP" "$TRAFIRA_IDENTITY_WORK/http.XXXXXX"
SH
printf '#!/bin/sh\nexit 0\n' >"$fake_bin/find"
chmod +x "$fake_bin/curl" "$fake_bin/mktemp" "$fake_bin/find"

version="$(env -u TRAFIRA_RELEASE_REPO PATH="$fake_bin:$PATH" TRAFIRA_LIB="$fake_lib" \
  ucode -L "$fake_lib" "$TRAFIRA_LIB/components/action.uc" latest-trafira-version)"
[ "$version" = '2.0.0' ] || fail "runtime updater did not parse Trafira release version"
[ "$(cat "$WORK_DIR/http-urls")" = 'https://api.github.com/repos/petrouspetr-pixel/trafira/releases/latest' ] ||
  fail "runtime updater requested the wrong publication endpoint"

printf 'Trafira identity checks passed\n'
