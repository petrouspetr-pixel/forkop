const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');

// These two ucode functions use the JavaScript-compatible subset. Execute the
// production functions with a worker that completes before launch returns.
const source = fs.readFileSync(path.join(__dirname, '../../trafira/files/usr/lib/components/updates.uc'), 'utf8');
function body(name) {
  const start = source.indexOf(`function ${name}(`);
  assert.ok(start >= 0, name);
  const end = source.indexOf('\nfunction ', start + 1);
  return source.slice(start, end);
}
for (const success of [false, true]) {
  let state;
  let response;
  let writes = 0;
  const ctx = {
    as_string: String,
    job_pid_valid: value => /^[1-9][0-9]*$/.test(value),
    object_or_empty: value => value || {},
    read_json_file: () => structuredClone(state),
    write_state_file: (_path, value) => { state = value; writes++; return true; },
    normalize_component_name: name => name,
    ensure_component_runtime_dirs: () => true,
    component_cleanup_jobs: () => {},
    component_job_id: () => 'test-job',
    component_job_state_path_value: () => '/jobs/test-job.json',
    component_job_output_path: () => '/jobs/test-job.out',
    component_running_job_state_value: () => ({ running: true }),
    now_seconds: () => 100,
    launch_component_worker: () => {
      state = { running: false, success, message: 'Insufficient free space on /overlay' };
      return '1234';
    },
    command_success_from_args: () => { throw new Error('Completed worker must not be killed'); },
    component_job_json_response: (ok, job) => { response = { ok, job }; },
    exit: code => { throw new Error(`Unexpected exit ${code}`); },
  };
  vm.runInNewContext(`${body('set_component_running_job_pid')}\n${body('component_action_async')}\ncomponent_action_async('zapret2', 'install');`, ctx);
  assert.deepEqual(response, { ok: true, job: 'test-job' });
  assert.equal(state.running, false);
  assert.equal(state.success, success);
  assert.equal(state.message, 'Insufficient free space on /overlay');
  assert.equal(writes, 1, 'Parent must never overwrite worker result');
}
console.log('PASS: fast component result survives asynchronous launch');
