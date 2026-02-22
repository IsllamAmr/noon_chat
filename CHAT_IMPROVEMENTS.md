# Flutter Chat Improvements (Based on provided `chat_service.dart` and `chat_screen.dart`)

## 1) Reliability and data consistency

- Keep one sender field only (`senderId`) and migrate old `senderUid` values to avoid dual-read forever.
- Ensure every message has `createdAt` to keep `orderBy('createdAt')` stable.
- Add a client fallback timestamp field (example: `createdAtClient`) to render pending messages before server timestamp resolves.

## 2) Read/unread accuracy

- Reset unread count to `0` for current user when opening the chat screen.
- Increment unread only for other participants (already done correctly in your transaction).
- Store per-user `lastReadAt` in chat membership data to support read receipts later.

## 3) Chat list correctness

- Avoid static inbox values (`title: "Chat"`, `photo: ""`).
- Resolve title/photo per recipient (other participant name/photo in 1:1 chats, group metadata for group chats).

## 4) UX and performance in `ChatScreen`

- Disable send button while request is in flight to prevent duplicate sends.
- Trim and validate message length (e.g., max 2,000 chars).
- Add empty/error states for `StreamBuilder` (`snapshot.hasError`).
- Optionally paginate messages if rooms can become large.

## 5) Security and rules checklist

- Firestore rules should enforce:
  - only chat participants can read messages,
  - only authenticated users can write,
  - `senderId == request.auth.uid` for new messages.

## 6) Small code changes to apply next

1. Add unread reset method in `ChatService` (called from `initState` of `ChatScreen`).
2. Add `_sending` state in `ChatScreen` and disable the send button during send.
3. Add `snapshot.hasError` UI and a retry hint.
4. Replace hardcoded inbox `title/photo` with participant-derived values.

---

If you share your `inbox_service.dart` and Firestore rules, we can produce a fully safe refactor patch next.
