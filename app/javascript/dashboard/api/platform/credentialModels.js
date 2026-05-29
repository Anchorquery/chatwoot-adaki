/* global axios */
import ApiClient from '../ApiClient';

class PlatformCredentialModelsAPI extends ApiClient {
  constructor() {
    super('captain/platform/credentials', { accountScoped: true });
  }

  baseUrl(credentialId) {
    return `${this.url}/${credentialId}/models`;
  }

  index(credentialId, params = {}) {
    return axios.get(this.baseUrl(credentialId), { params });
  }

  show(credentialId, id) {
    return axios.get(`${this.baseUrl(credentialId)}/${id}`);
  }

  create(credentialId, model) {
    return axios.post(this.baseUrl(credentialId), { model });
  }

  update(credentialId, id, model) {
    return axios.put(`${this.baseUrl(credentialId)}/${id}`, { model });
  }

  destroy(credentialId, id) {
    return axios.delete(`${this.baseUrl(credentialId)}/${id}`);
  }

  toggle(credentialId, id) {
    return axios.post(`${this.baseUrl(credentialId)}/${id}/toggle`);
  }

  sync(credentialId) {
    return axios.post(`${this.baseUrl(credentialId)}/sync`);
  }

  bulkToggle(credentialId, { enabled, kind } = {}) {
    return axios.post(`${this.baseUrl(credentialId)}/bulk_toggle`, { enabled, kind });
  }
}

export default new PlatformCredentialModelsAPI();
