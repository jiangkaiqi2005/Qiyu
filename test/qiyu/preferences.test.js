import test from 'node:test';
import assert from 'node:assert/strict';
import {
  createDefaultPreferences,
  loadPreferences,
  savePreferences
} from '../../src/qiyu/preferences.js';

test('preferences utility default values and save/load', () => {
  const store = {};
  const mockStorage = {
    getItem(key) {
      return store[key] || null;
    },
    setItem(key, val) {
      store[key] = val;
    }
  };

  const defaults = createDefaultPreferences();
  assert.equal(defaults.userName, '你');
  assert.equal(defaults.companionshipStyle, 'gentle');
  assert.equal(defaults.onboardingState, 'not started');

  // Load from empty
  const loadedEmpty = loadPreferences(mockStorage);
  assert.equal(loadedEmpty.userName, '你');

  // Save custom preferences
  const custom = {
    userName: '小雨',
    sleepTime: '22:30',
    companionshipStyle: 'playful',
    memoryConsent: true,
    onboardingState: 'completed'
  };

  savePreferences(mockStorage, custom);
  assert.match(store['qiyu_preferences'], /小雨/);

  const loadedCustom = loadPreferences(mockStorage);
  assert.equal(loadedCustom.userName, '小雨');
  assert.equal(loadedCustom.companionshipStyle, 'playful');
  assert.equal(loadedCustom.onboardingState, 'completed');
});
