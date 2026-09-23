'use strict';
'require baseclass';
'require fs';
'require uci';
'require ui';

if (typeof structuredClone !== 'function')
  globalThis.structuredClone = (obj) => JSON.parse(JSON.stringify(obj));

export { validateIP } from './validators/validateIp';
export { validateDomain } from './validators/validateDomain';
export { validateDNS } from './validators/validateDns';
export { validateUrl } from './validators/validateUrl';
export { validatePath } from './validators/validatePath';
export { validateSubnet } from './validators/validateSubnet';
export { bulkValidate } from './validators/bulkValidate';
export { validateOutboundJson } from './validators/validateOutboundJson';
export { validateProxyUrl } from './validators/validateProxyUrl';
export { parseValueList } from './helpers/parseValueList';
export { getProxyUrlName } from './helpers/getProxyUrlName';
export { injectGlobalStyles } from './helpers/injectGlobalStyles';
export { showToast } from './helpers/showToast';
export { getClashUIUrl } from './helpers/getClashApiUrl';
export { TrafiraShellMethods } from './trafira/methods/shell';
export { coreService } from './trafira/services/core.service';
export { store } from './trafira/services/store.service';
export { applyUiStateToStore } from './trafira/services/uiState.service';
export { DashboardTab } from './trafira/tabs/dashboard';
export { DiagnosticTab } from './trafira/tabs/diagnostic';
export { MonitoringTab } from './trafira/tabs/monitoring';
export { UpdatesTab } from './trafira/tabs/updates';
export {
  BOOTSTRAP_DNS_SERVER_OPTIONS,
  DEFAULT_LATENCY_TEST_URL,
  DNS_SERVER_OPTIONS,
  DOMAIN_LIST_OPTIONS,
  LATENCY_TEST_URL_OPTIONS,
  TRAFIRA_ACTION_PROVIDERS_AVAILABILITY_EVENT,
  TRAFIRA_UCI_PACKAGE,
} from './constants';
