# Test Fixtures

Static test data shared across `StowSharedTests` and `StowTests`.

Subdirectories are added on demand; expect:

- `DataStore/` — sample `data.json` files exercising schema versions and corrupt-byte cases
- `CloudKit/` — fixture `CKRecord`-shaped payloads for `CloudSyncManager` merge tests
- `Clipboard/` — sample clipboard contents for `ClipboardImportParser` tests
- `iOSSeed/` — JSON snapshots that the iOS app reads via the `STOW_SEED_FIXTURE` debug env var
