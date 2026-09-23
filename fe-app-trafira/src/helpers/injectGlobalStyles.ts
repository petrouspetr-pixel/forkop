import { GlobalStyles } from '../styles';

const TRAFIRA_GLOBAL_STYLES_ID = 'trafira-global-styles';

export function injectGlobalStyles() {
  if (document.getElementById(TRAFIRA_GLOBAL_STYLES_ID)) {
    return;
  }

  document.head.insertAdjacentHTML(
    'beforeend',
    `
        <style id="${TRAFIRA_GLOBAL_STYLES_ID}">
          ${GlobalStyles}
        </style>
    `,
  );
}
