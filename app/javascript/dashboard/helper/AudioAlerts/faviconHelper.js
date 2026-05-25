const brandedFavicon = () =>
  window.globalConfig?.LOGO_THUMBNAIL || '/brand-assets/logo_thumbnail.svg';

export const showBadgeOnFavicon = () => {
  const favicons = document.querySelectorAll('.favicon');

  favicons.forEach(favicon => {
    favicon.href = brandedFavicon();
  });
};

export const initFaviconSwitcher = () => {
  const favicons = document.querySelectorAll('.favicon');

  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible') {
      favicons.forEach(favicon => {
        favicon.href = brandedFavicon();
      });
    }
  });
};
