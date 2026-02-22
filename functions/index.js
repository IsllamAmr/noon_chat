const {
  onDocumentCreated,
  onDocumentUpdated,
  onDocumentWritten,
} = require("firebase-functions/v2/firestore");
const {onCall, HttpsError} = require("firebase-functions/v2/https");
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

exports.onMessageCreated = onDocumentCreated(
    "chats/{chatId}/messages/{messageId}",
    async (event) => {
      const msg = event.data?.data();
      if (!msg) return;

      const chatId = event.params.chatId;
      const senderId = asString(msg.senderId || msg.senderUid || "");
      if (!senderId) return;

      const db = getFirestore();
      const chatRef = db.collection("chats").doc(chatId);
      const chatSnap = await chatRef.get();
      if (!chatSnap.exists) return;

      const participants = Array.isArray(chatSnap.data()?.participants) ?
        chatSnap.data().participants.filter((v) => typeof v === "string" && v.trim()) : [];
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

      const batch = db.batch();
      const now = FieldValue.serverTimestamp();
      for (const uid of participants) {
        const otherUid = participants.find((x) => x !== uid) || senderId;
        const otherProfile = userByUid[otherUid] || {};
        batch.set(
            db.collection("users").doc(uid).collection("inbox").doc(chatId),
            {
              chatId,
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
      await batch.commit();

      if (!receiverIds.length) return;

      const senderName = asNonEmpty(userByUid[senderId]?.name, "Noon Chat");
      const tokenSnapshots = await Promise.all(receiverIds.map((uid) =>
        db.collection("users").doc(uid).collection("fcmTokens").get(),
      ));
      const receiverInbox = await Promise.all(receiverIds.map((uid) =>
        db.collection("users").doc(uid).collection("inbox").doc(chatId).get(),
      ));

      const unreadByUid = {};
      receiverIds.forEach((uid, i) => {
        unreadByUid[uid] = asUnread(receiverInbox[i].data()?.unread);
      });

      const tokenRecords = [];
      receiverIds.forEach((uid, index) => {
        tokenSnapshots[index].docs.forEach((doc) => {
          const token = asString(doc.data().token);
          if (token) tokenRecords.push({uid, token});
        });
      });
      if (!tokenRecords.length) return;

      const messages = tokenRecords.map((r) => ({
        token: r.token,
        notification: {
          title: senderName,
          body: preview,
        },
        data: {
          type: "chat_message",
          chatId,
          senderId,
        },
        android: {
          priority: "high",
          notification: {
            channelId: "chat_messages",
            sound: "default",
            defaultSound: true,
            notificationCount: unreadByUid[r.uid] || 1,
          },
        },
        apns: {
          payload: {
            aps: {
              sound: "default",
              badge: unreadByUid[r.uid] || 1,
            },
          },
        },
      }));

      const result = await getMessaging().sendEach(messages);
      const deliveredUids = new Set();
      result.responses.forEach((resp, index) => {
        if (resp.success) {
          deliveredUids.add(tokenRecords[index].uid);
        }
      });
      if (deliveredUids.size > 0) {
        const deliveredUpdate = {updatedAt: FieldValue.serverTimestamp()};
        deliveredUids.forEach((uid) => {
          deliveredUpdate[`deliveredAt.${uid}`] = FieldValue.serverTimestamp();
        });
        await chatRef.set(deliveredUpdate, {merge: true});
      }

      if (result.failureCount <= 0) return;

      const badTokens = [];
      result.responses.forEach((resp, index) => {
        if (!resp.success) badTokens.push(tokenRecords[index].token);
      });
      if (!badTokens.length) return;

      const cleanupBatch = db.batch();
      receiverIds.forEach((uid, i) => {
        tokenSnapshots[i].docs.forEach((tokenDoc) => {
          const token = asString(tokenDoc.data().token);
          if (token && badTokens.includes(token)) {
            cleanupBatch.delete(tokenDoc.ref);
          }
        });
      });
      await cleanupBatch.commit();
    },
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
