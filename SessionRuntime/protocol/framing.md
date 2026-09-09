# Session wire framing v1

Each frame is one unsigned kind byte followed by a four-byte unsigned big-endian
payload length, then exactly that many bytes. Kind 1 is a UTF-8 JSON control
payload (1–1048576 bytes); kind 2 is a binary surface payload (1–262144 bytes).
Unknown kinds, empty frames and oversized lengths terminate the connection before
payload allocation. EOF within either header or payload is a truncated frame.

Control and surface payloads use separate logical streams. Framing does not grant
write permission: the operation decoder must still validate identity, epoch,
capability, request schema and lease. The incremental decoder returns one frame
at a time and reports the consumed byte count so callers retain coalesced input.
The payload is borrowed until the next decoder feed call.

This file specifies framing only. Operation schemas and Swift interoperability
fixtures remain P0 work; a passing framing test is not an A02 pass.
