import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { scanPublicSource } from '../scan-public-source.mjs';
test('publication scanner reports credential classes without copying values', async () => {
  const root=await mkdtemp(path.join(tmpdir(),'public-scan-test-'));
  try {
    const token = ['ghp', 'a'.repeat(36)].join('_');
    await writeFile(path.join(root,'sample.txt'),token);
    const result=await scanPublicSource(root);
    assert.deepEqual(result.failures,[{path:'sample.txt',rule:'github-token'}]);
    assert(!JSON.stringify(result).includes(token));
  } finally { await rm(root,{recursive:true}); }
});
test('publication scanner refuses local configuration but permits empty examples', async () => {
  const root=await mkdtemp(path.join(tmpdir(),'public-scan-test-'));
  try {
    await writeFile(path.join(root,'.env.example'),'KEY=');
    assert.equal((await scanPublicSource(root)).failures.length,0);
    await writeFile(path.join(root,'.env'),'KEY=private');
    assert.deepEqual((await scanPublicSource(root)).failures,[{path:'.env',rule:'sensitive-file'}]);
  } finally { await rm(root,{recursive:true}); }
});
