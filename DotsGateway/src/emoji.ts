import data from "emoji-datasource/emoji.json";

// Slack's formatting guide identifies iamcal/emoji-data as its standard emoji
// catalogue. Only bundled Unicode metadata is used, not the image assets.
type Emoji = { unified: string; short_names: string[]; skin_variations?: Record<string, { unified: string }> };
const aliases = new Map<string, string>();
const unicode = (value: string) => String.fromCodePoint(...value.split("-").map(point => parseInt(point, 16)));
for (const item of data as Emoji[]) {
  for (const name of item.short_names) {
    aliases.set(`:${name}:`, unicode(item.unified));
    for (const [tone, variation] of Object.entries(item.skin_variations || {})) {
      const modifier = parseInt(tone, 16);
      if (/^1F3F[B-F]$/i.test(tone)) {
        aliases.set(`:${name}::skin-tone-${modifier - 0x1f3fb + 2}:`, unicode(variation.unified));
      }
    }
  }
}
export function standardEmoji(text: string): string {
  return text.replace(/:[a-z0-9_+-]+(?:::skin-tone-[2-6])?:/g, alias => aliases.get(alias) || alias);
}
