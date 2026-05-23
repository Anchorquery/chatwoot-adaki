/* global axios */
import ApiClient from '../ApiClient';

class AdakiAbsencesAPI extends ApiClient {
  constructor() {
    super('adaki/absences', { accountScoped: true });
  }
}

export default new AdakiAbsencesAPI();
