import { Trafira } from '../../types';
import { TRAFIRA_UCI_PACKAGE } from '../../../constants';

export async function getConfigSections(): Promise<Trafira.ConfigSection[]> {
  return uci
    .load(TRAFIRA_UCI_PACKAGE)
    .then(() => uci.sections(TRAFIRA_UCI_PACKAGE));
}
