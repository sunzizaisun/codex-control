// Accept presentation whitespace only BETWEEN known fields. Do not normalize
// message/reply text: their exact bytes must match the stored companion pair.
export function companionMirrorID(text: string): string | undefined {
  return /[ \t\r\n]同步编号：([a-f0-9-]{36})[ \t\r\n]*$/.exec(text)?.[1];
}

export function verifiedCompanionMirror(text: string, id: string,
  source: { text: string; reply: string | null } | undefined): boolean {
  if (!source || source.reply === null) return false;
  const fields = ["来自手机／手表", `用户：${source.text}`, `dot：${source.reply}`, `同步编号：${id}`];
  let offset = 0;
  for (let index = 0; index < fields.length; index++) {
    const field = fields[index];
    if (!text.startsWith(field, offset)) return false;
    offset += field.length;
    const end = offset;
    while (offset < text.length && /[ \t\r\n]/.test(text[offset])) offset++;
    if (index < fields.length - 1 && offset === end) return false;
  }
  return offset === text.length;
}
