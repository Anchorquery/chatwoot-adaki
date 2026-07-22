/* global axios */
import CacheEnabledApiClient from './CacheEnabledApiClient';

class Inboxes extends CacheEnabledApiClient {
  constructor() {
    super('inboxes', { accountScoped: true });
  }

  // eslint-disable-next-line class-methods-use-this
  get cacheModelName() {
    return 'inbox';
  }

  getCampaigns(inboxId) {
    return axios.get(`${this.url}/${inboxId}/campaigns`);
  }

  deleteInboxAvatar(inboxId) {
    return axios.delete(`${this.url}/${inboxId}/avatar`);
  }

  getAgentBot(inboxId) {
    return axios.get(`${this.url}/${inboxId}/agent_bot`);
  }

  getEvolutionAudienceOptions(inboxId) {
    return axios.get(`${this.url}/${inboxId}/evolution_audience_options`);
  }

  testEvolutionConnection(inboxId) {
    return axios.post(`${this.url}/${inboxId}/evolution_test_connection`);
  }

  getEvolutionPrivacyFilter(inboxId) {
    return axios.get(`${this.url}/${inboxId}/evolution_privacy_filter`);
  }

  updateEvolutionPrivacyFilter(inboxId, { mode, jids }) {
    return axios.post(
      `${this.url}/${inboxId}/evolution_update_privacy_filter`,
      {
        mode,
        jids,
      }
    );
  }

  setAgentBot(inboxId, botId) {
    return axios.post(`${this.url}/${inboxId}/set_agent_bot`, {
      agent_bot: botId,
    });
  }

  syncTemplates(inboxId) {
    return axios.post(`${this.url}/${inboxId}/sync_templates`);
  }

  createCSATTemplate(inboxId, template) {
    return axios.post(`${this.url}/${inboxId}/csat_template`, {
      template,
    });
  }

  getCSATTemplateStatus(inboxId) {
    return axios.get(`${this.url}/${inboxId}/csat_template`);
  }

  analyzeCSATTemplateUtility(inboxId, template) {
    return axios.post(`${this.url}/${inboxId}/csat_template/analyze`, {
      template,
    });
  }

  resetSecret(inboxId) {
    return axios.post(`${this.url}/${inboxId}/reset_secret`);
  }
}

export default new Inboxes();
