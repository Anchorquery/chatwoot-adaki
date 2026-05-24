/* global axios */
import ApiClient from '../ApiClient';

class AdakiCaptainSettingsAPI extends ApiClient {
  constructor() {
    super('adaki/captain_settings', { accountScoped: true });
  }

  show() {
    return axios.get(this.url);
  }

  update(payload) {
    return axios.patch(this.url, payload);
  }
}

export default new AdakiCaptainSettingsAPI();
