/* global axios */
import ApiClient from '../ApiClient';

class PlatformCredentialsAPI extends ApiClient {
  constructor() {
    super('captain/platform/credentials', { accountScoped: true });
  }

  index() {
    return axios.get(this.url);
  }

  show(id) {
    return axios.get(`${this.url}/${id}`);
  }

  create(payload) {
    return axios.post(this.url, { credential: payload });
  }

  update(id, payload) {
    return axios.put(`${this.url}/${id}`, { credential: payload });
  }

  destroy(id) {
    return axios.delete(`${this.url}/${id}`);
  }

  validate(id) {
    return axios.post(`${this.url}/${id}/validate`);
  }

  revoke(id) {
    return axios.post(`${this.url}/${id}/revoke`);
  }

  rotate(id, payload) {
    return axios.post(`${this.url}/${id}/rotate`, { credential: payload });
  }
}

export default new PlatformCredentialsAPI();
