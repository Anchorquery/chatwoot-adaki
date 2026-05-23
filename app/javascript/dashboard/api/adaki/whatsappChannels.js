/* global axios */
import ApiClient from '../ApiClient';

class AdakiWhatsappChannelsAPI extends ApiClient {
  constructor() {
    super('adaki/whatsapp_channels', { accountScoped: true });
  }

  refreshTier(channelId) {
    return axios.post(`${this.url}/${channelId}/refresh_tier`);
  }

  unlockTier(channelId, reason = '') {
    return axios.post(`${this.url}/${channelId}/unlock_tier`, { reason });
  }

  tierSnapshots(channelId) {
    return axios.get(`${this.url}/tier_snapshots/${channelId}`);
  }
}

export default new AdakiWhatsappChannelsAPI();
