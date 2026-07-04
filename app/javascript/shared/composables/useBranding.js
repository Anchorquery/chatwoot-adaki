/**
 * Composable for branding-related utilities
 * Provides methods to customize text with installation-specific branding
 */
import { useMapGetter } from 'dashboard/composables/store.js';

const DEFAULT_BRAND = 'Adaki';
// Matches default brand or legacy upstream brand for backward compatibility
const BRAND_REGEX = /Chatwoot|Adaki/g;

export function useBranding() {
  const globalConfig = useMapGetter('globalConfig/get');
  /**
   * Replaces default brand tokens in text with the installation name from global config
   * @param {string} text - The text to process
   * @returns {string} - Text with brand tokens replaced by installation name
   */
  const replaceInstallationName = text => {
    if (!text) return text;

    const installationName =
      globalConfig.value?.installationName || DEFAULT_BRAND;
    if (!installationName) return text;

    return text.replace(BRAND_REGEX, installationName);
  };

  return {
    replaceInstallationName,
  };
}
