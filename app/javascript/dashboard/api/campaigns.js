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

  results(id, { page = 1, status = '', q = '' } = {}) {
    return axios.get(`${this.url}/${id}/results`, {
      params: { page, status: status || undefined, q: q || undefined },
    });
  }

  retryFailed(id) {
    return axios.post(`${this.url}/${id}/retry_failed`);
  }
}

export default new CampaignsAPI();
