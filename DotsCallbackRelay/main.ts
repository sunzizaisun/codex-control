import { denoIO } from "./src/deno-io.ts";
import { relayHandler } from "./src/handler.ts";

const handler = relayHandler(Deno.env.get("CALLBACK_RELAY_KEY") || "", denoIO);
const port = Number(Deno.env.get("PORT") || "8000");
// No request, credential, destination or message logging.
Deno.serve({ port, onListen() {} }, handler);
