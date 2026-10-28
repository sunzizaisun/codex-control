import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { relayV2Credentials, sealRelayV2, openRelayV2 } from "../../scripts/lib/relay-v2-credentials.mjs";
const room = "qa-room", credentials = relayV2Credentials("fixture-only-".repeat(4), room);
const url = `http://127.0.0.1:18793/v2/rooms/${room}/snapshot`;
const headers = { "X-Codex-Relay-Key": credentials.authToken, "X-Codex-Relay-Key-ID": credentials.keyID, "Content-Type": "application/json" };
const response = await fetch(url, { headers }); assert.equal(response.status, 200);
const packet = await response.json();
assert.equal(openRelayV2(packet, credentials, room, "snapshot").snapshot.tasks[0].title, "中文🦦");
const now = Date.now();
const envelope = { version: 3, messageID: randomUUID(), sentAt: now, kind: "snapshot", senderDeviceID: "node-qa",
  snapshot: { tasks: [{ id: "node-fixture", title: "Node互通🦦", state: "running", updatedAt: now }], pendingApprovals: [], bridgeConnected: true, capturedAt: now } };
const uploaded = await fetch(url, { method: "PUT", headers, body: JSON.stringify(sealRelayV2(envelope, credentials, room, "snapshot")) });
assert.equal(uploaded.status, 200);
console.log("Swift to Node v2 authenticated encryption passed; Node fixture ready for native read.");
