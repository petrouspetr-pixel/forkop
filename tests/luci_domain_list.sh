#!/usr/bin/env bash
set -eo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/section.js" <<'NODE'
const fs = require('fs');
const assert = require('assert');
const source = fs.readFileSync(process.argv[2], 'utf8');
const main = { parseValueList: value => value.split(/[\s,]+/).filter(Boolean) };
function extract(name, next) {
  const start = source.indexOf(`function ${name}(`);
  const end = source.indexOf(`function ${next}(`, start);
  assert(start >= 0 && end > start, `missing function ${name}`);
  return eval(`(${source.slice(start, end).trim()})`);
}
const uniqueDomainTextValues = extract('uniqueDomainTextValues', 'appendUniqueDomainTextValues');
const appendUniqueDomainTextValues = extract('appendUniqueDomainTextValues', 'loadCombinedDomainText');
assert.strictEqual(appendUniqueDomainTextValues(['example.com', 'example.org'], []), 'example.com\nexample.org');
assert.strictEqual(appendUniqueDomainTextValues('example.com\n\nexample.org\n', []), 'example.com\n\nexample.org\n');
assert.strictEqual(appendUniqueDomainTextValues(['EXAMPLE.com'], ['example.com', 'example.org']), 'EXAMPLE.com\nexample.org');
assert.strictEqual(appendUniqueDomainTextValues(null, ['example.com']), 'example.com');
console.log('LuCI UCI domain list checks passed');
NODE
