const {
  onDocumentCreated,
  onDocumentUpdated,
  onDocumentWritten,
} = require("firebase-functions/v2/firestore");
const {onCall, onRequest, HttpsError} = require("firebase-functions/v2/https");
const {initializeApp} = require("firebase-admin/app");
const {getAuth} = require("firebase-admin/auth");
const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {getMessaging} = require("firebase-admin/messaging");

initializeApp();

function asString(value) {
  return typeof value === "string" ? value.trim() : "";
}

function asNonEmpty(value, fallback) {
  const v = asString(value);
  return v || fallback;
}

function asUnread(value) {
  if (typeof value === "number" && Number.isFinite(value)) {
    return Math.max(0, Math.floor(value));
  }
  return 0;
}

function extractInviteId(input) {
  const raw = asString(input);
  if (!raw) return "";

  const codeOnly = raw.toUpperCase();
  if (/^[A-Z2-9]{6,20}$/.test(codeOnly)) return codeOnly;

  const normalized = /^https?:\/\//i.test(raw) ? raw : `https://${raw}`;
  let url;
  try {
    url = new URL(normalized);
  } catch (_) {
    return "";
  }

  if (url.protocol.replace(":", "").toLowerCase() === "noonchat") {
    const host = asString(url.hostname).toLowerCase();
    const parts = url.pathname.split("/").filter(Boolean);
    if ((host === "invite" || host === "join") && parts.length >= 1) {
      const id = asString(parts[0]).toUpperCase();
      if (/^[A-Z2-9]{6,20}$/.test(id)) return id;
    }
  }

  const byQuery = asString(url.searchParams.get("invite")).toUpperCase();
  if (/^[A-Z2-9]{6,20}$/.test(byQuery)) return byQuery;

  const segments = url.pathname.split("/").filter(Boolean);
  if (segments.length >= 2) {
    const first = segments[0].toLowerCase();
    const second = asString(segments[1]).toUpperCase();
    if ((first === "invite" || first === "join") &&
        /^[A-Z2-9]{6,20}$/.test(second)) {
      return second;
    }
  }

  return "";
}

function messagePreview(msg) {
  if (msg.type === "image") return "Sent a photo";
  if (msg.type === "file") return "Sent a file";
  if (msg.type === "audio") return "Sent a voice message";
  if (msg.type === "call") {
    return msg.callType === "video" ? "Video call" : "Voice call";
  }
  return asNonEmpty(msg.text, "New message");
}

function parseRequestBody(req) {
  const body = req.body;
  if (!body) return {};
  if (typeof body === "object") return body;
  if (typeof body !== "string") return {};
  try {
    return JSON.parse(body);
  } catch (_) {
    return {};
  }
}

function validTokenFromHeader(req) {
  const raw = asString(req.headers?.authorization || "");
  const match = raw.match(/^Bearer\s+(.+)$/i);
  if (!match) return "";
  return asString(match[1]);
}

function asParticipantList(value) {
  if (!Array.isArray(value)) return [];
  return value
      .map((v) => asString(v))
      .filter((v) => v);
}

function collectTokensFromUserDoc(userData) {
  const set = new Set();
  const single = asString(userData?.fcmToken);
  if (single) set.add(single);

  const list = userData?.fcmTokens;
  if (Array.isArray(list)) {
    list.forEach((v) => {
      const token = asString(v);
      if (token) set.add(token);
    });
  } else if (list && typeof list === "object") {
    Object.values(list).forEach((v) => {
      const token = asString(v);
      if (token) set.add(token);
    });
  }
  return Array.from(set);
}

function isTokenPermanentlyInvalid(errorCode) {
  return errorCode === "messaging/registration-token-not-registered" ||
    errorCode === "messaging/invalid-registration-token" ||
    errorCode === "messaging/invalid-argument";
}

async function resolveConversationRef(db, conversationId) {
  const chatRef = db.collection("chats").doc(conversationId);
  const chatSnap = await chatRef.get();
  if (chatSnap.exists) {
    return {ref: chatRef, snap: chatSnap, collectionName: "chats"};
  }
  const convRef = db.collection("conversations").doc(conversationId);
  const convSnap = await convRef.get();
  if (convSnap.exists) {
    return {ref: convRef, snap: convSnap, collectionName: "conversations"};
  }
  return null;
}

async function deleteCollectionInBatches(db, collectionRef, batchSize = 400) {
  while (true) {
    const snap = await collectionRef.limit(batchSize).get();
    if (snap.empty) return;
    const batch = db.batch();
    snap.docs.forEach((doc) => batch.delete(doc.ref));
    await batch.commit();
    if (snap.size < batchSize) return;
  }
}

exports.deleteMyAccount = onCall(async (request) => {
  const uid = request.auth?.uid;
  if (!uid) {
    throw new HttpsError("unauthenticated", "Sign-in required.");
  }

  const db = getFirestore();
  const userRef = db.collection("users").doc(uid);

  await deleteCollectionInBatches(db, userRef.collection("inbox"));
  await deleteCollectionInBatches(db, userRef.collection("fcmTokens"));
  await userRef.delete();

  try {
    await getAuth().deleteUser(uid);
  } catch (e) {
    if (e?.code !== "auth/user-not-found") {
      throw new HttpsError("internal", "Failed to delete auth account.");
    }
  }

  return {ok: true};
});

exports.acceptInvite = onCall(async (request) => {
  const uid = request.auth?.uid;
  if (!uid) {
    throw new HttpsError("unauthenticated", "Sign-in required.");
  }

  const inviteId = extractInviteId(request.data?.inviteLink || request.data?.link || "");
  if (!inviteId) {
    throw new HttpsError("invalid-argument", "Invalid invite link.");
  }

  const db = getFirestore();
  const result = await db.runTransaction(async (tx) => {
    const inviteRef = db.collection("invites").doc(inviteId);
    const inviteSnap = await tx.get(inviteRef);
    if (!inviteSnap.exists) {
      throw new HttpsError("not-found", "Invite not found.");
    }

    const invite = inviteSnap.data() || {};
    const chatId = asString(invite.chatId);
    const inviterUid = asString(invite.inviterUid);
    const usedBy = asString(invite.usedBy);
    if (!chatId || !inviterUid) {
      throw new HttpsError("failed-precondition", "Invite data is invalid.");
    }

    const chatRef = db.collection("chats").doc(chatId);
    const chatSnap = await tx.get(chatRef);
    if (!chatSnap.exists) {
      throw new HttpsError("not-found", "Chat not found.");
    }

    const participants = Array.isArray(chatSnap.data()?.participants) ?
      chatSnap.data().participants.filter((v) => typeof v === "string" && v.trim()) : [];
    const alreadyParticipant = participants.includes(uid);
    const inviterClaimOnly = !!usedBy &&
      usedBy === inviterUid &&
      participants.length === 1 &&
      participants.includes(inviterUid);
    if (!alreadyParticipant && participants.length >= 2) {
      throw new HttpsError("failed-precondition", "Chat already has two participants.");
    }
    if (!alreadyParticipant && usedBy && usedBy !== uid && !(inviterClaimOnly && uid !== inviterUid)) {
      throw new HttpsError("failed-precondition", "Invite already used.");
    }
    const nextParticipants = Array.from(new Set([...participants, uid]));

    const meRef = db.collection("users").doc(uid);
    const inviterRef = db.collection("users").doc(inviterUid);
    const meSnap = await tx.get(meRef);
    const inviterSnap = await tx.get(inviterRef);
    const meData = meSnap.data() || {};
    const inviterData = inviterSnap.data() || {};
    const meName = asNonEmpty(meData.name, "Noon User");
    const mePhoto = asString(meData.photo);
    const inviterName = asNonEmpty(inviterData.name, "New chat");
    const inviterPhoto = asString(inviterData.photo);
    const now = FieldValue.serverTimestamp();

    const shouldClaimInvite = !alreadyParticipant && (!usedBy || usedBy === uid || inviterClaimOnly);
    if (shouldClaimInvite) {
      tx.set(inviteRef, {
        usedBy: uid,
        usedAt: now,
      }, {merge: true});
    }

    tx.set(chatRef, {
      participants: nextParticipants,
      updatedAt: now,
    }, {merge: true});

    tx.set(
        meRef.collection("inbox").doc(chatId),
        {
          chatId,
          peerUid: inviterUid,
          title: inviterName,
          photo: inviterPhoto,
          lastText: asString(chatSnap.data()?.lastMessage),
          lastTime: chatSnap.data()?.lastMessageAt || now,
          type: "personal",
          unread: 0,
          updatedAt: now,
        },
        {merge: true},
    );

    tx.set(
        inviterRef.collection("inbox").doc(chatId),
        {
          chatId,
          peerUid: uid,
          title: meName,
          photo: mePhoto,
          lastTime: chatSnap.data()?.lastMessageAt || now,
          type: "personal",
          updatedAt: now,
        },
        {merge: true},
    );

    return {chatId};
  });

  return result;
});

exports.sendReply = onRequest({cors: true}, async (req, res) => {
  if (req.method !== "POST") {
    res.status(405).json({error: "method-not-allowed"});
    return;
  }

  const idToken = validTokenFromHeader(req);
  if (!idToken) {
    res.status(401).json({error: "unauthenticated"});
    return;
  }

  let decoded;
  try {
    decoded = await getAuth().verifyIdToken(idToken, true);
  } catch (_) {
    res.status(401).json({error: "invalid-token"});
    return;
  }

  const body = parseRequestBody(req);
  const uid = asString(body.senderUid) || decoded.uid;
  if (uid !== decoded.uid) {
    res.status(403).json({error: "sender-mismatch"});
    return;
  }

  const conversationId = asString(body.conversationId || body.chatId);
  const replyText = asString(body.replyText || body.text);
  if (!conversationId || !replyText) {
    res.status(400).json({error: "missing-params"});
    return;
  }
  if (replyText.length > 2000) {
    res.status(400).json({error: "text-too-long"});
    return;
  }

  const db = getFirestore();
  const resolved = await resolveConversationRef(db, conversationId);
  if (!resolved) {
    res.status(404).json({error: "conversation-not-found"});
    return;
  }

  const {ref: conversationRef, snap: conversationSnap} = resolved;
  const participants = asParticipantList(conversationSnap.data()?.participants);
  if (!participants.includes(uid)) {
    res.status(403).json({error: "not-a-participant"});
    return;
  }

  const senderSnap = await db.collection("users").doc(uid).get();
  const senderData = senderSnap.data() || {};
  const senderName = asNonEmpty(senderData.name, "Noon User");
  const senderPhoto = asString(senderData.photo);
  const otherUid = participants.find((id) => id !== uid) || "";

  const now = FieldValue.serverTimestamp();
  const msgRef = conversationRef.collection("messages").doc();
  await msgRef.set({
    type: "text",
    text: replyText,
    senderId: uid,
    createdAt: now,
  });

  await conversationRef.set({
    lastMessage: replyText,
    lastMessageAt: now,
    lastSenderId: uid,
    updatedAt: now,
    [`typing.${uid}`]: false,
    [`seenAt.${uid}`]: now,
    [`deliveredAt.${uid}`]: now,
  }, {merge: true});

  const writes = [];
  writes.push(
      db.collection("users").doc(uid).collection("inbox").doc(conversationId).set(
          {
            chatId: conversationId,
            ...(otherUid ? {peerUid: otherUid} : {}),
            lastText: replyText,
            lastTime: now,
            lastSenderId: uid,
            type: "personal",
            unread: 0,
            updatedAt: now,
          },
          {merge: true},
      ),
  );

  if (otherUid) {
    writes.push(
        db.collection("users").doc(otherUid).collection("inbox").doc(conversationId).set(
            {
              chatId: conversationId,
              peerUid: uid,
              title: senderName,
              photo: senderPhoto,
              lastText: replyText,
              lastTime: now,
              lastSenderId: uid,
              type: "personal",
              unread: FieldValue.increment(1),
              updatedAt: now,
            },
            {merge: true},
        ),
    );
  }

  await Promise.all(writes);

  res.status(200).json({
    ok: true,
    conversationId,
    messageId: msgRef.id,
  });
});

async function handleMessageCreated(event, collectionName) {
  const msg = event.data?.data();
  if (!msg) return;

  const conversationId = asString(
      event.params.chatId || event.params.conversationId,
  );
  const messageId = asString(event.params.messageId);
  const senderId = asString(msg.senderId || msg.senderUid || "");
  if (!conversationId || !senderId) return;

  const db = getFirestore();
  const conversationRef = db.collection(collectionName).doc(conversationId);
  const conversationSnap = await conversationRef.get();
  if (!conversationSnap.exists) return;

  const participants = asParticipantList(conversationSnap.data()?.participants);
  if (!participants.length) return;

  const receiverIds = participants.filter((uid) => uid !== senderId);
  const preview = messagePreview(msg);

  const userDocs = await Promise.all(
      participants.map((uid) => db.collection("users").doc(uid).get()),
  );
  const userByUid = {};
  participants.forEach((uid, i) => {
    userByUid[uid] = userDocs[i].data() || {};
  });

  const now = FieldValue.serverTimestamp();
  const inboxBatch = db.batch();
  for (const uid of participants) {
    const otherUid = participants.find((x) => x !== uid) || senderId;
    const otherProfile = userByUid[otherUid] || {};
    inboxBatch.set(
        db.collection("users").doc(uid).collection("inbox").doc(conversationId),
        {
          chatId: conversationId,
          peerUid: otherUid,
          title: asNonEmpty(otherProfile.name, "Chat"),
          photo: asString(otherProfile.photo),
          lastText: preview,
          lastTime: now,
          lastSenderId: senderId,
          type: "personal",
          ...(uid === senderId ? {unread: 0} : {}),
          updatedAt: now,
        },
        {merge: true},
    );
  }
  await inboxBatch.commit();

  if (!receiverIds.length) return;

  const senderName = asNonEmpty(userByUid[senderId]?.name, "Noon Chat");
  const tokenSnapshots = await Promise.all(receiverIds.map((uid) =>
    db.collection("users").doc(uid).collection("fcmTokens").get(),
  ));
  const receiverInbox = await Promise.all(receiverIds.map((uid) =>
    db.collection("users").doc(uid).collection("inbox").doc(conversationId).get(),
  ));

  const unreadByUid = {};
  receiverIds.forEach((uid, i) => {
    unreadByUid[uid] = asUnread(receiverInbox[i].data()?.unread);
  });

  const tokenRecords = [];
  const seenTokenByUid = {};
  receiverIds.forEach((uid, index) => {
    seenTokenByUid[uid] = new Set();

    tokenSnapshots[index].docs.forEach((doc) => {
      const token = asString(doc.data().token);
      if (!token || seenTokenByUid[uid].has(token)) return;
      seenTokenByUid[uid].add(token);
      tokenRecords.push({uid, token});
    });

    collectTokensFromUserDoc(userByUid[uid]).forEach((token) => {
      if (!token || seenTokenByUid[uid].has(token)) return;
      seenTokenByUid[uid].add(token);
      tokenRecords.push({uid, token});
    });
  });

  if (!tokenRecords.length) return;

  const messagingPayloads = tokenRecords.map((record) => ({
    token: record.token,
    notification: {
      title: senderName,
      body: preview,
    },
    data: {
      type: "chat",
      chatId: conversationId,
      conversationId,
      senderId,
      senderName,
      messageId,
      textPreview: preview,
    },
    android: {
      priority: "high",
      ttl: "86400s",
      collapseKey: `chat_${conversationId}`,
      notification: {
        channelId: "chat_high",
        tag: `chat_${conversationId}`,
        sound: "default",
        defaultSound: true,
        clickAction: "FLUTTER_NOTIFICATION_CLICK",
        notificationCount: unreadByUid[record.uid] || 1,
      },
    },
    apns: {
      headers: {
        "apns-priority": "10",
      },
      payload: {
        aps: {
          sound: "default",
          badge: unreadByUid[record.uid] || 1,
          category: "CHAT_REPLY",
          "thread-id": `chat_${conversationId}`,
          "mutable-content": 1,
        },
      },
    },
  }));

  const sendResult = await getMessaging().sendEach(messagingPayloads);
  const deliveredUids = new Set();
  const invalidTokensByUid = {};

  sendResult.responses.forEach((response, index) => {
    const uid = tokenRecords[index].uid;
    const token = tokenRecords[index].token;
    if (response.success) {
      deliveredUids.add(uid);
      return;
    }
    const errorCode = asString(response.error?.code);
    if (!isTokenPermanentlyInvalid(errorCode)) return;
    if (!invalidTokensByUid[uid]) invalidTokensByUid[uid] = new Set();
    invalidTokensByUid[uid].add(token);
  });

  if (deliveredUids.size > 0) {
    const deliveredUpdate = {updatedAt: FieldValue.serverTimestamp()};
    deliveredUids.forEach((uid) => {
      deliveredUpdate[`deliveredAt.${uid}`] = FieldValue.serverTimestamp();
    });
    await conversationRef.set(deliveredUpdate, {merge: true});
  }

  if (Object.keys(invalidTokensByUid).length === 0) return;

  const cleanupBatch = db.batch();
  receiverIds.forEach((uid, index) => {
    const invalidTokens = Array.from(invalidTokensByUid[uid] || []);
    if (!invalidTokens.length) return;

    tokenSnapshots[index].docs.forEach((tokenDoc) => {
      const token = asString(tokenDoc.data().token);
      if (token && invalidTokens.includes(token)) {
        cleanupBatch.delete(tokenDoc.ref);
      }
    });

    cleanupBatch.set(
        db.collection("users").doc(uid),
        {
          fcmTokens: FieldValue.arrayRemove(...invalidTokens),
          fcmUpdatedAt: FieldValue.serverTimestamp(),
        },
        {merge: true},
    );

    const singleToken = asString(userByUid[uid]?.fcmToken);
    if (singleToken && invalidTokens.includes(singleToken)) {
      cleanupBatch.set(
          db.collection("users").doc(uid),
          {
            fcmToken: FieldValue.delete(),
            fcmUpdatedAt: FieldValue.serverTimestamp(),
          },
          {merge: true},
      );
    }
  });
  await cleanupBatch.commit();
}

exports.onMessageCreated = onDocumentCreated(
    "chats/{chatId}/messages/{messageId}",
    async (event) => handleMessageCreated(event, "chats"),
);

exports.onConversationMessageCreated = onDocumentCreated(
    "conversations/{conversationId}/messages/{messageId}",
    async (event) => handleMessageCreated(event, "conversations"),
);

exports.onInboxWritten = onDocumentWritten(
    "users/{uid}/inbox/{chatId}",
    async (event) => {
      const uid = event.params.uid;
      const before = event.data?.before?.data() || {};
      const after = event.data?.after?.data() || {};

      const beforeUnread = asUnread(before.unread);
      const afterUnread = event.data?.after?.exists ? asUnread(after.unread) : 0;
      const delta = afterUnread - beforeUnread;
      if (delta === 0) return;

      const db = getFirestore();
      const userRef = db.collection("users").doc(uid);
      await db.runTransaction(async (tx) => {
        const userSnap = await tx.get(userRef);
        const current = asUnread(userSnap.data()?.unreadTotal);
        const next = Math.max(0, current + delta);
        tx.set(userRef, {
          unreadTotal: next,
          unreadTotalUpdatedAt: FieldValue.serverTimestamp(),
        }, {merge: true});
      });
    },
);

exports.onUserProfileUpdated = onDocumentUpdated(
    "users/{uid}",
    async (event) => {
      const uid = event.params.uid;
      const before = event.data?.before?.data() || {};
      const after = event.data?.after?.data() || {};
      const beforeName = asString(before.name);
      const beforePhoto = asString(before.photo);
      const nextName = asNonEmpty(after.name, "Noon User");
      const nextPhoto = asString(after.photo);

      if (beforeName === nextName && beforePhoto === nextPhoto) return;

      const db = getFirestore();
      const chatsSnap = await db
          .collection("chats")
          .where("participants", "arrayContains", uid)
          .get();
      if (chatsSnap.empty) return;

      let batch = db.batch();
      let ops = 0;
      const commitBatch = async () => {
        if (ops === 0) return;
        await batch.commit();
        batch = db.batch();
        ops = 0;
      };

      for (const chatDoc of chatsSnap.docs) {
        const participants = Array.isArray(chatDoc.data()?.participants) ?
          chatDoc.data().participants.filter((v) => typeof v === "string" && v.trim()) : [];
        if (participants.length !== 2) continue;

        const otherUid = participants.find((p) => p !== uid);
        if (!otherUid) continue;

        batch.set(
            db.collection("users").doc(otherUid).collection("inbox").doc(chatDoc.id),
            {
              chatId: chatDoc.id,
              title: nextName,
              photo: nextPhoto,
              updatedAt: FieldValue.serverTimestamp(),
            },
            {merge: true},
        );
        ops += 1;
        if (ops >= 400) await commitBatch();
      }

      await commitBatch();
    },
);
