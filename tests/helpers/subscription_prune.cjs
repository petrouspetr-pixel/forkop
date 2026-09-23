const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { spawnSync } = require('node:child_process');

const library = path.resolve(__dirname, '../../trafira/files/usr/lib');
const source = fs.readFileSync(path.join(library, 'singbox/prune.uc'), 'utf8');
let implementation;
if (process.argv.includes('--ucode')) {
  implementation = input => {
    const script = 'let p=require("singbox.prune"); let i=json(getenv("TEST_PRUNE_INPUT")); let removed=p.prune_config(i.config,i.sources); p.prune_state(i.state,removed); print(sprintf("%J",i));';
    const run = spawnSync('ucode', ['-L', library, '-e', script], { env: { ...process.env, TEST_PRUNE_INPUT: JSON.stringify(input) }, encoding: 'utf8' });
    assert.equal(run.status, 0, run.stderr || String(run.error));
    return JSON.parse(run.stdout);
  };
} else {
  // Local Windows check runs the production functions with ucode primitives.
  // CI above executes the same cases through the real ucode module loader.
  const context = {
    type: x => Array.isArray(x) ? 'array' : x === null ? 'null' : typeof x,
    keys: Object.keys,
    push: (a, x) => a.push(x),
    length: x => x.length,
  };
  vm.createContext(context);
  const executable = source.replace(/^#!.*\n/, '').replace(/for \(let (\w+) in (.*)\) \{/g, 'for (let $1 of $2) {');
  implementation = input => {
    context.input = structuredClone(input);
    vm.runInContext('(function(){' + executable.replace(/return \{ prune_config, prune_state \};\s*$/, '') + '\nlet removed=prune_config(input.config,input.sources); prune_state(input.state,removed); })()', context);
    return JSON.parse(JSON.stringify(context.input));
  };
}

function proxy(tag, detour) { return { type: 'vless', tag, ...(detour ? { detour } : {}) }; }
function check(config, sourceTags, retained) {
  const all = config.outbounds.map(o => o.tag);
  const values = Object.fromEntries(all.map(tag => [tag, tag]));
  const state = {
    links: { ...values }, servers: { ...values },
    outboundMetadata: Object.fromEntries(['names', 'countries', 'protocols', 'transports', 'securities'].map(key => [key, { ...values }])),
    urltestCandidateTags: [...all],
    urltestGroups: { stale: { outbounds: ['stale', ...retained] }, dashboard: { outbounds: [...all] } },
    priorityGroups: { priority: { outbounds: [...all], levels: [{ outbounds: [...all] }] } },
    subscriptionMetadata: [{ sourceIndex: 1, upload: 5 }]
  };
  const input = { config, state, sources: Object.fromEntries(sourceTags.map(tag => [tag, true])) };
  const result = implementation(input);
  assert.deepEqual(result.config.outbounds.map(o => o.tag).sort(), [...retained].sort());
  const removed = all.filter(tag => !retained.includes(tag));
  for (const map of [result.state.links, result.state.servers, ...Object.values(result.state.outboundMetadata)]) {
    for (const tag of removed) assert.equal(map[tag], undefined, 'removed metadata ' + tag);
    for (const tag of retained) assert.equal(map[tag], tag, 'retained metadata ' + tag);
  }
  assert.deepEqual(result.state.urltestCandidateTags, all.filter(tag => retained.includes(tag)));
  assert.deepEqual(result.state.urltestGroups.dashboard.outbounds, result.state.urltestCandidateTags);
  assert.deepEqual(result.state.priorityGroups.priority.outbounds, result.state.urltestCandidateTags);
  assert.deepEqual(result.state.priorityGroups.priority.levels[0].outbounds, result.state.urltestCandidateTags);
  if (removed.includes('stale')) assert.equal(result.state.urltestGroups.stale, undefined);
  assert.deepEqual(result.state.subscriptionMetadata, state.subscriptionMetadata);
  // Idempotent and does not mutate persistent source documents.
  assert.deepEqual(implementation(result), result);
  return result;
}

check({ outbounds: [proxy('manual'), proxy('interface'), proxy('direct'), proxy('stale'), proxy('selected'), { type: 'selector', tag: 'section', outbounds: ['selected'] }] }, ['stale', 'selected'], ['manual', 'interface', 'direct', 'selected', 'section']);
check({ outbounds: [proxy('stale'), proxy('hidden'), proxy('relay'), proxy('selected', 'hidden'), { type: 'selector', tag: 'section', outbounds: ['selected'] }] .map(o => o.tag === 'hidden' ? { ...o, detour: 'relay' } : o) }, ['stale', 'hidden', 'relay', 'selected'], ['hidden', 'relay', 'selected', 'section']);
for (const type of ['urltest', 'selector', 'fallback']) {
  check({ outbounds: [proxy('stale'), proxy('member'), { type, tag: 'generated-group', outbounds: ['member'] }] }, ['stale', 'member'], ['member', 'generated-group']);
}
check({ outbounds: [proxy('stale'), proxy('member'), { type: 'urltest', tag: 'unused-imported-group', outbounds: ['stale'] }, { type: 'urltest', tag: 'imported-group', outbounds: ['member'] }, { type: 'selector', tag: 'section', outbounds: ['imported-group'] }] }, ['stale', 'member', 'unused-imported-group', 'imported-group'], ['member', 'imported-group', 'section']);
check({ outbounds: [proxy('stale'), proxy('nested'), proxy('final'), proxy('dns'), proxy('endpoint'), proxy('download')], route: { final: 'final', rules: [{ type: 'logical', rules: [{ type: 'logical', rules: [{ outbound: 'nested' }] }] }], rule_set: [{ download_detour: 'download' }] }, dns: { servers: [{ detour: 'dns' }] }, endpoints: [{ type: 'wireguard', tag: 'ep', detour: 'endpoint' }] }, ['stale', 'nested', 'final', 'dns', 'endpoint', 'download'], ['nested', 'final', 'dns', 'endpoint', 'download']);
check({ outbounds: [proxy('stale', 'dead-cycle'), proxy('dead-cycle', 'stale'), proxy('live', 'live-cycle'), proxy('live-cycle', 'live'), { type: 'selector', tag: 'section', outbounds: ['live'] }] }, ['stale', 'dead-cycle', 'live', 'live-cycle'], ['live', 'live-cycle', 'section']);
check({ outbounds: [proxy('stale'), proxy('selected'), { type: 'selector', tag: 'manual-default', default: 'selected', outbounds: [] }] }, ['stale', 'selected'], ['selected', 'manual-default']);
// Fresh generation starts from the original subscription, so a filter change can restore any server.
for (const selected of ['first', 'second']) {
  check({ outbounds: [proxy('first'), proxy('second'), { type: 'selector', tag: 'section', outbounds: [selected] }] }, ['first', 'second'], [selected, 'section']);
}
console.log('subscription outbound pruning: passed');
