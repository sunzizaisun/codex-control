import { setTimeout as delay } from 'node:timers/promises';

// Test-client transport recovery only, not a dot accelerator. Never replay a
// submission, a provider error, a quota failure, or an uncertain write.
export async function withBoundedReadRetry(method, send, pause = delay) {
  for (let attempt = 0; ; attempt++) {
    try { return await send(); }
    catch (error) {
      const code = error?.cause?.code;
      if (method !== 'GET' || !['ECONNRESET', 'ETIMEDOUT', 'EPIPE', 'UND_ERR_SOCKET'].includes(code) || attempt >= 2) throw error;
      await pause((attempt + 1) * 500);
    }
  }
}
