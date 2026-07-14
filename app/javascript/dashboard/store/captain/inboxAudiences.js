import CaptainInboxAudiences from 'dashboard/api/captain/inboxAudiences';
import { createStore } from '../storeFactory';
import { throwErrorMessage } from 'dashboard/store/utils/api';

export default createStore({
  name: 'CaptainInboxAudience',
  API: CaptainInboxAudiences,
  actions: mutations => ({
    delete: async function remove({ commit }, { id, assistantId }) {
      commit(mutations.SET_UI_FLAG, { deletingItem: true });
      try {
        await CaptainInboxAudiences.delete({ id, assistantId });
        commit(mutations.DELETE, id);
        return id;
      } catch (error) {
        return throwErrorMessage(error);
      } finally {
        commit(mutations.SET_UI_FLAG, { deletingItem: false });
      }
    },
    update: async function update(
      { commit },
      { id, assistantId, groupJids, channelJids, labelTitles }
    ) {
      commit(mutations.SET_UI_FLAG, { updatingItem: true });
      try {
        const response = await CaptainInboxAudiences.update({
          id,
          assistantId,
          groupJids,
          channelJids,
          labelTitles,
        });
        commit(mutations.UPSERT, response.data);
        return response.data;
      } catch (error) {
        return throwErrorMessage(error);
      } finally {
        commit(mutations.SET_UI_FLAG, { updatingItem: false });
      }
    },
  }),
});
