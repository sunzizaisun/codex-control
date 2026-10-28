// An enriched sync receipt may contain private official message bodies. QA
// output must remain metadata-only, including for older --status/--wait calls.
export function historySyncSummary(receipt) {
  const result = {};
  for (const key of ['id', 'state', 'room_id', 'deliveryState']) {
    const value = receipt[key];
    if (typeof value === 'string' && /^[A-Za-z0-9_-]{1,64}$/.test(value)) result[key] = value;
  }
  for (const key of ['createdAt', 'expiresAt', 'recoverableUntil', 'imported', 'duplicates', 'mirrored', 'deliveryAttempts', 'completedAt']) {
    if (typeof receipt[key] === 'number' && Number.isFinite(receipt[key])) result[key] = receipt[key];
  }
  if (typeof receipt.truncated === 'boolean') result.truncated = receipt.truncated;
  if (receipt.timing && typeof receipt.timing === 'object') {
    result.timing = {};
    for (const key of ['acceptedAt', 'dispatchedAt', 'acknowledgedAt', 'readAt', 'mcpReceivedAt', 'mcpAuthorizedAt']) {
      if (typeof receipt.timing[key] === 'number' && Number.isFinite(receipt.timing[key])) result.timing[key] = receipt.timing[key];
    }
  }
  if (receipt.historyImport && typeof receipt.historyImport === 'object') {
    result.historyImport = {};
    for (const key of ['startedAt', 'attempts', 'lastFailedAt']) {
      if (typeof receipt.historyImport[key] === 'number' && Number.isSafeInteger(receipt.historyImport[key]) && receipt.historyImport[key] >= 0) result.historyImport[key] = receipt.historyImport[key];
    }
    if (typeof receipt.historyImport.lastError === 'string' && /^[a-z0-9_]{1,80}$/.test(receipt.historyImport.lastError)) result.historyImport.lastError = receipt.historyImport.lastError;
  }
  if (Array.isArray(receipt.messages) || Array.isArray(receipt.hiddenMessageIDs)) {
    const messages = receipt.messages ?? [], hidden = receipt.hiddenMessageIDs ?? [];
    const ids = messages.map(row => row?.id);
    const officialID = value => typeof value === 'string' && /^official\.[A-Za-z0-9_-]{1,128}$/.test(value);
    result.batch = {
      visible: messages.length, hidden: hidden.length,
      bounded: messages.length + hidden.length <= 30,
      unique: new Set([...ids, ...hidden]).size === ids.length + hidden.length,
      onlyOfficialIDs: [...ids, ...hidden].every(officialID),
    };
  }
  return result;
}
