/* global axios */
import ApiClient from '../ApiClient';

class PlatformCredentialModelsAPI extends ApiClient {
  constructor() {
    super('captain/platform/credentials', { accountScoped: true });
  }

  // NOTE: do NOT name this `baseUrl` — that collides with ApiClient#baseUrl()
  // which the `url` getter calls, producing infinite recursion.
  modelsUrl(credentialId) {
    return `${this.url}/${credentialId}/models`;
  }

  index(credentialId, params = {}) {
    return axios.get(this.modelsUrl(credentialId), { params });
  }

  show(credentialId, id) {
    return axios.get(`${this.modelsUrl(credentialId)}/${id}`);
  }

  create(credentialId, model) {
    return axios.post(this.modelsUrl(credentialId), { model });
  }

  update(credentialId, id, model) {
    return axios.put(`${this.modelsUrl(credentialId)}/${id}`, { model });
  }

  destroy(credentialId, id) {
    return axios.delete(`${this.modelsUrl(credentialId)}/${id}`);
  }

  toggle(credentialId, id) {
    return axios.post(`${this.modelsUrl(credentialId)}/${id}/toggle`);
  }

  sync(credentialId) {
    return axios.post(`${this.modelsUrl(credentialId)}/sync`);
  }

  bulkToggle(credentialId, { enabled, kind } = {}) {
    return axios.post(`${this.modelsUrl(credentialId)}/bulk_toggle`, { enabled, kind });
  }
}

export default new PlatformCredentialModelsAPI();
