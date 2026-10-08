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

// Nombre comparable; los "nombres" que en realidad son un número o un JID no
// sirven para emparejar.
const nameKey = name => {
  const key = String(name || '')
    .normalize('NFKC')
    .toLowerCase()
    .replace(/\s+/g, ' ')
    .trim();
  if (!key || /^\+?[\d\s]+$/.test(key) || key.includes('@')) return null;
  return key;
};

const uniqueByName = items => {
  const groups = new Map();
  items.forEach(item => {
    const key = nameKey(item.name);
    if (key) groups.set(key, [...(groups.get(key) || []), item]);
  });
  return new Map(
    [...groups]
      .filter(([, group]) => group.length === 1)
      .map(([key, group]) => [key, group[0]])
  );
};

// Misma regla que el backend: un "@lid" sin teléfono y un teléfono con el
// mismo nombre, únicos los dos, son la misma persona. Se muestran en una sola
// fila (el lid pasa a alt_jids); si hay homónimos, no se une nada.
export const pairPrivateIds = items => {
  const lids = uniqueByName(
    items.filter(item => item.jid.endsWith('@lid') && !item.phone)
  );
  const phones = uniqueByName(items.filter(item => item.phone));
  const paired = new Map();
  lids.forEach((lid, key) => {
    const phoneItem = phones.get(key);
    if (phoneItem) paired.set(phoneItem.jid, lid.jid);
  });
  const mergedLids = new Set(paired.values());
  return items
    .filter(item => !mergedLids.has(item.jid))
    .map(item =>
      paired.has(item.jid)
        ? {
            ...item,
            alt_jids: [...(item.alt_jids || []), paired.get(item.jid)],
          }
        : item
    );
};
