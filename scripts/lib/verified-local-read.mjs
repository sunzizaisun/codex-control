import { lstat, readFile } from 'node:fs/promises';

// File-provider placeholders can return zero bytes without a read error.
// An equal hash of two incomplete reads is not a verified recovery copy.
export async function verifiedLocalRead(filename, io = { lstat, readFile }) {
  const before = await io.lstat(filename);
  if (!before.isFile() || !Number.isSafeInteger(before.size) || before.size < 0) {
    throw Error('not_a_regular_source_file');
  }
  const bytes = await io.readFile(filename);
  const after = await io.lstat(filename);
  if (!(bytes instanceof Uint8Array) || bytes.byteLength !== before.size || !after.isFile()
      || after.size !== before.size || after.ino !== before.ino || after.dev !== before.dev
      || after.mtimeMs !== before.mtimeMs) {
    throw Error('incomplete_or_changed_source_read');
  }
  return bytes;
}
