# P0 snapshot transaction

After a validated hello, the probe sends a kind-1 JSON control frame:
`{"type":"snapshot_begin","length":N,"sha256":"<64 hex digits>","sequence":S,"baseSequence":null}`.
N must be in 1…33554432. Only one transaction may be active per connection.

Kind-2 frames carry a four-byte unsigned big-endian chunk index followed by
nonempty snapshot bytes. Indices start at zero and increase by one. The entire
kind-2 payload remains at most 262144 bytes, leaving 262140 bytes for data.

A kind-1 `{"type":"snapshot_end"}` commits the transaction only when the
received length and SHA-256 match. Missing, reordered, excessive or corrupt data
rejects the transaction. EOF with an unfinished transaction is an error.
The bridge does not expose partial data or enable input before its first commit.
The probe bridge has a five-second initial/in-flight snapshot deadline.

The bridge requires the explicit `snapshot_transaction_v1` capability as well as
`p0_active_screen` and `terminal_delta_v1`; old probe peers are rejected before input.
See `delta-transaction.md` for sequence and resynchronization rules.

This framing now wraps both text screens and the active formatter state. It does
not claim full saved-state restoration, durable snapshot identity, graphics replay or
production surface revision/epoch tracking. SHA-256 is an integrity check, not
peer authentication. Production ownership still belongs to the transport and
session protocol contracts.
