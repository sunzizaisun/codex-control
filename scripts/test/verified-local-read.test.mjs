import assert from 'node:assert/strict';
import { test } from 'node:test';
import { verifiedLocalRead } from '../lib/verified-local-read.mjs';

const stat = { isFile: () => true, size: 4, ino: 1, dev: 2, mtimeMs: 3 };
const io = (bytes, second = stat) => {
  let calls = 0;
  return { readFile: async () => bytes, lstat: async () => calls++ ? second : stat };
};
test('verified backup reads preserve exact bytes including legitimate empty files', async () => {
  const bytes = Buffer.from([0, 255, 1, 2]);
  assert.deepEqual(await verifiedLocalRead('fixture', io(bytes)), bytes);
  const empty = { ...stat, size: 0 };
  assert.equal((await verifiedLocalRead('fixture', {
    readFile: async () => Buffer.alloc(0), lstat: async () => empty,
  })).byteLength, 0);
});
test('silent empty placeholder reads cannot pass backup verification', async () => {
  for (const bytes of [Buffer.alloc(0), Buffer.from([1, 2]), 'text']) {
    await assert.rejects(verifiedLocalRead('fixture', io(bytes)), /incomplete_or_changed_source_read/);
  }
});
test('a source replaced or modified during reading cannot pass', async () => {
  for (const changed of [{ ...stat, size: 5 }, { ...stat, ino: 9 }, { ...stat, dev: 9 },
    { ...stat, mtimeMs: 4 }, { ...stat, isFile: () => false }]) {
    await assert.rejects(verifiedLocalRead('fixture', io(Buffer.alloc(4), changed)), /incomplete_or_changed_source_read/);
  }
});
