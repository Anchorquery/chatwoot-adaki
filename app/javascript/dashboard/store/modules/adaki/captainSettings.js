import AdakiCaptainSettingsAPI from '../../../api/adaki/captainSettings';
import PlatformCredentialsAPI from '../../../api/platform/credentials';
import { throwErrorMessage } from '../../utils/api';

export const state = {
  data: null,
  credentials: [],
  uiFlags: {
    isFetching: false,
    isUpdating: false,
    isFetchingCredentials: false,
    isSavingCredential: false,
  },
};

export const getters = {
  getSettings: _state => _state.data,
  getCredentials: _state => _state.credentials,
  getUIFlags: _state => _state.uiFlags,
};

export const actions = {
  fetch: async ({ commit }) => {
    commit('SET_UI_FLAG', { isFetching: true });
    try {
      const { data } = await AdakiCaptainSettingsAPI.show();
      commit('SET_DATA', data);
      commit('SET_CREDENTIALS', data.credentials || []);
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
      commit('SET_CREDENTIALS', data.credentials || []);
      return data;
    } catch (e) {
      throwErrorMessage(e);
    } finally {
      commit('SET_UI_FLAG', { isUpdating: false });
    }
    return null;
  },

  fetchCredentials: async ({ commit }) => {
    commit('SET_UI_FLAG', { isFetchingCredentials: true });
    try {
      const { data } = await PlatformCredentialsAPI.index();
      commit('SET_CREDENTIALS', data || []);
    } catch (e) {
      throwErrorMessage(e);
    } finally {
      commit('SET_UI_FLAG', { isFetchingCredentials: false });
    }
  },

  createCredential: async ({ commit, dispatch }, payload) => {
    commit('SET_UI_FLAG', { isSavingCredential: true });
    try {
      const { data } = await PlatformCredentialsAPI.create(payload);
      await dispatch('fetch');
      return data;
    } catch (e) {
      throwErrorMessage(e);
    } finally {
      commit('SET_UI_FLAG', { isSavingCredential: false });
    }
    return null;
  },

  updateCredential: async ({ commit, dispatch }, { id, payload }) => {
    commit('SET_UI_FLAG', { isSavingCredential: true });
    try {
      const { data } = await PlatformCredentialsAPI.update(id, payload);
      await dispatch('fetch');
      return data;
    } catch (e) {
      throwErrorMessage(e);
    } finally {
      commit('SET_UI_FLAG', { isSavingCredential: false });
    }
    return null;
  },

  destroyCredential: async ({ dispatch }, id) => {
    await PlatformCredentialsAPI.destroy(id);
    await dispatch('fetch');
  },

  validateCredential: async ({ dispatch }, id) => {
    await PlatformCredentialsAPI.validate(id);
    await dispatch('fetch');
  },

  revokeCredential: async ({ dispatch }, id) => {
    await PlatformCredentialsAPI.revoke(id);
    await dispatch('fetch');
  },
};

export const mutations = {
  SET_UI_FLAG(_state, data) {
    _state.uiFlags = { ..._state.uiFlags, ...data };
  },
  SET_DATA(_state, data) {
    _state.data = data;
  },
  SET_CREDENTIALS(_state, credentials) {
    _state.credentials = credentials;
  },
};

export default { namespaced: true, state, getters, actions, mutations };
