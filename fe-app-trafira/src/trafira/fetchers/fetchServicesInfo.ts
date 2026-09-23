import { TrafiraShellMethods } from '../methods';
import { logger } from '../services/logger.service';
import { store } from '../services/store.service';
import { refreshRuntimeUiState } from '../services/runtimeUiState.service';
import { Trafira } from '../types';

let latestServicesInfoRequestId = 0;

function getSettledMethodResponse<T>(
  scope: string,
  result: PromiseSettledResult<Trafira.MethodResponse<T>>,
): Trafira.MethodResponse<T> {
  if (result.status === 'fulfilled') {
    return result.value;
  }

  logger.error('[SERVICES_INFO]', `${scope} failed`, result.reason);

  return {
    success: false,
    error: result.reason instanceof Error ? result.reason.message : '',
  };
}

export async function fetchServicesInfo() {
  const requestId = ++latestServicesInfoRequestId;
  const uiState = await refreshRuntimeUiState({ force: true });

  if (requestId !== latestServicesInfoRequestId) {
    return;
  }

  if (uiState) {
    return uiState;
  }

  const [trafiraResult, singboxResult] = await Promise.allSettled([
    TrafiraShellMethods.getStatus(),
    TrafiraShellMethods.getSingBoxStatus(),
  ]);

  if (requestId !== latestServicesInfoRequestId) {
    return;
  }

  const trafira = getSettledMethodResponse('getStatus', trafiraResult);
  const singbox = getSettledMethodResponse('getSingBoxStatus', singboxResult);
  const previousData = store.get().servicesInfoWidget.data;

  store.set({
    servicesInfoWidget: {
      loading: false,
      failed: !trafira.success || !singbox.success,
      data: {
        singbox: singbox.success ? singbox.data.running : previousData.singbox,
        trafiraRunning: trafira.success
          ? trafira.data.running
          : previousData.trafiraRunning,
        trafiraEnabled: trafira.success
          ? trafira.data.enabled
          : previousData.trafiraEnabled,
        trafiraStatus: trafira.success
          ? trafira.data.status
          : previousData.trafiraStatus,
      },
    },
  });

  return undefined;
}
