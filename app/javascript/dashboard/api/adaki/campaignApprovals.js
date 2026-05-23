/* global axios */
import ApiClient from '../ApiClient';

class AdakiCampaignApprovalsAPI extends ApiClient {
  constructor() {
    super('campaigns', { accountScoped: true });
  }

  show(campaignId) {
    return axios.get(`${this.url}/${campaignId}/approvals`);
  }

  request(campaignId) {
    return axios.post(`${this.url}/${campaignId}/approvals`);
  }

  approve(campaignId, note = '') {
    return axios.post(`${this.url}/${campaignId}/approvals/approve`, { note });
  }

  reject(campaignId, note = '') {
    return axios.post(`${this.url}/${campaignId}/approvals/reject`, { note });
  }
}

export default new AdakiCampaignApprovalsAPI();
