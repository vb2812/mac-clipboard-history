# Roadmap: not built yet, and why

| Item | From | Why not now | Next step |
|---|---|---|---|
| iCloud sync (opt-in, off by default) | Win+V parity P21, S-08 | L effort and high risk. It needs a CloudKit container and entitlements, which need a provisioning profile; this Mac has only an Apple Development identity. It also needs per-item encryption and conflict rules for pins and deletes. Syncing clipboard history raises the privacy stakes, so it deserves its own design pass | CloudKit private DB with `CKSyncEngine`; sync only pinned items at first; end-to-end encrypted fields |
| One-time menu bar hint | S-07 | Low value; onboarding covers it | — |
| Encryption at rest | Phase 5 #6 | FileVault covers data at rest. An app-level key in the Keychain would protect against other processes running as the same user only if the DB key were access-group-locked, which needs a signed, sandboxed or app-group setup | Revisit with the Developer ID build |
| Store app-private pasteboard types | D13 | Forcing lazy providers (Pages, Figma) to render can be slow and huge | Opt-in "keep all formats" with a size cap |
