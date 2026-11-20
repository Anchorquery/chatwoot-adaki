// Destinatarios de una campaña API además de las etiquetas. El backend los
// resuelve en Campaigns::DirectAudienceService; estas reglas son las mismas que
// Campaigns::DirectAudienceService.normalize_phone para que el recuento y la
// comprobación de WhatsApp coincidan con lo que se envía.

const MIN_DIGITS = 8;

// Sin prefijo se asume España: 9 cifras que empiezan por 6, 7, 8 o 9.
export const normalizePhone = value => {
  let digits = String(value || '').replace(/[^\d+]/g, '');
  digits = digits.replace(/^00/, '+');
  if (/^[6789]\d{8}$/.test(digits)) digits = `+34${digits}`;
  if (!digits.startsWith('+')) digits = `+${digits}`;
  return /^\+[1-9]\d{7,14}$/.test(digits) ? digits : null;
};

const digitCount = value => String(value).replace(/\D/g, '').length;
const hasLetters = value => /\p{L}/u.test(value);

// "nombre;teléfono", "teléfono;nombre", "nombre<TAB>teléfono" o
// "nombre,teléfono" (como sale de una hoja de cálculo) dan un número con
// nombre. Cualquier otra coma separa varios números en la misma línea.
const parseLine = line => {
  const named = line.split(/[;\t]/).map(part => part.trim());
  const commaParts = line.split(',').map(part => part.trim());
  let parts = [line.trim()];
  if (named.length >= 2) parts = named;
  else if (commaParts.length === 2 && commaParts.some(hasLetters))
    parts = commaParts;
  else return commaParts.map(raw => ({ raw, name: '' }));

  const raw = parts.find(part => digitCount(part) >= MIN_DIGITS) || '';
  const name = parts.find(part => part !== raw && hasLetters(part)) || '';
  return [{ raw, name }];
};

// Cada entrada: { raw, phone (E.164 o null), name }. Los repetidos se quedan
// una vez, con el primer nombre que tengan.
export const parsePhoneEntries = text => {
  const seen = new Set();
  return String(text || '')
    .split(/\n+/)
    .flatMap(parseLine)
    .filter(entry => digitCount(entry.raw) >= 3)
    .map(entry => ({ ...entry, phone: normalizePhone(entry.raw) }))
    .filter(entry => {
      const key = entry.phone || entry.raw;
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    });
};

// Quita del texto las líneas (o trozos de línea) de esos números.
export const removePhonesFromText = (text, phonesToRemove) => {
  const remove = new Set(phonesToRemove);
  return String(text || '')
    .split(/\n/)
    .map(line => {
      const entries = parseLine(line);
      if (entries.length === 1)
        return remove.has(normalizePhone(entries[0].raw)) ? null : line;
      return entries
        .filter(entry => !remove.has(normalizePhone(entry.raw)))
        .map(entry => entry.raw)
        .join(', ');
    })
    .filter(line => line !== null && line.trim() !== '')
    .join('\n');
};

export const buildAudience = ({
  labelIds = [],
  excludedLabelIds = [],
  chats = [],
  chatNames = {},
  phoneText = '',
}) => [
  ...labelIds.map(id => ({ type: 'Label', id })),
  ...excludedLabelIds.map(id => ({ type: 'ExcludeLabel', id })),
  ...chats.map(jid => ({
    type: 'WhatsappChat',
    id: jid,
    name: chatNames[jid] || jid,
  })),
  ...parsePhoneEntries(phoneText)
    .filter(entry => entry.phone)
    .map(entry => ({ type: 'Phone', id: entry.phone, name: entry.name })),
];

export const phoneTextFromAudience = audience =>
  (audience || [])
    .filter(item => item.type === 'Phone')
    .map(item => (item.name ? `${item.name};${item.id}` : item.id))
    .join('\n');
