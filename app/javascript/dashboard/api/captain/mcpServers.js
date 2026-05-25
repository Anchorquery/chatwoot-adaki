/* global axios */
import ApiClient from '../ApiClient';

class CaptainMcpServersAPI extends ApiClient {
  constructor() {
    super('captain/mcp_servers', { accountScoped: true });
  }

  get(params = {}) {
    return axios.get(this.url, { params });
  }

  show(id) {
    return axios.get(`${this.url}/${id}`);
  }

  create(data = {}) {
    return axios.post(this.url, { mcp_server: data });
  }

  update(id, data = {}) {
    return axios.put(`${this.url}/${id}`, { mcp_server: data });
  }

  delete(id) {
    return axios.delete(`${this.url}/${id}`);
  }

  test(id) {
    return axios.post(`${this.url}/${id}/test`);
  }

  discover(id) {
    return axios.post(`${this.url}/${id}/discover`);
  }
}

export default new CaptainMcpServersAPI();
