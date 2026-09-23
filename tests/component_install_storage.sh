#!/usr/bin/env bash
set -eo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR/trafira/files/usr/lib/components/action.uc" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const source = fs.readFileSync(process.argv[2], 'utf8');
function body(name) {
    const start = source.indexOf('function ' + name + '(');
    assert(start >= 0, 'Missing function ' + name);
    const end = source.indexOf('\nfunction ', start + 1);
    return source.slice(start, end < 0 ? source.indexOf('\nlet mode =', start) : end).trim();
}
const int = x => Math.trunc(Number(x));
const as_string = x => x == null ? '' : String(x);
const match = (s, r) => s.match(r);
const trim = s => s.trim();
const split = (s, sep) => s.split(sep);
eval(body('install_storage_required_bytes'));
eval(body('install_storage_error'));
eval(body('package_install_error_detail'));
const MiB = 1048576;
assert(install_storage_required_bytes('sing_box', 0) >= 32 * MiB);
assert.strictEqual(install_storage_required_bytes('sing_box', 0, 'install_tiny'), 8 * MiB);
assert(install_storage_required_bytes('zapret2', 0) >= 8 * MiB);
assert(install_storage_required_bytes('sing_box', 100 * MiB) >= 104 * MiB);
assert(install_storage_error('/overlay', 0, 8 * MiB).includes('Insufficient free disk space'));
assert(install_storage_error('/overlay', -1, 8 * MiB).includes('Cannot determine'));
assert.strictEqual(install_storage_error('/overlay', 8 * MiB, 8 * MiB), '');
assert(package_install_error_detail('ERROR: failed to extract: No space left on device').includes('No space left on device'));
assert(package_install_error_detail('ERROR: unable to select packages: world[foo]').includes('dependencies'));
assert.strictEqual(package_install_error_detail('password=secret unrelated failure'), '');
const action = body('component_action');
assert(action.indexOf('ensure_install_storage') < action.indexOf('capture_trafira_running_state'));
const compressed = body('install_sing_box_extended');
assert(compressed.indexOf('staged_install_bytes') < compressed.indexOf('stop_trafira_before_sing_box_change'));
const fail = body('fail_package_sing_box_install');
assert(fail.indexOf('package_failure_message') < fail.indexOf('restore_sing_box_after_failed_package_install'));
assert(body('run_logged').includes('capture_install_error'));
assert(body('run_logged').includes('install_failure_detail == ""'));
// Execute the real dispatcher: full disk must fail before service state capture,
// release resolution, bootstrap installation, or any component implementation.
const vm = require('vm');
// An ordinary update of tiny needs the same reserve as explicit tiny install.
// A full unrelated /opt mount must not block sing-box or Trafira.
for (const component of ['sing_box', 'trafira', 'zapret', 'zapret2', 'byedpi']) {
    const checked = [];
    const context = {
        int, install_storage_required_bytes, install_storage_error,
        file_exists: () => true,
        sing_box_runtime_output: () => 'tiny',
        filesystem_available_bytes: path => { checked.push(path); return path === '/opt' ? 0 : 12 * MiB; },
        action_fail: (_component, _action, message) => { throw Error(message); },
    };
    vm.createContext(context);
    vm.runInContext(body('ensure_install_storage').replace('for (let target in ', 'for (let target of '), context);
    if (component === 'sing_box' || component === 'trafira') {
        context.ensure_install_storage(component, 'install', 0);
        assert(!checked.includes('/opt'), component + ' must ignore unrelated /opt');
    } else {
        assert.throws(() => context.ensure_install_storage(component, 'install', 0), /Insufficient free disk space on \/opt/);
    }
}
for (const [component, operation] of [
    ['trafira', 'install'], ['zapret', 'install'], ['zapret2', 'install'],
    ['byedpi', 'install'], ['sing_box', 'install'], ['sing_box', 'install_stable'],
    ['sing_box', 'install_tiny'], ['sing_box', 'install_extended'],
    ['sing_box', 'install_extended_compressed']
]) {
    const calls = [];
    const context = {
        as_string, normalize_component_name: x => x, acquire_component_lock: () => true,
        init_tmp_dir: () => true,
        ensure_install_storage: () => { calls.push('guard'); throw Error('full disk'); },
        capture_trafira_running_state: () => calls.push('service'),
    };
    vm.createContext(context);
    vm.runInContext(body('component_action'), context);
    assert.throws(() => context.component_action(component, operation), /full disk/);
    assert.deepStrictEqual(calls, ['guard'], component + ':' + operation);
}
let install_failure_detail = '';
let output = 'ERROR: No space left on device';
const init_tmp_dir = () => true;
const make_tmp_file = () => '/tmp/test';
const updates_log = () => {};
let command_exit = 1;
const command_status = () => command_exit;
const shell_quote = x => x;
const read_file = () => output;
const remove_file = () => {};
eval(body('run_logged').replace('for (let line in ', 'for (let line of '));
eval(body('run_logged_install'));
eval(body('package_failure_message'));
run_logged('unrelated command', 'fake', false);
assert.strictEqual(install_failure_detail, '', 'unrelated commands do not leak diagnostics');
run_logged_install('install', 'fake');
const firstFailure = package_failure_message('Install failed');
output = 'ERROR: unable to select packages: world[other]';
run_logged_install('rollback', 'fake');
assert.strictEqual(package_failure_message('Install failed'), firstFailure);
command_exit = 0;
run_logged_install('successful fallback', 'fake');
assert.strictEqual(package_failure_message('Health check failed'), 'Health check failed');
assert(firstFailure.includes('ENOSPC'), 'snapshot survives successful fallback or rollback');
console.log('component install storage tests passed');
NODE
