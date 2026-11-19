# iPhone approval pairing

The companion source is included and now signs requests with a device-local
Ed25519 key in Keychain (`AfterFirstUnlockThisDeviceOnly`, not synchronized).
Update both apps. There is no unsigned approval compatibility exception.

Open Pair with Mac on the phone and tap Connect. On the Mac, open Connectors →
iPhone, match the full phone code, and choose Pair. Pair records the Mac's
acceptance as owed to that phone, in the same write. The Mac sends it as a
signed `pairing_confirmed` message naming the device when it starts speaking to
the phone, when Pair is chosen, and whenever a phone is heard from; the phone
takes it whether or not it is still waiting, and answers with the signed
`pairingConfirmed` action, which clears what is owed. Each acceptance has its
own identity (`acceptance`), carried by the confirmation and by the Mac's
`pairDevice` answer and echoed by the acknowledgement, so an acknowledgement of
an earlier pairing never settles a later one. The phone takes a confirmation in
any state, including mid-repair. Until then the Mac shows the phone as paired
here and waiting for the phone to confirm, not as able to approve. A record from
before this field is owed once. Every Connect first re-reads the Mac's pairing
key from iCloud. A phone message the Mac cannot verify is answered with the
unsigned `signature_invalid_resync` wake-up; the phone re-reads the key and a
waiting Connect goes again under it. Requests
from a new signed phone can appear in this list before Connect is tapped.
Remove immediately withdraws approval authority; a durable removed record
prevents automatic enrollment from delayed messages. To pair that identity
again, its explicit Connect request can ask for local confirmation again.

The Mac stores `paired_phones.json` under its existing data root. Records contain
the public key, its SHA-256 fingerprint as device ID, pending/paired/removed
status, the current `acceptance` identity, and `confirmed` once the phone
acknowledged it. Only the
Mac Pair button promotes a pending key. Missing storage starts empty; malformed, unreadable, or nonregular storage refuses mutations and
decisions without replacing its contents. No private device key reaches the Mac.

The Mac publishes pairing material through CloudKit, with no KVS publication or
synchronization checkpoint. Its unsigned resync hint retains the shared wire
schema's local `pairing_secret_version` field.

The Mac's paired-phone snapshot publishes reloads through `LatestRead` and
committed status changes through its `write` boundary. A newer pending read
does not suppress an older completed read; canceled reads publish nothing.

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

Each handshake step says where it stands. The Mac's pairing fact names when it
sent its acceptance, or why it could not. An acknowledgement echoing an earlier
acceptance is answered with an error naming it and met with the current
acceptance at once. The phone awaits the Mac's answer to its acknowledgement and
its Connection pairing line says whether it is still telling the Mac, was turned
away (with the Mac's reason), or did not reach the Mac. "Pairing key is here"
means the phone holds the key the Mac publishes now.
