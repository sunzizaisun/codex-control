import { DurableObject } from "cloudflare:workers";
import { readPacket, PacketReadError, isRelayPacket, isExpired, isMailboxPacketExpired, constantTimeEqual } from "./packet.mjs";
import { authorizeRelayV2, validRelayRoomID } from "./auth-v2.mjs";
import { DeviceRelayOperations } from "./device-relay.mjs";
import { deviceError, forwardDeviceRequest, legacyDeviceUpgradeRequired } from "./device-routing.mjs";

export class RelayRoom extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.deviceRelay = new DeviceRelayOperations(ctx, env);
    // Cloudflare answers static health probes without waking a hibernated
    // room. Real mailbox notifications still wake only the connected client.
    this.ctx.setWebSocketAutoResponse(
      this.ctx.getWebSockets().some(socket => socket.deserializeAttachment()?.version === 3)
        ? undefined : new WebSocketRequestResponsePair("ping", "pong"),
    );
  }

  async fetch(request) {
    try { return await this.handle(request); }
    catch (error) {
      if (error instanceof PacketReadError) return json({ error: error.message }, { status: error.status });
      throw error;
    }
  }

  async handle(request) {
    const url = new URL(request.url);
    if (url.pathname.startsWith("/v3/") || request.headers.get("X-Codex-Relay-Protocol") === "3") {
      return this.deviceRelay.handle(request);
    }
    // A previous Worker version may still forward legacy requests while the
    // object has already updated. Cutover must be checked at BOTH boundaries.
    try {
      if (legacyDeviceUpgradeRequired(this.env.RELAY_V3_ONLY_ROOMS, request.headers.get("X-Codex-Relay-Room"))) {
        return new Response("Device protocol upgrade required", { status: 426 });
      }
    } catch (error) { return deviceError(error); }
    const parts = url.pathname.split("/").filter(Boolean);
    const resource = parts[0];
    const secure = request.headers.get("X-Codex-Relay-Protocol") === "2";
    const packetContext = destination => secure ? { keyID: request.headers.get("X-Codex-Relay-Key-ID"), destination } : undefined;

    if (resource === "chat-snapshot" || (["stream", "mailbox"].includes(resource) && parts[1] === "browser")) {
      return new Response("Chat route retired", { status: 410 });
    }

    if (resource === "snapshot" && parts.length === 1) {
      if (request.method === "PUT") {
        const packet = await readPacket(request, packetContext("snapshot"));
        await this.ctx.storage.put("snapshot", packet);
        return json({ ok: true });
      }
      if (request.method === "GET") {
        const packet = await this.ctx.storage.get("snapshot");
        if (packet && !isRelayPacket(packet)) {
          await this.ctx.storage.delete("snapshot");
          return new Response(null, { status: 204 });
        }
        if (packet && isExpired(packet, 5 * 60 * 1000)) {
          await this.ctx.storage.delete("snapshot");
          return new Response(null, { status: 204 });
        }
        return packet ? json(packet) : new Response(null, { status: 204 });
      }
    }

    // Macs and future always-on gateways keep one hibernatable WebSocket
    // open instead of polling every few seconds. Messages remain persisted in
    // the mailbox; the socket is only an inexpensive "something changed"
    // signal, so reconnects and missed signals cannot lose an action.
    if (resource === "stream" && parts.length === 2 && ["mac", "phone", "watch"].includes(parts[1])) {
      if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
        return new Response("Expected WebSocket", { status: 426 });
      }
      const mailbox = parts[1];
      const pair = new WebSocketPair();
      const [client, server] = Object.values(pair);
      const tag = `mailbox:${mailbox}`;
      server.serializeAttachment({ mailbox });
      this.ctx.acceptWebSocket(server, [tag]);

      // Close the GET/subscribe race: if a message was queued immediately
      // before this socket attached, signal it now. Otherwise the connection
      // hibernates until the next POST.
      const pending = await this.ctx.storage.list({
        prefix: `mailbox:${mailbox}:`,
        limit: 1,
      });
      if (pending.size > 0) server.send("mailbox");

      return new Response(null, { status: 101, webSocket: client });
    }

    if (resource === "mailbox" && ["mac", "phone", "watch"].includes(parts[1])) {
      const mailbox = parts[1];
      if (request.method === "POST" && parts.length === 2) {
        const packet = await readPacket(request, packetContext(mailbox));
        await this.ctx.storage.put(`mailbox:${mailbox}:${packet.id}`, packet);
        this.notifyMailbox(mailbox);
        return json({ ok: true });
      }
      if (request.method === "GET" && parts.length === 2) {
        const stored = await this.ctx.storage.list({ prefix: `mailbox:${mailbox}:` });
        const packets = [];
        const expiredKeys = [];
        for (const [key, packet] of stored) {
          // The payload is encrypted, so the sender supplies the deadline.
          // Current clients give Chat/task commands up to 24 hours to survive a
          // sleeping Mac, while approvals, resets, replies, and legacy packets
          // retain the short 15-minute safety window.
          if (!isRelayPacket(packet) || isMailboxPacketExpired(packet)) {
            expiredKeys.push(key);
          } else {
            packets.push(packet);
          }
        }
        if (expiredKeys.length > 0) {
          for (let offset = 0; offset < expiredKeys.length; offset += 128) {
            await this.ctx.storage.delete(expiredKeys.slice(offset, offset + 128));
          }
        }
        packets.sort((a, b) => a.sentAt - b.sentAt);
        return json(packets);
      }
      if (request.method === "DELETE" && parts.length === 3) {
        let messageID;
        try { messageID = decodeURIComponent(parts[2]); } catch { return new Response("Invalid message ID", { status: 400 }); }
        if (!/^[A-Za-z0-9_-]{1,160}$/.test(messageID)) return new Response("Invalid message ID", { status: 400 });
        await this.ctx.storage.delete(`mailbox:${mailbox}:${messageID}`);
        return new Response(null, { status: 204 });
      }
    }

    return new Response("Not found", { status: 404 });
  }

  notifyMailbox(mailbox) {
    for (const socket of this.ctx.getWebSockets(`mailbox:${mailbox}`)) {
      try {
        socket.send("mailbox");
      } catch {
        // A disconnected socket disappears from getWebSockets after the close
        // handshake. Storage remains the source of truth in the meantime.
      }
    }
  }

  async webSocketMessage(socket, message) {
    if (socket.deserializeAttachment()?.version === 3) return this.deviceRelay.socketMessage(socket, message);
    // Keep client heartbeats cheap. The platform-level auto-response handles
    // the common string ping without waking a hibernated room; this fallback
    // covers clients that send another representation.
    if (message === "ping") socket.send("pong");
  }

  async alarm() { await this.deviceRelay.alarm(); }
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname.startsWith("/v3/")) return forwardDeviceRequest(request, env);
    if (url.pathname === "/health" && request.method === "GET") {
      // A metadata-only probe lets the Oracle gateway and troubleshooting
      // tools distinguish an unavailable Worker from an empty mailbox. It
      // reveals no room, packet, or account information and is intentionally
      // independent of relay authentication.
      return json({ ok: true, protocol: 3, now: Date.now() });
    }
    const match = url.pathname.match(/^\/v([12])\/rooms\/([^/]+)\/(.+)$/);
    if (!match) return new Response("Not found", { status: 404 });

    let roomID;
    try { roomID = decodeURIComponent(match[2]); } catch { return new Response("Invalid room ID", { status: 400 }); }
    // The legacy namespace is the bare room ID. Disallow ':' there so a v1
    // caller can never name a v2:<room>:<keyID> Durable Object directly.
    if (!validRelayRoomID(roomID)) return new Response("Invalid room ID", { status: 400 });
    try {
      if (legacyDeviceUpgradeRequired(env.RELAY_V3_ONLY_ROOMS, roomID)) return new Response("Device protocol upgrade required", { status: 426 });
    } catch (error) { return deviceError(error); }
    const supplied = request.headers.get("X-Codex-Relay-Key") || "";
    const keyID = request.headers.get("X-Codex-Relay-Key-ID") || "";
    if (match[1] === "2") {
      const result = authorizeRelayV2(env.RELAY_AUTH_V2 || "", roomID, keyID, supplied);
      if (!result.configured) return new Response("Secure relay is not configured", { status: 503 });
      if (!result.authorized) return new Response("Unauthorized", { status: 401 });
    } else {
      // Explicit temporary compatibility only for devices already installed.
      // v2 clients never fall back to this namespace or its known weak key.
      if (env.ALLOW_LEGACY_RELAY !== "true") return new Response("Relay protocol upgrade required", { status: 426 });
      if (!constantTimeEqual(supplied, env.RELAY_AUTH_KEY || "")) return new Response("Unauthorized", { status: 401 });
    }
    const id = env.RELAY_ROOMS.idFromName(match[1] === "2" ? `v2:${roomID}:${keyID}` : roomID);
    const stub = env.RELAY_ROOMS.get(id);
    const forwardedHeaders = new Headers(request.headers);
    forwardedHeaders.set("X-Codex-Relay-Room", roomID);
    forwardedHeaders.set("X-Codex-Relay-Protocol", match[1]);
    return stub.fetch(new Request(`${url.origin}/${match[3]}`, {
      method: request.method,
      headers: forwardedHeaders,
      body: request.method === "GET" || request.method === "HEAD" ? undefined : request.body,
    }));
  },
};

function json(value, init = {}) {
  return new Response(JSON.stringify(value), {
    ...init,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
  });
}
