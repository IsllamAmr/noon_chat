require('dotenv').config();

const express = require('express');
const cors = require('cors');
const helmet = require('helmet');
const morgan = require('morgan');
const admin = require('firebase-admin');

const PORT = Number(process.env.PORT || 8080);
const ONESIGNAL_APP_ID = (process.env.ONESIGNAL_APP_ID || '').trim();
const ONESIGNAL_REST_KEY = (process.env.ONESIGNAL_REST_KEY || '').trim();
const ONE_SIGNAL_API_URL = 'https://api.onesignal.com/notifications?c=push';

function loadServiceAccountFromEnv() {
  const raw = (process.env.FIREBASE_SERVICE_ACCOUNT_JSON || '').trim();
  if (!raw) {
    throw new Error('FIREBASE_SERVICE_ACCOUNT_JSON is required');
  }

  try {
    return JSON.parse(raw);
  } catch (_) {
    const decoded = Buffer.from(raw, 'base64').toString('utf8');
    return JSON.parse(decoded);
  }
}

function assertEnv() {
  if (!ONESIGNAL_APP_ID) {
    throw new Error('ONESIGNAL_APP_ID is required');
  }
  if (!ONESIGNAL_REST_KEY) {
    throw new Error('ONESIGNAL_REST_KEY is required');
  }
}

function bearerTokenFromHeader(headerValue) {
  const header = (headerValue || '').trim();
  const match = header.match(/^Bearer\s+(.+)$/i);
  return match ? match[1].trim() : '';
}

function asString(value) {
  return typeof value === 'string' ? value.trim() : '';
}

function isValidConversationParticipants(participants, fromUid, toUid) {
  if (!Array.isArray(participants)) return false;
  return participants.includes(fromUid) && participants.includes(toUid);
}

async function resolveConversation(db, conversationId) {
  const chatRef = db.collection('chats').doc(conversationId);
  const chatSnap = await chatRef.get();
  if (chatSnap.exists) {
    return chatSnap;
  }

  const convRef = db.collection('conversations').doc(conversationId);
  const convSnap = await convRef.get();
  return convSnap.exists ? convSnap : null;
}

async function sendOneSignalPush({
  oneSignalId,
  senderName,
  textPreview,
  toUid,
  fromUid,
  conversationId,
}) {
  const configuredAndroidChannelId = (
    process.env.ONESIGNAL_ANDROID_CHANNEL_ID || ''
  ).trim();

  const payload = {
    app_id: ONESIGNAL_APP_ID,
    include_subscription_ids: [oneSignalId],
    headings: {
      en: senderName || 'Noon Chat',
    },
    contents: {
      en: textPreview || 'New message',
    },
    data: {
      type: 'chat',
      conversationId,
      toUid,
      senderId: fromUid,
    },
    target_channel: 'push',
    collapse_id: `chat_${conversationId}`,
    android_group: `chat_${conversationId}`,
    priority: 10,
    ttl: 86400,
  };

  if (configuredAndroidChannelId) {
    payload.android_channel_id = configuredAndroidChannelId;
  }

  const response = await fetch(ONE_SIGNAL_API_URL, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Key ${ONESIGNAL_REST_KEY}`,
    },
    body: JSON.stringify(payload),
  });

  const text = await response.text();
  let json;
  try {
    json = JSON.parse(text);
  } catch (_) {
    json = {raw: text};
  }

  if (!response.ok) {
    const error = new Error(
      `OneSignal request failed with status ${response.status}`,
    );
    error.details = json;
    throw error;
  }

  return json;
}

async function main() {
  assertEnv();
  const serviceAccount = loadServiceAccountFromEnv();
  admin.initializeApp({
    credential: admin.credential.cert(serviceAccount),
  });

  const db = admin.firestore();
  const app = express();

  app.use(helmet());
  app.use(cors());
  app.use(express.json({limit: '1mb'}));
  app.use(morgan('tiny'));

  app.get('/health', (_, res) => {
    res.status(200).json({ok: true, service: 'onesignal-notify'});
  });

  app.post('/notify', async (req, res) => {
    try {
      const idToken = bearerTokenFromHeader(req.headers.authorization);
      if (!idToken) {
        return res.status(401).json({ok: false, error: 'missing-auth-token'});
      }

      const decoded = await admin.auth().verifyIdToken(idToken, true);
      const fromUid = decoded.uid;

      const toUid = asString(req.body?.toUid);
      const conversationId = asString(req.body?.conversationId);
      const senderName = asString(req.body?.senderName);
      const textPreview = asString(req.body?.textPreview) || 'New message';

      if (!toUid || !conversationId) {
        return res.status(400).json({ok: false, error: 'missing-required-fields'});
      }
      if (toUid === fromUid) {
        return res.status(400).json({ok: false, error: 'cannot-notify-self'});
      }

      const conversationSnap = await resolveConversation(db, conversationId);
      if (!conversationSnap) {
        return res.status(404).json({ok: false, error: 'conversation-not-found'});
      }

      const participants = conversationSnap.data()?.participants || [];
      if (!isValidConversationParticipants(participants, fromUid, toUid)) {
        return res.status(403).json({ok: false, error: 'sender-not-in-conversation'});
      }

      const recipientSnap = await db.collection('users').doc(toUid).get();
      if (!recipientSnap.exists) {
        return res.status(404).json({ok: false, error: 'recipient-not-found'});
      }

      const oneSignalId = asString(recipientSnap.data()?.oneSignalId);
      if (!oneSignalId) {
        return res.status(200).json({
          ok: true,
          skipped: true,
          reason: 'recipient-has-no-onesignal-id',
        });
      }

      const result = await sendOneSignalPush({
        oneSignalId,
        senderName,
        textPreview,
        toUid,
        fromUid,
        conversationId,
      });

      return res.status(200).json({ok: true, result});
    } catch (error) {
      const message =
        error && typeof error.message === 'string'
          ? error.message
          : 'notify-failed';
      return res.status(500).json({
        ok: false,
        error: message,
        details: error.details || null,
      });
    }
  });

  app.listen(PORT, () => {
    // eslint-disable-next-line no-console
    console.log(`notify backend listening on port ${PORT}`);
  });
}

main().catch((error) => {
  // eslint-disable-next-line no-console
  console.error('Fatal startup error:', error);
  process.exit(1);
});
