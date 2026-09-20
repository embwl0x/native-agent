# iPhone approval pairing

The companion source is included and now signs requests with a device-local
Ed25519 key in Keychain (`AfterFirstUnlockThisDeviceOnly`, not synchronized).
Update both apps. There is no unsigned approval compatibility exception.

Open Pair with Mac on the phone and tap Connect. On the Mac, open Connectors →
iPhone, match the full phone code, and choose Pair. Tap Connect again on the
phone. Existing installations must also confirm their device once. Requests
from a new signed phone can appear in this list before Connect is tapped.
Remove immediately withdraws approval authority; a durable removed record
prevents automatic enrollment from delayed messages. To pair that identity
again, its explicit Connect request can ask for local confirmation again.

The Mac stores `paired_phones.json` under its existing data root. Records contain
the public key, its SHA-256 fingerprint as device ID, and pending/paired/removed
status. Only the Mac Pair button promotes a pending key. Missing storage starts
empty; malformed, unreadable, or nonregular storage refuses mutations and
decisions without replacing its contents. No private device key reaches the Mac.

Wire fields: `clientId` is the lowercase 64-character SHA-256 fingerprint of the
32-byte Ed25519 public key; `devicePublicKey` and `deviceSignature` are base64.
The signature covers sorted-key JSON for the entire envelope excluding only
`signature` and `deviceSignature`. This includes the action, full payload,
message/transaction IDs, timestamp, protocol version, and device public key.
The existing outer HMAC then covers the envelope including the device signature.
Both Drive and CloudKit retain their HMAC, freshness, and transaction-ledger
checks before the common action router checks the registered device.

Approval, step, and inbox decision routes require the registered signature.
Resolution provenance retains the verified fingerprint in `clientID` and
`deviceID`; historical provenance still decodes. Invalid signatures and unknown
or removed devices produce a plain refusal in the Mac iPhone tab and a signed
error response to the phone. Invalid requests do not resolve the approval.
Pairing confirmation does not replay a refused decision; send it again.
