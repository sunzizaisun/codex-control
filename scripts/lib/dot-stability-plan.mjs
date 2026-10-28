export function dotStabilityPlan(batch) {
  if (!/^[a-f0-9]{8}$/.test(batch)) throw new Error('invalid_test_batch');
  const safe = '不要执行命令或调用其他插件。';
  const first = `银狐-${batch}🦊`;
  const second = `青松-${batch}🌲`;
  return [
    { label: 'unicode-seed', text: `稳定性1[${batch}]：请记住校验短语“${first}”，只回复这个完整短语。${safe}`, expected: first },
    { label: 'context-followup', text: `稳定性2[${batch}]：当前伴随软件线程的稳定性1中，让你记住的校验短语是什么？只回复完整短语。${safe}`, expected: first },
    { label: 'context-replacement', text: `稳定性3[${batch}]：将这一轮校验短语更新为“${second}”，只回复这个完整新短语。${safe}`, expected: second },
    { label: 'updated-followup', text: `稳定性4[${batch}]：当前伴随软件线程的稳定性3更新后的校验短语是什么？只回复完整短语。${safe}`, expected: second },
    { label: 'burst-a', text: `稳定性5[${batch}]：只回复“并发A-${batch}，中文🙂”。${safe}`, expected: `并发A-${batch}，中文🙂` },
    { label: 'burst-b', text: `稳定性6[${batch}]：只回复“并发B-${batch}，English🦉”。${safe}`, expected: `并发B-${batch}，English🦉` },
  ];
}
