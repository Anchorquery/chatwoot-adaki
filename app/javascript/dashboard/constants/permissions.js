// Permissions a custom role can be given, grouped by the section of the app
// they open. Keep in sync with CustomRole::PERMISSION_GROUPS.
export const CUSTOM_ROLE_PERMISSION_GROUPS = [
  {
    key: 'conversations',
    permissions: [
      'conversation_manage',
      'conversation_unassigned_manage',
      'conversation_participating_manage',
      'macro_manage',
    ],
  },
  { key: 'contacts', permissions: ['contact_manage'] },
  { key: 'campaigns', permissions: ['campaign_manage', 'campaign_approve'] },
  { key: 'channels', permissions: ['inbox_manage', 'channel_operate'] },
  { key: 'captain', permissions: ['captain_manage'] },
  {
    key: 'team',
    permissions: [
      'agent_manage',
      'team_manage',
      'label_manage',
      'assignment_manage',
      'absence_manage',
    ],
  },
  {
    key: 'customization',
    permissions: [
      'automation_manage',
      'attribute_manage',
      'agent_bot_manage',
      'sla_manage',
    ],
  },
  { key: 'integrations', permissions: ['integration_manage'] },
  { key: 'reports', permissions: ['report_manage'] },
  { key: 'knowledge_base', permissions: ['knowledge_base_manage'] },
  {
    key: 'account',
    permissions: ['account_settings_manage', 'audit_log_view'],
  },
];

export const AVAILABLE_CUSTOM_ROLE_PERMISSIONS =
  CUSTOM_ROLE_PERMISSION_GROUPS.flatMap(group => group.permissions);

// One-click sets of permissions. Keep in sync with CustomRole::PRESETS.
export const CUSTOM_ROLE_PRESETS = {
  communication: [
    'conversation_manage',
    'contact_manage',
    'campaign_manage',
    'channel_operate',
  ],
  ai_agent: [
    'conversation_manage',
    'captain_manage',
    'inbox_manage',
    'agent_manage',
    'team_manage',
    'label_manage',
    'assignment_manage',
  ],
};

export const ROLES = ['agent', 'administrator'];

export const CONVERSATION_PERMISSIONS = [
  'conversation_manage',
  'conversation_unassigned_manage',
  'conversation_participating_manage',
];

export const MANAGE_ALL_CONVERSATION_PERMISSIONS = 'conversation_manage';

export const CONVERSATION_UNASSIGNED_PERMISSIONS =
  'conversation_unassigned_manage';

export const CONVERSATION_PARTICIPATING_PERMISSIONS =
  'conversation_participating_manage';

export const CONTACT_PERMISSIONS = 'contact_manage';

export const REPORTS_PERMISSIONS = 'report_manage';

export const PORTAL_PERMISSIONS = 'knowledge_base_manage';

export const ASSIGNEE_TYPE_TAB_PERMISSIONS = {
  me: {
    count: 'mineCount',
    permissions: [...ROLES, ...CONVERSATION_PERMISSIONS],
  },
  unassigned: {
    count: 'unAssignedCount',
    permissions: [
      ...ROLES,
      MANAGE_ALL_CONVERSATION_PERMISSIONS,
      CONVERSATION_UNASSIGNED_PERMISSIONS,
    ],
  },
  all: {
    count: 'allCount',
    permissions: [
      ...ROLES,
      MANAGE_ALL_CONVERSATION_PERMISSIONS,
      CONVERSATION_PARTICIPATING_PERMISSIONS,
    ],
  },
};
