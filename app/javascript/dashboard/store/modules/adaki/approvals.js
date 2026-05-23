import AdakiCampaignApprovalsAPI from '../../../api/adaki/campaignApprovals';
import { throwErrorMessage } from '../../utils/api';

export const state = {
  byCampaign: {},
  uiFlags: {
    isFetching: false,
    isRequesting: false,
    isApproving: false,
    isRejecting: false,
  },
};

export const getters = {
  forCampaign: _state => campaignId => _state.byCampaign[campaignId] || [],
  getUIFlags: _state => _state.uiFlags,
};

export const actions = {
  fetch: async ({ commit }, campaignId) => {
    commit('SET_UI_FLAG', { isFetching: true });
    try {
      const { data } = await AdakiCampaignApprovalsAPI.show(campaignId);
      commit('SET_FOR_CAMPAIGN', { campaignId, data });
    } catch (e) {
      // ignore
    } finally {
      commit('SET_UI_FLAG', { isFetching: false });
    }
  },

  request: async ({ commit, dispatch }, campaignId) => {
    commit('SET_UI_FLAG', { isRequesting: true });
    try {
      await AdakiCampaignApprovalsAPI.request(campaignId);
      await dispatch('fetch', campaignId);
    } catch (e) {
      throwErrorMessage(e);
    } finally {
      commit('SET_UI_FLAG', { isRequesting: false });
    }
  },

  approve: async ({ commit, dispatch }, { campaignId, note }) => {
    commit('SET_UI_FLAG', { isApproving: true });
    try {
      await AdakiCampaignApprovalsAPI.approve(campaignId, note);
      await dispatch('fetch', campaignId);
    } catch (e) {
      throwErrorMessage(e);
    } finally {
      commit('SET_UI_FLAG', { isApproving: false });
    }
  },

  reject: async ({ commit, dispatch }, { campaignId, note }) => {
    commit('SET_UI_FLAG', { isRejecting: true });
    try {
      await AdakiCampaignApprovalsAPI.reject(campaignId, note);
      await dispatch('fetch', campaignId);
    } catch (e) {
      throwErrorMessage(e);
    } finally {
      commit('SET_UI_FLAG', { isRejecting: false });
    }
  },
};

export const mutations = {
  SET_UI_FLAG(_state, data) {
    _state.uiFlags = { ..._state.uiFlags, ...data };
  },
  SET_FOR_CAMPAIGN(_state, { campaignId, data }) {
    _state.byCampaign = { ..._state.byCampaign, [campaignId]: data };
  },
};

export default { namespaced: true, state, getters, actions, mutations };
