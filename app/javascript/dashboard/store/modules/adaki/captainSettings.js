import AdakiCaptainSettingsAPI from '../../../api/adaki/captainSettings';
import { throwErrorMessage } from '../../utils/api';

export const state = {
  data: null,
  uiFlags: {
    isFetching: false,
    isUpdating: false,
  },
};

export const getters = {
  getSettings: _state => _state.data,
  getUIFlags: _state => _state.uiFlags,
};

export const actions = {
  fetch: async ({ commit }) => {
    commit('SET_UI_FLAG', { isFetching: true });
    try {
      const { data } = await AdakiCaptainSettingsAPI.show();
      commit('SET_DATA', data);
    } catch (_) {
      // ignore
    } finally {
      commit('SET_UI_FLAG', { isFetching: false });
    }
  },

  update: async ({ commit }, payload) => {
    commit('SET_UI_FLAG', { isUpdating: true });
    try {
      const { data } = await AdakiCaptainSettingsAPI.update(payload);
      commit('SET_DATA', data);
      return data;
    } catch (e) {
      throwErrorMessage(e);
    } finally {
      commit('SET_UI_FLAG', { isUpdating: false });
    }
    return null;
  },
};

export const mutations = {
  SET_UI_FLAG(_state, data) {
    _state.uiFlags = { ..._state.uiFlags, ...data };
  },
  SET_DATA(_state, data) {
    _state.data = data;
  },
};

export default { namespaced: true, state, getters, actions, mutations };
