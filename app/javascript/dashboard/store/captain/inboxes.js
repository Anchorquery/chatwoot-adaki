import CaptainInboxes from 'dashboard/api/captain/inboxes';
import { createStore } from '../storeFactory';
import { throwErrorMessage } from 'dashboard/store/utils/api';

export default createStore({
  name: 'CaptainInbox',
  API: CaptainInboxes,
  actions: mutations => ({
    delete: async function remove({ commit }, { inboxId, assistantId }) {
      commit(mutations.SET_UI_FLAG, { deletingItem: true });
      try {
        await CaptainInboxes.delete({ inboxId, assistantId });
        commit(mutations.DELETE, inboxId);
        commit(mutations.SET_UI_FLAG, { deletingItem: false });
        return inboxId;
      } catch (error) {
        commit(mutations.SET_UI_FLAG, { deletingItem: false });
        return throwErrorMessage(error);
      }
    },
    updateSettings: async function update(
      { commit, state },
      { assistantId, inboxId, settings }
    ) {
      try {
        const response = await CaptainInboxes.updateSettings({
          assistantId,
          inboxId,
          settings,
        });
        const existing = state.records.find(r => r.id === inboxId);
        if (existing) {
          const updated = {
            ...existing,
            captain_inbox: {
              ...(existing.captain_inbox || {}),
              settings: response.data.settings,
            },
          };
          commit(mutations.UPDATE, updated);
        }
        return response.data;
      } catch (error) {
        return throwErrorMessage(error);
      }
    },
  }),
});
