import { hasStoredPreferences } from '../qiyu/preferences.js';

export function render(container, context) {
  const storage = window.localStorage;
  const storedPrefs = hasStoredPreferences(storage);

  function navigateTo(path) {
    container.innerHTML = '';
    return context.router.navigate(path);
  }

  if (storedPrefs) {
    return navigateTo('/chat');
  }

  if (typeof fetch !== 'function') {
    return navigateTo('/chat');
  }

  if (window.location.pathname === '/') {
    return fetch('/api/settings')
      .then(res => res.ok ? res.json() : null)
      .then(data => {
        if (data && data.hasLlm === false && window.location.pathname === '/') {
          return navigateTo('/onboarding');
        }
        if (window.location.pathname === '/') {
          return navigateTo('/chat');
        }
        return undefined;
      })
      .catch(() => {
        if (window.location.pathname === '/') {
          return navigateTo('/chat');
        }
        return undefined;
      });
  }

  container.innerHTML = '';
  return undefined;
}
