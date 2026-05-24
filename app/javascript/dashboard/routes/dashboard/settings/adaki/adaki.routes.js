import { frontendURL } from '../../../../helper/URLHelper';
import SettingsWrapper from '../SettingsWrapper.vue';
import AbsencesIndex from './absences/Index.vue';
import TierIndex from './tier/Index.vue';
import AuditIndex from './audit/Index.vue';
import ApprovalsIndex from './approvals/Index.vue';
import CaptainIndex from './captain/Index.vue';

const meta = {
  permissions: ['administrator'],
};

export default {
  routes: [
    {
      path: frontendURL('accounts/:accountId/settings/adaki'),
      component: SettingsWrapper,
      children: [
        {
          path: '',
          name: 'adaki_settings_wrapper',
          meta,
          redirect: to => ({ name: 'adaki_absences_list', params: to.params }),
        },
        {
          path: 'absences',
          name: 'adaki_absences_list',
          meta,
          component: AbsencesIndex,
        },
        {
          path: 'tier',
          name: 'adaki_tier_list',
          meta,
          component: TierIndex,
        },
        {
          path: 'audit',
          name: 'adaki_audit_list',
          meta,
          component: AuditIndex,
        },
        {
          path: 'approvals',
          name: 'adaki_approvals_list',
          meta,
          component: ApprovalsIndex,
        },
        {
          path: 'captain',
          name: 'adaki_captain_settings',
          meta,
          component: CaptainIndex,
        },
      ],
    },
  ],
};
