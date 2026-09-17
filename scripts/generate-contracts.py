#!/usr/bin/env python3
"""Generate the Swift catalog and focused models from the pinned OpenRPC schema.

No network or Python package dependencies. `--check` is suitable for CI. Updating
the upstream contract is deliberate: replace Contracts/gateway-contract.openrpc.json
and its provenance/hash in Contracts/pin.json, then regenerate and review the diff.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent.parent
SCHEMA = ROOT / "Contracts/gateway-contract.openrpc.json"
PIN = ROOT / "Contracts/pin.json"
OUTPUT = ROOT / "Sources/HermesProtocol/GatewayContract.generated.swift"

# Keep the first usable slice reviewed and small. Complex referenced objects stay
# JSONValue, retaining fields until dedicated domain adapters are introduced.
MODELS = (
    "ClientCapabilitiesParams", "ClientCapabilitiesResult",
    "SessionCreateParams", "SessionResumeParams", "SessionActivateParams",
    "SessionInterruptParams", "SessionEventsSinceParams", "SessionEventsSinceResult",
    "PromptSubmitParams", "PromptSubmitResult", "GatewayReadyPayload",
    "StreamDeltaPayload", "MessageCompletePayload", "ApprovalResult", "ClarifyResult",
)


def literal(value: str) -> str:
    return json.dumps(value, ensure_ascii=False).replace("\\/", "/")


def identifier(value: str) -> str:
    words = re.split(r"[._-]", value)
    acronyms = {"id": "ID", "ids": "IDs", "url": "URL", "urls": "URLs", "rpc": "RPC", "tts": "TTS"}
    return words[0] + "".join(
        acronyms.get(word, word.capitalize())
        for word in words[1:]
    )


def swift_type(schema: dict, definitions: dict) -> str:
    if "$ref" in schema:
        ref = schema["$ref"].split("/")[-1]
        resolved = definitions[ref]
        if "enum" in resolved and resolved.get("type") == "string":
            return "String"  # Preserve values introduced by a newer server.
        return ref if ref in MODELS else "JSONValue"
    if "anyOf" in schema:
        nonnull = [item for item in schema["anyOf"] if item.get("type") != "null"]
        return swift_type(nonnull[0], definitions) if len(nonnull) == 1 else "JSONValue"
    kind = schema.get("type")
    if kind == "array":
        element = schema.get("items", {})
        value = swift_type(element, definitions)
        if nullable(element):
            value += "?"
        return f"[{value}]"
    if kind == "object" and isinstance(schema.get("additionalProperties"), dict):
        element = schema["additionalProperties"]
        value = swift_type(element, definitions)
        if nullable(element):
            value += "?"
        return f"[String: {value}]"
    return {"string": "String", "integer": "Int", "number": "Double", "boolean": "Bool"}.get(kind, "JSONValue")


def nullable(schema: dict) -> bool:
    return any(item.get("type") == "null" for item in schema.get("anyOf", []))


def model(name: str, schema: dict, definitions: dict) -> str:
    required = set(schema.get("required", []))
    properties = schema.get("properties", {})
    fields = []
    for wire_name, spec in properties.items():
        base = swift_type(spec, definitions)
        null = nullable(spec)
        optional = wire_name not in required
        kind = "field" if null and optional else "optional" if optional else "required"
        value_type = f"JSONField<{base}>" if kind == "field" else base + ("?" if optional or null else "")
        fields.append((wire_name, identifier(wire_name), base, value_type, kind))
    lines = [f"/// Wire schema: `{name}`. Complex referenced objects retain their full JSON structure.",
             f"public struct {name}: Sendable, Codable, Equatable {{"]
    for _, prop, _, value_type, _ in fields:
        lines.append(f"    public var `{prop}`: {value_type}")
    lines += ["", "    public init("]
    for index, (_, prop, _, value_type, kind) in enumerate(fields):
        default = " = .absent" if kind == "field" else " = nil" if kind == "optional" else ""
        comma = "," if index < len(fields) - 1 else ""
        lines.append(f"        `{prop}`: {value_type}{default}{comma}")
    lines.append("    ) {")
    for _, prop, _, _, _ in fields:
        lines.append(f"        self.`{prop}` = `{prop}`")
    lines += ["    }", "", "    private enum CodingKeys: String, CodingKey {"]
    for wire_name, prop, _, _, _ in fields:
        lines.append(f"        case `{prop}` = {literal(wire_name)}")
    lines += ["    }", "", "    public init(from decoder: any Decoder) throws {",
              "        let container = try decoder.container(keyedBy: CodingKeys.self)"]
    for _, prop, base, value_type, kind in fields:
        operation = "decodeField" if kind == "field" else "decodeOmittable" if kind == "optional" else "decode"
        decoded_type = base if kind != "required" else value_type
        lines.append(f"        `{prop}` = try container.{operation}({decoded_type}.self, forKey: .`{prop}`)")
    lines += ["    }", "", "    public func encode(to encoder: any Encoder) throws {",
              "        var container = encoder.container(keyedBy: CodingKeys.self)"]
    for _, prop, _, _, kind in fields:
        operation = "encodeField" if kind == "field" else "encodeIfPresent" if kind == "optional" else "encode"
        lines.append(f"        try container.{operation}(`{prop}`, forKey: .`{prop}`)")
    lines += ["    }", "}"]
    return "\n".join(lines)


def generate(schema: dict, pin: dict) -> str:
    lines = ["// Generated by scripts/generate-contracts.py. Do not edit.",
             f"// Upstream: {pin['commit']}", f"// Schema SHA-256: {pin['sha256']}",
             "import Foundation", "", "public enum GatewayContract {",
             f"    public static let upstreamCommit = {literal(pin['commit'])}",
             f"    public static let schemaSHA256 = {literal(pin['sha256'])}",
             "}", ""]
    for name, key in (("GatewayMethod", "methods"), ("GatewayServerRequestMethod", "x-server-requests"),
                      ("GatewayEventType", "x-notifications")):
        entries = schema[key]
        identifiers = [identifier(item["name"]) for item in entries]
        if len(set(identifiers)) != len(identifiers):
            raise ValueError(f"Swift name collision in {name}")
        lines.append(f"public enum {name}: String, Sendable, CaseIterable, Codable {{")
        for entry in entries:
            lines.append(f"    case `{identifier(entry['name'])}` = {literal(entry['name'])}")
        lines += ["", "    public var payloadSchema: String {", "        switch self {"]
        for entry in entries:
            ref = entry["params"][0]["schema"].get("$ref")
            # No-payload events are inline empty-object schemas.
            value = ref.split("/")[-1] if ref else "EmptyObject"
            lines.append(f"        case .`{identifier(entry['name'])}`: {literal(value)}")
        lines += ["        }", "    }"]
        if key != "x-notifications":
            lines += ["", "    public var resultSchema: String {", "        switch self {"]
            for entry in entries:
                ref = entry["result"]["schema"].get("$ref")
                value = ref.split("/")[-1] if ref else "JSONValue"
                lines.append(f"        case .`{identifier(entry['name'])}`: {literal(value)}")
            lines += ["        }", "    }"]
        lines += ["}", ""]
    definitions = schema["components"]["schemas"]
    for name in MODELS:
        lines += [model(name, definitions[name], definitions), ""]
    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Exit nonzero if generated Swift has drifted")
    args = parser.parse_args()
    source = SCHEMA.read_bytes()
    pin = json.loads(PIN.read_text())
    actual_hash = hashlib.sha256(source).hexdigest()
    if actual_hash != pin["sha256"]:
        raise SystemExit("Pinned schema hash mismatch; review/update Contracts/pin.json before generating")
    output = generate(json.loads(source), pin)
    if args.check:
        if not OUTPUT.exists() or OUTPUT.read_text() != output:
            raise SystemExit("Swift contract has drifted. Run python3 scripts/generate-contracts.py")
        print("Swift contract matches pinned schema (218 RPCs, 12 server requests, 69 events).")
    else:
        OUTPUT.write_text(output)
        print(f"Generated {OUTPUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
