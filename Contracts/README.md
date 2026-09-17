# Pinned Hermes gateway contract

`gateway-contract.openrpc.json` is the unmodified upstream schema from the commit
recorded in `pin.json`. Its 218 RPCs, 12 server requests and 69 notification types
are generated into `Sources/HermesProtocol/GatewayContract.generated.swift`.

```sh
python3 scripts/generate-contracts.py
python3 scripts/generate-contracts.py --check
```

The generator checks the schema's SHA-256 before it writes anything. To update the
baseline, copy the schema from a reviewed upstream commit, update the commit and
digest in `pin.json`, regenerate, and review the resulting contract diff.

The Swift catalog is exhaustive. Fifteen high-use parameter/result/payload models
are also generated. Primitive fields are typed; string enums accept new values;
complex referenced objects retain their full `JSONValue` until a dedicated domain
adapter is implemented. Optional nullable fields use `JSONField.absent`, `.null`,
and `.value`, so encoding never invents default parameters. This matters because
the gateway rejects extra request fields and distinguishes omission from null.

Wire envelopes (`GatewayEvent`, `GatewayServerRequest`, `RPCID`, `JSONRPCError`) and
JSON primitives are maintained separately. Event payloads stay under `payload`;
`session_id` and `seq` belong to the envelope. Unknown event names remain accepted.

JSON numbers have IEEE 754 precision, matching the existing JavaScript client.
`RPCID` uses integer/string decoding separately to preserve request identifiers.
