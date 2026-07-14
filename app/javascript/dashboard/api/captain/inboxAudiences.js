/* global axios */
import ApiClient from '../ApiClient';

class CaptainInboxAudiences extends ApiClient {
  constructor() {
    super('captain/assistants', { accountScoped: true });
  }

  get({ assistantId } = {}) {
    return axios.get(`${this.url}/${assistantId}/inbox_audiences`);
  }

  create(params = {}) {
    const { assistantId, inboxId, groupJids, channelJids, labelTitles } =
      params;
    return axios.post(`${this.url}/${assistantId}/inbox_audiences`, {
      captain_inbox_audience: {
        inbox_id: inboxId,
        group_jids: groupJids,
        channel_jids: channelJids,
        label_titles: labelTitles,
      },
    });
  }

  update(params = {}) {
    const { assistantId, id, groupJids, channelJids, labelTitles } = params;
    return axios.patch(`${this.url}/${assistantId}/inbox_audiences/${id}`, {
      captain_inbox_audience: {
        group_jids: groupJids,
        channel_jids: channelJids,
        label_titles: labelTitles,
      },
    });
  }

  delete(params = {}) {
    const { assistantId, id } = params;
    return axios.delete(`${this.url}/${assistantId}/inbox_audiences/${id}`);
  }
}

export default new CaptainInboxAudiences();
