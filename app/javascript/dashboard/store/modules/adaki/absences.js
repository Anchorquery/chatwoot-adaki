import * as MutationHelpers from 'shared/helpers/vuex/mutationHelpers';
import types from '../../mutation-types';
import AdakiAbsencesAPI from '../../../api/adaki/absences';
import { throwErrorMessage } from '../../utils/api';

export const state = {
  records: [],
  uiFlags: {
    isFetching: false,
    isCreating: false,
    isUpdating: false,
    isDeleting: false,
  },
};

export const getters = {
  getAbsences(_state) {
    return _state.records;
  },
  getUIFlags(_state) {
    return _state.uiFlags;
  },
};

export const actions = {
  get: async ({ commit }) => {
    commit(types.SET_ADAKI_ABSENCES_UI_FLAG, { isFetching: true });
    try {
      const { data } = await AdakiAbsencesAPI.get();
      commit(types.SET_ADAKI_ABSENCES, data);
    } catch (error) {
      // ignore
    } finally {
      commit(types.SET_ADAKI_ABSENCES_UI_FLAG, { isFetching: false });
    }
  },

  create: async ({ commit }, payload) => {
    commit(types.SET_ADAKI_ABSENCES_UI_FLAG, { isCreating: true });
    try {
      const { data } = await AdakiAbsencesAPI.create({ absence: payload });
      commit(types.ADD_ADAKI_ABSENCE, data);
      return data;
    } catch (error) {
      throwErrorMessage(error);
    } finally {
      commit(types.SET_ADAKI_ABSENCES_UI_FLAG, { isCreating: false });
    }
    return null;
  },

  update: async ({ commit }, { id, ...payload }) => {
    commit(types.SET_ADAKI_ABSENCES_UI_FLAG, { isUpdating: true });
    try {
      const { data } = await AdakiAbsencesAPI.update(id, { absence: payload });
      commit(types.EDIT_ADAKI_ABSENCE, data);
      return data;
    } catch (error) {
      throwErrorMessage(error);
    } finally {
      commit(types.SET_ADAKI_ABSENCES_UI_FLAG, { isUpdating: false });
    }
    return null;
  },

  delete: async ({ commit }, id) => {
    commit(types.SET_ADAKI_ABSENCES_UI_FLAG, { isDeleting: true });
    try {
      await AdakiAbsencesAPI.delete(id);
      commit(types.DELETE_ADAKI_ABSENCE, id);
    } catch (error) {
      throwErrorMessage(error);
    } finally {
      commit(types.SET_ADAKI_ABSENCES_UI_FLAG, { isDeleting: false });
    }
  },
};

export const mutations = {
  [types.SET_ADAKI_ABSENCES_UI_FLAG](_state, data) {
    _state.uiFlags = { ..._state.uiFlags, ...data };
  },
  [types.SET_ADAKI_ABSENCES]: MutationHelpers.set,
  [types.ADD_ADAKI_ABSENCE]: MutationHelpers.create,
  [types.EDIT_ADAKI_ABSENCE]: MutationHelpers.update,
  [types.DELETE_ADAKI_ABSENCE]: MutationHelpers.destroy,
};

export default {
  namespaced: true,
  state,
  getters,
  actions,
  mutations,
};
