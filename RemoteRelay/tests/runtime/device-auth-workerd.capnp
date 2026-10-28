using Workerd = import "/workerd/workerd.capnp";

# Offline test command only. No listening sockets, production bindings or
# outgoing network. --directory-path must point to a fresh QA temp directory.
const unitTests :Workerd.Config = (
  sockets = [],
  services = [
    (name = "no-network", network = (allow = [])),
    (name = "s2-qa-disk", disk = (writable = true)),
    (name = "s2-auth-qa", worker = (
      modules = [(name = "worker.mjs", esModule = embed "device-auth-workerd.bundle.mjs")],
      compatibilityDate = "2026-07-21",
      globalOutbound = "no-network",
      durableObjectNamespaces = [
        (className = "RelayAuthQARoom", uniqueKey = "s2-isolated-qa-only", enableSql = true),
        (className = "RelayHTTPQARoom", uniqueKey = "s2-http-isolated-qa-only", enableSql = true)
      ],
      durableObjectStorage = (localDisk = "s2-qa-disk"),
      bindings = [
        (name = "AUTH_QA", durableObjectNamespace = "RelayAuthQARoom"),
        (name = "RELAY_ROOMS", durableObjectNamespace = "RelayHTTPQARoom"),
        (name = "RELAY_DEVICE_ROOTS_V3", text = embed "RemoteRelay/tests/fixtures/runtime-device-roots.json"),
        (name = "RELAY_V3_ONLY_ROOMS", text = "[\"qa-runtime\"]")
      ]
    ))
  ]
);
