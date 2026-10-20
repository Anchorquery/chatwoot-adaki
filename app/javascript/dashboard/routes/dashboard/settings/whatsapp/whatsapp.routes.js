import { frontendURL } from '../../../../helper/URLHelper';
import SettingsWrapper from '../SettingsWrapper.vue';
import WhatsappConnectionsIndex from './Index.vue';

export default {
  routes: [
    {
      path: frontendURL('accounts/:accountId/settings/whatsapp'),
      component: SettingsWrapper,
      children: [
        {
          path: '',
          name: 'settings_whatsapp_connections',
          meta: {
            permissions: ['administrator', 'inbox_manage', 'channel_operate'],
          },
          component: WhatsappConnectionsIndex,
        },
      ],
    },
  ],
};
