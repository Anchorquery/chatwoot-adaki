import * as MutationHelpers from 'shared/helpers/vuex/mutationHelpers';
import types from '../../mutation-types';
import AdakiWhatsappChannelsAPI from '../../../api/adaki/whatsappChannels';
import { throwErrorMessage } from '../../utils/api';

export const state = {
  channels: [],
  snapshotsByChannel: {},
  uiFlags: {
    isFetching: false,
    isRefreshing: false,
    isUnlocking: false,
    isFetchingSnapshots: false,
  },
};

export const getters = {
  getChannels: _state => _state.channels,
  getSnapshots: _state => channelId => _state.snapshotsByChannel[channelId] || [],
  getUIFlags: _state => _state.uiFlags,
};

export const actions = {
  get: async ({ commit }) => {
    commit(types.SET_ADAKI_TIER_UI_FLAG, { isFetching: true });
    try {
      const { data } = await AdakiWhatsappChannelsAPI.get();
      commit(types.SET_ADAKI_TIER_CHANNELS, data);
    } catch (error) {
      // ignore
    } finally {
      commit(types.SET_ADAKI_TIER_UI_FLAG, { isFetching: false });
    }
  },

  refreshTier: async ({ commit }, channelId) => {
    commit(types.SET_ADAKI_TIER_UI_FLAG, { isRefreshing: true });
    try {
      const { data } = await AdakiWhatsappChannelsAPI.refreshTier(channelId);
      commit(types.EDIT_ADAKI_TIER_CHANNEL, data);
      return data;
    } catch (error) {
      throwErrorMessage(error);
    } finally {
      commit(types.SET_ADAKI_TIER_UI_FLAG, { isRefreshing: false });
    }
    return null;
  },

  unlockTier: async ({ commit }, { channelId, reason }) => {
    commit(types.SET_ADAKI_TIER_UI_FLAG, { isUnlocking: true });
    try {
      const { data } = await AdakiWhatsappChannelsAPI.unlockTier(channelId, reason);
      commit(types.EDIT_ADAKI_TIER_CHANNEL, data);
      return data;
    } catch (error) {
      throwErrorMessage(error);
    } finally {
      commit(types.SET_ADAKI_TIER_UI_FLAG, { isUnlocking: false });
    }
    return null;
  },

  fetchSnapshots: async ({ commit }, channelId) => {
    commit(types.SET_ADAKI_TIER_UI_FLAG, { isFetchingSnapshots: true });
    try {
      const { data } = await AdakiWhatsappChannelsAPI.tierSnapshots(channelId);
      commit(types.SET_ADAKI_TIER_SNAPSHOTS, { channelId, snapshots: data });
    } catch (error) {
      // ignore
    } finally {
      commit(types.SET_ADAKI_TIER_UI_FLAG, { isFetchingSnapshots: false });
    }
  },
};

export const mutations = {
  [types.SET_ADAKI_TIER_UI_FLAG](_state, data) {
    _state.uiFlags = { ..._state.uiFlags, ...data };
  },
  [types.SET_ADAKI_TIER_CHANNELS]: MutationHelpers.set,
  [types.EDIT_ADAKI_TIER_CHANNEL]: MutationHelpers.update,
  [types.SET_ADAKI_TIER_SNAPSHOTS](_state, { channelId, snapshots }) {
    _state.snapshotsByChannel = { ..._state.snapshotsByChannel, [channelId]: snapshots };
  },
};

export default {
  namespaced: true,
  state,
  getters,
  actions,
  mutations,
};
