import { calculateJwkThumbprint } from "jose";
import { authorizeDevice, DeviceAuthError, deviceRevocation, requireUnrevokedDevice, revokeDevice, roleAllows, verifyDeviceProof } from "./device-auth.mjs";
import { createEnrollmentInvitation, enrolledDeviceRecords, readEnrollmentInvitation, readOwnEnrollment, redeemEnrollmentInvitation } from "./device-enrollment.mjs";
import { DEVICE_PROTOCOL_HEADER, deviceAdmission, deviceError, deviceJSON, deviceRoots, deviceRoute } from "./device-routing.mjs";
import { readDevicePacket, sequenceText, validDevicePacket } from "./device-packets.mjs";
import { PacketReadError } from "./packet.mjs";
import { handleKeyDelivery, keyDeliveryResource } from "./device-key-delivery.mjs";

const id = value => typeof value === "string" && /^[A-Za-z0-9_-]{1,160}$/.test(value);
const digest = value => typeof value === "string" && /^[A-Za-z0-9_-]{43}$/.test(value);
const exact = (value, fields) => value && typeof value === "object" && !Array.isArray(value)
  && Object.keys(value).sort().join(",") === [...fields].sort().join(",");
const fail = (code, status = 503) => { throw new DeviceAuthError(code, status); };
const indexPrefix = target => `device-packet:index:${target}:`;
const indexKey = (target, packetID) => indexPrefix(target) + packetID;
const queuePrefix = target => `device-packet:queue:${target}:`;
const queueKey = (target, sequence) => queuePrefix(target) + sequenceText(sequence);
const validIndex = value => exact(value, ["version", "deviceID", "thumbprint", "packetDigest", "sequence", "expiresAt", "state"])
  && value.version === 1 && id(value.deviceID) && digest(value.thumbprint) && digest(value.packetDigest)
  && Number.isSafeInteger(value.sequence) && value.sequence > 0 && Number.isSafeInteger(value.expiresAt) && value.expiresAt > 0
  && ["queued", "acknowledged", "blocked"].includes(value.state);
const validRow = (value, context) => exact(value, ["version", "deviceID", "thumbprint", "role", "packet"])
  && value.version === 1 && id(value.deviceID) && digest(value.thumbprint) && ["mac", "phone", "watch"].includes(value.role)
  && validDevicePacket(value.packet, context, 0, false);

// Reused by the actual RelayRoom HTTP/WebSocket entry points. The optional
// clock is constructor-only dependency injection, never an HTTP/env setting.
// No request authentication or pending work lives solely in instance memory.
export class DeviceRelayOperations {
  constructor(ctx, env, clock = Date.now) { this.ctx = ctx; this.env = env; this.clock = clock; }
  async records(context) { return enrolledDeviceRecords(this.ctx.storage, deviceRoots(this.env.RELAY_DEVICE_ROOTS_V3, context), context); }
  async requirePrincipal(transaction, principal) {
    await requireUnrevokedDevice(transaction, principal);
    if (principal.expiresAt <= this.clock()) fail("invalid_dpop_proof", 401);
  }
  async handle(request) {
    try { return await this.handleChecked(request); }
    catch (error) {
      if (error instanceof PacketReadError) return deviceJSON({ error: error.message }, error.status);
      return deviceError(error);
    }
  }
  async handleChecked(request) {
    const context = deviceRoute(request);
    if (request.headers.get("X-Codex-Relay-Protocol") !== "3"
        || request.headers.get("X-Codex-Relay-Room") !== context.roomID) fail("invalid_device_route", 400);
    const roots = deviceRoots(this.env.RELAY_DEVICE_ROOTS_V3, context);
    const storage = this.ctx.storage, resource = context.resource;
    if (keyDeliveryResource(resource)) return handleKeyDelivery(request, context, roots, storage, this.clock);
    if (resource === "devices/invitations") return deviceAdmission(await createEnrollmentInvitation(request, context, roots, storage, this.clock));
    if (/^devices\/invitations\/[A-Za-z0-9_-]{1,160}$/.test(resource)) {
      const result = await readEnrollmentInvitation(request, context, roots, storage, this.clock);
      if (!result.authorized) return deviceAdmission(result);
      return result.invitation === undefined ? deviceJSON(undefined, 204) : deviceJSON(result);
    }
    if (resource === "devices/enroll") return deviceJSON(await redeemEnrollmentInvitation(request, context, roots, storage, this.clock));
    if (resource === "devices/me") return deviceAdmission(await readOwnEnrollment(request, context, roots, storage, this.clock));
    const records = await this.records(context);
    const revocation = /^devices\/([A-Za-z0-9_-]+)\/revoke$/.exec(resource);
    if (revocation) {
      if (request.body !== null) fail("unexpected_device_body", 400);
      const result = await revokeDevice(request, context, JSON.stringify(records), storage, revocation[1], this.clock);
      if (result.authorized) await this.closeRevokedSockets(revocation[1]);
      return deviceAdmission(result);
    }
    const write = resource === "snapshot" && request.method === "PUT"
      || /^mailbox\/(mac|phone|watch)$/.test(resource) && request.method === "POST";
    if (write) {
      // Reject unknown keys/tokens/roles before buffering a large encrypted
      // body. This signature-only preflight is NOT admission: the final gate
      // below still verifies actual body bytes, live nonce and replay state.
      const preflight = await verifyDeviceProof(request, { ...context, requireBodyDigest: true }, JSON.stringify(records), this.clock());
      if (!roleAllows(preflight.principal.role, request.method, resource)) fail("device_role_forbidden", 403);
    }
    const target = resource === "snapshot" ? "snapshot" : resource.split("/")[1];
    const admitted = write ? await readDevicePacket(request, { keyID: context.keyID, destination: target }, this.clock()) : undefined;
    if (!write && request.body !== null) fail("unexpected_device_body", 400);
    const authorization = await authorizeDevice(request, { ...context, ...(admitted ? { bodyDigest: admitted.bodyDigest } : {}) },
      JSON.stringify(records), storage, this.clock);
    if (!authorization.authorized) return deviceAdmission(authorization);
    const principal = authorization.principal;
    if (resource === "devices/peers") return deviceJSON(await this.peers(principal, context));
    if (resource.startsWith("stream/")) return this.stream(request, principal, context);
    if (resource === "snapshot") return this.snapshot(request, principal, context, admitted, records);
    if (resource.startsWith("mailbox/")) {
      if (request.method === "POST") {
        const result = await this.enqueue(principal, context, admitted);
        // Notification failure never changes a durable acceptance into a false
        // rejection. Sockets are hints; the persisted queue remains authority.
        await this.notifyMailbox(target).catch(() => {});
        return deviceJSON(result);
      }
      if (request.method === "GET") return deviceJSON(await this.mailbox(principal, context));
      if (request.method === "DELETE") { await this.acknowledge(principal, context); return deviceJSON(undefined, 204); }
    }
    fail("device_route_not_found", 404);
  }
  async peers(principal, context) {
    const records = await this.records(context);
    return this.ctx.storage.transaction(async transaction => {
      await this.requirePrincipal(transaction, principal);
      const peers = [];
      for (const record of records) {
        if (principal.role !== "mac" && record.role !== "mac" && record.deviceID !== principal.deviceID) continue;
        const revoked = await deviceRevocation(transaction, record);
        peers.push({ roomID: record.roomID, keyID: record.keyID, deviceID: record.deviceID, role: record.role,
          jwk: record.jwk, expiresAt: record.expiresAt,
          ...(revoked ? { revokedAt: revoked.revokedAt } : record.revokedAt === undefined ? {} : { revokedAt: record.revokedAt }) });
      }
      await this.requirePrincipal(transaction, principal);
      return { peers, capturedAt: this.clock() };
    });
  }
  async snapshot(request, principal, context, admitted, records) {
    const packetContext = { keyID: context.keyID, destination: "snapshot" };
    const thumbprints = new Map(await Promise.all(records.map(async record => [record.deviceID, await calculateJwkThumbprint(record.jwk)])));
    const result = await this.ctx.storage.transaction(async transaction => {
      await this.requirePrincipal(transaction, principal);
      const current = await transaction.get("device-packet:snapshot");
      await this.requirePrincipal(transaction, principal);
      if (current !== undefined && (!validRow(current, packetContext) || current.role !== "mac")) fail("device_relay_state_unavailable");
      if (request.method === "GET") {
        if (!current || !validDevicePacket(current.packet, packetContext, this.clock())) return undefined;
        const owner = records.find(value => value.deviceID === current.deviceID && value.role === "mac");
        const revoked = owner ? await deviceRevocation(transaction, owner) : undefined;
        await this.requirePrincipal(transaction, principal);
        if (!owner || owner.expiresAt <= this.clock() || owner.revokedAt <= this.clock()
            || thumbprints.get(owner.deviceID) !== current.thumbprint || revoked) return undefined;
        return current.packet;
      }
      if (!validDevicePacket(admitted.packet, packetContext, this.clock())) fail("device_packet_expired", 400);
      if (current && current.packet.sentAt > admitted.packet.sentAt) return { stored: false, superseded: true, id: admitted.packet.id };
      await transaction.put("device-packet:snapshot", { version: 1, deviceID: principal.deviceID,
        thumbprint: principal.thumbprint, role: principal.role, packet: admitted.packet });
      return { stored: true, id: admitted.packet.id, packetDigest: admitted.packetDigest };
    });
    return result === undefined ? deviceJSON(undefined, 204) : deviceJSON(result);
  }
  async enqueue(principal, context, admitted) {
    const target = context.resource.split("/")[1], { packet, packetDigest } = admitted;
    return this.ctx.storage.transaction(async transaction => {
      await this.requirePrincipal(transaction, principal);
      const key = indexKey(target, packet.id), prior = await transaction.get(key);
      await this.requirePrincipal(transaction, principal);
      if (prior !== undefined) {
        if (!validIndex(prior)) fail("device_relay_state_unavailable");
        if (prior.deviceID !== principal.deviceID || prior.thumbprint !== principal.thumbprint || prior.packetDigest !== packetDigest) fail("device_packet_conflict", 409);
        return { stored: true, duplicate: true, id: packet.id, packetDigest, delivery: prior.state };
      }
      const indices = await transaction.list({ prefix: indexPrefix(target), limit: 1025 });
      if (indices.size > 1024) fail("device_relay_state_unavailable");
      const sequence = (await transaction.get(`device-packet:sequence:${target}`) ?? 0) + 1;
      const sequenceString = sequenceText(sequence), expired = []; let queued = 0;
      const now = this.clock();
      if (!validDevicePacket(packet, { keyID: context.keyID, destination: target }, now)) fail("device_packet_expired", 400);
      for (const [storedKey, value] of indices) {
        if (!validIndex(value)) fail("device_relay_state_unavailable");
        if (value.expiresAt <= now) expired.push(storedKey, queueKey(target, value.sequence));
        else if (value.state === "queued") queued++;
      }
      if (indices.size - expired.length / 2 >= 1024 || queued >= 128) fail("device_mailbox_full", 429);
      await this.requirePrincipal(transaction, principal);
      if (!validDevicePacket(packet, { keyID: context.keyID, destination: target }, this.clock())) fail("device_packet_expired", 400);
      if (expired.length) await transaction.delete(expired);
      await transaction.put(queuePrefix(target) + sequenceString, { version: 1, deviceID: principal.deviceID,
        thumbprint: principal.thumbprint, role: principal.role, packet });
      await transaction.put(key, { version: 1, deviceID: principal.deviceID, thumbprint: principal.thumbprint,
        packetDigest, sequence, expiresAt: packet.expiresAt, state: "queued" });
      await transaction.put(`device-packet:sequence:${target}`, sequence);
      return { stored: true, duplicate: false, id: packet.id, packetDigest, delivery: "queued" };
    });
  }
  async mailbox(principal, context) {
    const target = principal.role, prefix = queuePrefix(target), records = await this.records(context);
    const thumbprints = new Map(await Promise.all(records.map(async record => [record.deviceID, await calculateJwkThumbprint(record.jwk)])));
    return this.ctx.storage.transaction(async transaction => {
      await this.requirePrincipal(transaction, principal);
      const rows = await transaction.list({ prefix, ...(context.cursor ? { startAfter: prefix + context.cursor } : {}), limit: 9 });
      const packets = [], rejected = [], removals = []; let last, consumed = 0, bytes = 0;
      for (const [key, row] of rows) {
        if (consumed >= 8) break;
        if (!/^\d{16}$/.test(key.slice(prefix.length)) || !validRow(row, { keyID: context.keyID, destination: target })) fail("device_relay_state_unavailable");
        const size = row.packet.sealed.length + 1024;
        if (packets.length && bytes + size > 4_000_000) break;
        const pointer = await transaction.get(indexKey(target, row.packet.id));
        if (!validIndex(pointer) || queueKey(target, pointer.sequence) !== key || pointer.state !== "queued"
            || pointer.deviceID !== row.deviceID || pointer.thumbprint !== row.thumbprint) fail("device_relay_state_unavailable");
        const grant = records.find(value => value.deviceID === row.deviceID);
        const revoked = grant ? await deviceRevocation(transaction, grant) : undefined;
        if (!validDevicePacket(row.packet, { keyID: context.keyID, destination: target }, this.clock())) removals.push(key);
        else if (!grant || grant.expiresAt <= this.clock() || grant.revokedAt <= this.clock() || revoked || thumbprints.get(row.deviceID) !== row.thumbprint) {
          rejected.push({ id: row.packet.id, reason: "sender_no_longer_authorized" });
          await transaction.put(indexKey(target, row.packet.id), { ...pointer, state: "blocked" }); removals.push(key);
        } else { packets.push(row.packet); bytes += size; }
        last = key.slice(prefix.length); consumed++;
      }
      if (removals.length) await transaction.delete(removals);
      await this.requirePrincipal(transaction, principal);
      return { packets, rejected, nextCursor: consumed < rows.size ? last : null, capturedAt: this.clock() };
    });
  }
  async acknowledge(principal, context) {
    const packetID = context.resource.split("/")[2], target = principal.role;
    await this.ctx.storage.transaction(async transaction => {
      await this.requirePrincipal(transaction, principal);
      const key = indexKey(target, packetID), value = await transaction.get(key);
      await this.requirePrincipal(transaction, principal);
      if (value === undefined) fail("device_packet_not_found", 404);
      if (!validIndex(value)) fail("device_relay_state_unavailable");
      if (value.state === "acknowledged") return;
      if (value.state !== "queued") fail("device_packet_not_pending", 409);
      await transaction.delete(queueKey(target, value.sequence));
      await transaction.put(key, { ...value, state: "acknowledged" });
    });
  }
  async connectionAllowed(attachment) {
    if (!attachment || attachment.version !== 3 || attachment.expiresAt <= this.clock()) return false;
    const records = await this.records(attachment), record = records.find(value => value.deviceID === attachment.deviceID);
    if (!record || record.role !== attachment.role || record.expiresAt <= this.clock() || record.revokedAt <= this.clock()
        || await calculateJwkThumbprint(record.jwk) !== attachment.thumbprint) return false;
    const revoked = await deviceRevocation(this.ctx.storage, record);
    return !revoked && attachment.expiresAt > this.clock() && record.expiresAt > this.clock();
  }
  async stream(request, principal, context) {
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") return deviceJSON({ error: "websocket_required" }, 426);
    const tag = "device:" + principal.deviceID;
    if (this.ctx.getWebSockets(tag).length >= 4 || this.ctx.getWebSockets().length >= 128) fail("device_stream_capacity", 429);
    // No unauthenticated auto-pong in v3: each client message rechecks the
    // enrolled pin/expiry/revocation. The legacy room policy stays unchanged.
    this.ctx.setWebSocketAutoResponse();
    const pair = new WebSocketPair(), [client, server] = Object.values(pair);
    server.serializeAttachment({ version: 3, ...principal });
    this.ctx.acceptWebSocket(server, [tag, "device-mailbox:" + principal.role]);
    if (!await this.connectionAllowed(server.deserializeAttachment())) { server.close(1008, "Device authorization expired"); }
    else {
      if ((await this.ctx.storage.list({ prefix: queuePrefix(principal.role), limit: 1 })).size) server.send("mailbox");
      await this.scheduleSocketExpiry();
    }
    return new Response(null, { status: 101, webSocket: client, headers: { [DEVICE_PROTOCOL_HEADER]: "3", "Cache-Control": "no-store" } });
  }
  async socketMessage(socket, message) {
    try {
      if (message !== "ping" || !await this.connectionAllowed(socket.deserializeAttachment())) { socket.close(1008, "Device authorization required"); return; }
      socket.send("pong");
    } catch { try { socket.close(1011, "Device authorization unavailable"); } catch {} }
  }
  async closeRevokedSockets(deviceID) {
    for (const socket of this.ctx.getWebSockets("device:" + deviceID)) try { socket.close(1008, "Device revoked"); } catch {}
    await this.scheduleSocketExpiry();
  }
  async notifyMailbox(target) {
    for (const socket of this.ctx.getWebSockets("device-mailbox:" + target)) {
      try { if (await this.connectionAllowed(socket.deserializeAttachment())) socket.send("mailbox"); else socket.close(1008, "Device authorization required"); }
      catch { try { socket.close(1011, "Device authorization unavailable"); } catch {} }
    }
  }
  async scheduleSocketExpiry() {
    const expiries = this.ctx.getWebSockets().map(socket => socket.deserializeAttachment()).filter(value => value?.version === 3 && value.expiresAt > this.clock()).map(value => value.expiresAt);
    if (expiries.length) await this.ctx.storage.setAlarm(Math.min(...expiries));
  }
  async alarm() {
    for (const socket of this.ctx.getWebSockets()) {
      if (socket.deserializeAttachment()?.version !== 3) continue;
      try { if (!await this.connectionAllowed(socket.deserializeAttachment())) socket.close(1008, "Device authorization expired"); }
      catch { try { socket.close(1011, "Device authorization unavailable"); } catch {} }
    }
    await this.scheduleSocketExpiry();
  }
}
