/* global axios */

import ApiClient from './ApiClient';

class CampaignsAPI extends ApiClient {
  constructor() {
    super('campaigns', { accountScoped: true });
  }

  aiGenerate(data) {
    return axios.post(`${this.url}/ai_generate`, data);
  }

  clone(id) {
    return axios.post(`${this.url}/${id}/clone`);
  }
}

export default new CampaignsAPI();
