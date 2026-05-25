import CaptainMcpServersAPI from 'dashboard/api/captain/mcpServers';
import { createStore } from '../storeFactory';
import { throwErrorMessage } from 'dashboard/store/utils/api';

export default createStore({
  name: 'CaptainMcpServer',
  API: CaptainMcpServersAPI,
  actions: mutations => ({
    test: async ({ commit }, id) => {
      commit(mutations.SET_UI_FLAG, { fetchingItem: true });
      try {
        const response = await CaptainMcpServersAPI.test(id);
        return response.data;
      } catch (error) {
        return throwErrorMessage(error);
      } finally {
        commit(mutations.SET_UI_FLAG, { fetchingItem: false });
      }
    },

    discover: async ({ commit }, id) => {
      commit(mutations.SET_UI_FLAG, { fetchingItem: true });
      try {
        const response = await CaptainMcpServersAPI.discover(id);
        const record = response.data.payload || response.data;
        commit(mutations.EDIT, record);
        return record;
      } catch (error) {
        return throwErrorMessage(error);
      } finally {
        commit(mutations.SET_UI_FLAG, { fetchingItem: false });
      }
    },
  }),
});
