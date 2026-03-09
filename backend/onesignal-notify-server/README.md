# OneSignal Notify Backend

Minimal secure backend for chat push notifications without Firebase Blaze/Cloud Functions.

## Endpoints

- `GET /health`
- `POST /notify`

`POST /notify` requires:

- Header: `Authorization: Bearer <Firebase ID Token>`
- Body:
```json
{
  "toUid": "recipient_uid",
  "conversationId": "chat_or_conversation_id",
  "senderName": "Islam",
  "textPreview": "Hello"
}
```

The backend verifies Firebase token, validates conversation membership, reads `users/{toUid}.oneSignalId`, then sends OneSignal push.

## Environment Variables

- `ONESIGNAL_APP_ID`
- `ONESIGNAL_REST_KEY`
- `FIREBASE_SERVICE_ACCOUNT_JSON` (raw JSON or base64 JSON)
- `PORT` (optional)
- `ONESIGNAL_ANDROID_CHANNEL_ID` (optional, use OneSignal dashboard channel ID)

## Run locally

```bash
npm install
npm run start
```

## Deploy (Render/Fly/Railway)

1. Create new Node service.
2. Set env vars above.
3. Start command: `npm run start`.
4. Copy public URL and pass it to Flutter:
```bash
--dart-define=NOTIFY_BACKEND_URL=https://your-service-url
```
