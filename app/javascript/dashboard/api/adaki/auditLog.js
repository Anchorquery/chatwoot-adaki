/* global axios */
import ApiClient from '../ApiClient';

class AdakiAuditLogAPI extends ApiClient {
  constructor() {
    super('adaki/audit_log_entries', { accountScoped: true });
  }

  verifyChain() {
    return axios.get(`${this.url}/verify`);
  }
}

export default new AdakiAuditLogAPI();
