import * as MutationHelpers from 'shared/helpers/vuex/mutationHelpers';
import types from '../../mutation-types';
import AdakiAuditLogAPI from '../../../api/adaki/auditLog';

export const state = {
  records: [],
  verifyResult: null,
  uiFlags: {
    isFetching: false,
    isVerifying: false,
  },
};

export const getters = {
  getEntries: _state => _state.records,
  getVerifyResult: _state => _state.verifyResult,
  getUIFlags: _state => _state.uiFlags,
};

export const actions = {
  get: async ({ commit }) => {
    commit(types.SET_ADAKI_AUDIT_UI_FLAG, { isFetching: true });
    try {
      const { data } = await AdakiAuditLogAPI.get();
      commit(types.SET_ADAKI_AUDIT_ENTRIES, data);
    } catch (error) {
      // ignore
    } finally {
      commit(types.SET_ADAKI_AUDIT_UI_FLAG, { isFetching: false });
    }
  },

  verify: async ({ commit }) => {
    commit(types.SET_ADAKI_AUDIT_UI_FLAG, { isVerifying: true });
    try {
      const { data } = await AdakiAuditLogAPI.verifyChain();
      commit(types.SET_ADAKI_AUDIT_VERIFY, data);
      return data;
    } catch (error) {
      commit(types.SET_ADAKI_AUDIT_VERIFY, { valid: false, error: error.message });
    } finally {
      commit(types.SET_ADAKI_AUDIT_UI_FLAG, { isVerifying: false });
    }
    return null;
  },
};

export const mutations = {
  [types.SET_ADAKI_AUDIT_UI_FLAG](_state, data) {
    _state.uiFlags = { ..._state.uiFlags, ...data };
  },
  [types.SET_ADAKI_AUDIT_ENTRIES]: MutationHelpers.set,
  [types.SET_ADAKI_AUDIT_VERIFY](_state, result) {
    _state.verifyResult = result;
  },
};

export default {
  namespaced: true,
  state,
  getters,
  actions,
  mutations,
};
