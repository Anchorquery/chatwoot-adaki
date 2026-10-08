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

  updateEvolutionPrivacyFilter(inboxId, { mode, jids, labels }) {
    return axios.post(
      `${this.url}/${inboxId}/evolution_update_privacy_filter`,
      {
        mode,
        jids,
        labels,
      }
    );
  }

  searchEvolutionPrivacy(inboxId, { q, type, page }) {
    return axios.get(`${this.url}/${inboxId}/evolution_privacy_search`, {
      params: { q, type, page },
    });
  }

  resolveEvolutionPrivacy(inboxId, jids) {
    return axios.post(`${this.url}/${inboxId}/evolution_privacy_resolve`, {
      jids,
    });
  }

  getEvolutionPrivacyContact(inboxId, contactId) {
    return axios.get(`${this.url}/${inboxId}/evolution_privacy_contact`, {
      params: { contact_id: contactId },
    });
  }

  updateEvolutionPrivacyContact(inboxId, contactId, filtered) {
    return axios.post(
      `${this.url}/${inboxId}/evolution_update_privacy_contact`,
      { contact_id: contactId, filtered }
    );
  }

  createEvolutionInbox(name) {
    return axios.post(`${this.url}/evolution_create`, { name });
  }

  getEvolutionConnectionState(inboxId) {
    return axios.get(`${this.url}/${inboxId}/evolution_connection_state`);
  }

  connectEvolution(inboxId) {
    return axios.post(`${this.url}/${inboxId}/evolution_connect`);
  }

  logoutEvolution(inboxId) {
    return axios.post(`${this.url}/${inboxId}/evolution_logout`);
  }

  restartEvolution(inboxId) {
    return axios.post(`${this.url}/${inboxId}/evolution_restart`);
  }

  getEvolutionInstanceSettings(inboxId) {
    return axios.get(`${this.url}/${inboxId}/evolution_instance_settings`);
  }

  updateEvolutionInstanceSettings(inboxId, settings) {
    return axios.post(
      `${this.url}/${inboxId}/evolution_update_instance_settings`,
      settings
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
