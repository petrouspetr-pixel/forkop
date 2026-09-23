const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const library = path.resolve(__dirname, '../../trafira/files/usr/lib');
const work = fs.mkdtempSync(path.join(os.tmpdir(), 'trafira-prune-generator-'));
try {
  const subscriptions = path.join(work, 'subscriptions');
  fs.mkdirSync(subscriptions);
  const source = path.join(subscriptions, 'proxy-subscription-1');
  const subscription = JSON.stringify({ outbounds: ['Alpha', 'Beta'].map(tag => ({
    type: 'vless', tag, server: tag.toLowerCase() + '.example', server_port: 443,
    uuid: '00000000-0000-4000-8000-000000000001', tls: { enabled: true }
  })) });
  fs.writeFileSync(source + '.json', subscription);
  fs.writeFileSync(source + '.url', 'https://subscription.example/test\n');
  fs.writeFileSync(source + '.user_agent', '');
  const fixturePath = path.join(work, 'fixture.json');
  const output = path.join(work, 'config.json');
  fs.mkdirSync(output + '.section-cache');

  // Reuse the same source and section cache: the second run must restore a
  // previously pruned server, not reuse an irreversibly filtered subscription.
  for (const selected of ['Alpha', 'Beta']) {
    const excluded = selected === 'Alpha' ? 'Beta' : 'Alpha';
    const fixture = {
      settings: { '.name': 'settings', '.type': 'settings', log_level: 'warn' },
      section: [{
        '.name': 'proxy', '.type': 'section', enabled: '1', action: 'connection',
        subscription_urls: ['https://subscription.example/test'],
        dashboard_filter_mode: 'include', dashboard_include_outbounds: [selected]
      }]
    };
    fs.writeFileSync(fixturePath, JSON.stringify(fixture));
    const result = spawnSync('ucode', ['-L', library, path.join(library, 'singbox/generator.uc'), 'generate-config-fixture', fixturePath, output, '127.0.0.1'], {
      env: { ...process.env, TMP_SUBSCRIPTION_FOLDER: subscriptions }, encoding: 'utf8'
    });
    assert.equal(result.status, 0, result.stderr || String(result.error));
    const config = JSON.parse(fs.readFileSync(output, 'utf8'));
    const cache = JSON.parse(fs.readFileSync(path.join(output + '.section-cache', 'proxy.json'), 'utf8'));
    assert(config.outbounds.some(outbound => outbound.tag === selected), 'selected subscription must remain');
    assert(!config.outbounds.some(outbound => outbound.tag === excluded), 'excluded subscription must be pruned by generator');
    const selector = config.outbounds.find(outbound => outbound.tag === 'proxy-out');
    assert(selector, 'section selector must remain');
    assert.deepEqual(selector.outbounds, [selected]);
    assert.deepEqual(cache.urltestCandidateTags, [selected]);
    assert.equal(cache.outboundMetadata.names[selected], selected);
    assert.equal(cache.servers[selected], selected.toLowerCase() + '.example');
    for (const map of [cache.links, cache.servers, ...Object.values(cache.outboundMetadata)]) {
      assert.equal(map[excluded], undefined, 'excluded metadata must be pruned before cache write');
    }
    assert.equal(fs.readFileSync(source + '.json', 'utf8'), subscription, 'source cache must remain untouched');
  }
  console.log('subscription pruning generator integration: passed');
} finally {
  fs.rmSync(work, { recursive: true, force: true });
}
