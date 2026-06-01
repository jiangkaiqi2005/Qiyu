export function createDefaultPreferences() {
  return {
    userName: '你',
    sleepTime: '23:00',
    companionshipStyle: 'gentle', // gentle, playful, quiet
    memoryConsent: false,
    onboardingState: 'not started' // not started, in progress, completed, skipped
  };
}

export function loadPreferences(storage) {
  const raw = storage.getItem('qiyu_preferences');
  if (!raw) return createDefaultPreferences();
  try {
    return { ...createDefaultPreferences(), ...JSON.parse(raw) };
  } catch {
    return createDefaultPreferences();
  }
}

export function savePreferences(storage, prefs) {
  storage.setItem('qiyu_preferences', JSON.stringify(prefs));
}
