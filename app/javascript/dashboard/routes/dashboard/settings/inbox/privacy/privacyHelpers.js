// El filtro puede venir guardado por dos UIs: JID completo desde Chatwoot o
// número pelado desde el Manager de Evolution. Para Evolution son lo mismo
// (compara ambas formas), así que se unifican al JID para no duplicar.
export const normalizeJid = jid => {
  const value = String(jid || '').trim();
  return /^\d{6,}$/.test(value) ? `${value}@s.whatsapp.net` : value;
};

export const jidType = jid => {
  if (jid.endsWith('@g.us')) return 'group';
  if (jid.endsWith('@newsletter')) return 'channel';
  return 'contact';
};

export const phoneFromJid = jid =>
  jid.endsWith('@s.whatsapp.net') ? jid.split('@')[0] : null;

export const sameSelection = (a, b) => {
  if (a.mode !== b.mode) return false;
  if (a.mode === 'all') return true;
  if (a.jids.length !== b.jids.length) return false;
  const set = new Set(a.jids);
  return b.jids.every(jid => set.has(jid));
};
