import type { Trafira } from '../../types';

export function shouldApplyCompletedComponentActionResult(
  result: Pick<Trafira.ComponentActionResult, 'action'>,
  notify: boolean,
) {
  return result.action !== 'check_update' || notify;
}
