# Firebase Cleanup Tools (Safe)

This folder contains **server-side** cleanup scripts for Firestore/Auth/Storage.
They are designed with strict safety defaults:

- Default mode is **dry-run** (no deletions).
- Every run creates a **backup JSON** first.
- Real delete requires explicit `--confirm-delete`.
- Deletion targets only users/chats matching **test/old filters**.

## 1) Install

```bash
cd admin-tools
npm install
```

## 2) Required environment variables

```bash
export FIREBASE_PROJECT_ID="your-project-id"
export GOOGLE_APPLICATION_CREDENTIALS="/absolute/path/service-account.json"
export CUTOFF_DATE="2025-01-01T00:00:00Z"
```

Notes:
- `CUTOFF_DATE` is optional, but recommended.
- Users are targeted when at least one matches:
  - `email` ends with `@test.com`
  - `isTest == true` (or `test == true`)
  - `createdAt < CUTOFF_DATE`

## 3) Dry-run (safe, no delete)

```bash
node dry-run-delete.js
```

Optional flags:
- `--delete-auth` include matching Auth users (test users only)
- `--delete-storage` include `stories/{uid}/...` files
- `--skip-stories` skip stories cleanup scan

Dry-run prints a summary and writes a backup file:
- `admin-tools/backups/cleanup-backup-<timestamp>.json`

## 4) Confirm delete (destructive)

```bash
node delete-confirm.js --confirm-delete
```

Optional flags (same as dry-run):
- `--delete-auth`
- `--delete-storage`
- `--skip-stories`

Extra safety:
- On non-dev project IDs, script refuses destructive delete by default.
- To override (dangerous), add `--allow-prod-delete` or env `ALLOW_PROD_DELETE=true`.

## 5) What gets cleaned

- Firestore:
  - `users/{uid}` (targeted only) + known subcollections:
    - `users/{uid}/inbox/*`
    - `users/{uid}/fcmTokens/*`
  - `conversations/*` and `chats/*` if old or member is targeted user
  - `messages/*` under targeted conversations/chats
  - `stories/*` (targeted test/old users) + `views/*`
- Auth (optional):
  - matching test users only
- Storage (optional):
  - `stories/{uid}/...` for targeted users

## 6) Idempotency

The scripts are safe to re-run:
- Missing docs/users/files are skipped.
- Failures are logged and processing continues.
