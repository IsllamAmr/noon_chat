const fs = require('fs');
const path = require('path');
const admin = require('firebase-admin');

const COLLECTION_SCAN_PAGE = 300;
const DELETE_BATCH_SIZE = 450;
const SAFE_PROJECT_REGEX = /(dev|test|staging|sandbox|local|demo)/i;

function nowIso() {
  return new Date().toISOString();
}

function toDate(value) {
  if (!value) return null;
  if (value instanceof Date) return value;
  if (typeof value.toDate === 'function') {
    try {
      return value.toDate();
    } catch (_) {
      return null;
    }
  }
  const asDate = new Date(value);
  if (Number.isNaN(asDate.getTime())) return null;
  return asDate;
}

function toBooleanEnv(value, fallback = false) {
  if (value == null) return fallback;
  const normalized = String(value).trim().toLowerCase();
  return normalized === '1' || normalized === 'true' || normalized === 'yes';
}

function parseCliArgs(argv) {
  const args = new Set(argv);
  return {
    confirmDelete: args.has('--confirm-delete'),
    includeStories: !args.has('--skip-stories'),
    deleteAuth: args.has('--delete-auth') || toBooleanEnv(process.env.DELETE_AUTH_USERS, false),
    deleteStorage:
      args.has('--delete-storage') || toBooleanEnv(process.env.DELETE_STORAGE_FILES, false),
    allowProdDelete:
      args.has('--allow-prod-delete') ||
      toBooleanEnv(process.env.ALLOW_PROD_DELETE, false),
  };
}

function sanitizeForJson(value) {
  if (value == null) return null;
  if (Array.isArray(value)) return value.map(sanitizeForJson);
  if (typeof value !== 'object') return value;
  const asDate = toDate(value);
  if (asDate) return asDate.toISOString();
  const output = {};
  for (const [k, v] of Object.entries(value)) {
    output[k] = sanitizeForJson(v);
  }
  return output;
}

function readConfig(argv, forceConfirmMode) {
  const cli = parseCliArgs(argv);
  const projectId = (process.env.FIREBASE_PROJECT_ID || '').trim();
  if (!projectId) {
    throw new Error('Missing required env var FIREBASE_PROJECT_ID');
  }

  const cutoffRaw = (process.env.CUTOFF_DATE || '').trim();
  const cutoffDate = cutoffRaw ? toDate(cutoffRaw) : null;
  if (cutoffRaw && !cutoffDate) {
    throw new Error('CUTOFF_DATE is invalid. Use ISO format, e.g. 2025-01-01T00:00:00Z');
  }

  const confirmDelete = forceConfirmMode ? cli.confirmDelete : false;
  const isDevProject = SAFE_PROJECT_REGEX.test(projectId);

  return {
    projectId,
    cutoffDate,
    cutoffRaw: cutoffDate ? cutoffDate.toISOString() : '',
    confirmDelete,
    isDevProject,
    includeStories: cli.includeStories,
    deleteAuth: cli.deleteAuth,
    deleteStorage: cli.deleteStorage,
    allowProdDelete: cli.allowProdDelete,
    credentialsPath: (process.env.GOOGLE_APPLICATION_CREDENTIALS || '').trim(),
  };
}

function ensureSafeDeleteMode(config) {
  if (!config.confirmDelete) {
    throw new Error('Deletion is disabled. Pass --confirm-delete to proceed.');
  }
  if (!config.isDevProject && !config.allowProdDelete) {
    throw new Error(
      `Refusing destructive delete on non-dev project "${config.projectId}". ` +
        'Use --allow-prod-delete only if you are 100% sure.',
    );
  }
}

function isTestEmail(email) {
  return String(email || '').trim().toLowerCase().endsWith('@test.com');
}

function normalizeMemberList(data) {
  const raw = data.participants || data.members || [];
  if (!Array.isArray(raw)) return [];
  const ids = new Set();
  for (const value of raw) {
    const id = String(value || '').trim();
    if (id) ids.add(id);
  }
  return [...ids];
}

function isOlderThanCutoff(data, cutoffDate) {
  if (!cutoffDate) return false;
  const created =
    toDate(data.createdAt) ||
    toDate(data.updatedAt) ||
    toDate(data.lastMessageAt) ||
    toDate(data.expiresAt);
  if (!created) return false;
  return created < cutoffDate;
}

function userDeletionReason(data, cutoffDate) {
  const email = String(data.email || '').trim();
  const byEmail = isTestEmail(email);
  const byFlag = data.isTest === true || data.test === true;
  const byAge = isOlderThanCutoff(data, cutoffDate);
  const shouldDelete = byEmail || byFlag || byAge;
  return {
    shouldDelete,
    byEmail,
    byFlag,
    byAge,
    isTest: byEmail || byFlag,
  };
}

async function initAdmin(projectId) {
  if (!admin.apps.length) {
    admin.initializeApp({
      projectId,
      credential: admin.credential.applicationDefault(),
    });
  }
  return {
    db: admin.firestore(),
    auth: admin.auth(),
    storage: admin.storage(),
  };
}

async function scanCollection(collectionRef, onDoc) {
  let lastDocId = null;
  while (true) {
    let query = collectionRef
      .orderBy(admin.firestore.FieldPath.documentId())
      .limit(COLLECTION_SCAN_PAGE);
    if (lastDocId) {
      query = query.startAfter(lastDocId);
    }
    const snap = await query.get();
    if (snap.empty) break;
    for (const doc of snap.docs) {
      await onDoc(doc);
    }
    lastDocId = snap.docs[snap.docs.length - 1].id;
    if (snap.size < COLLECTION_SCAN_PAGE) break;
  }
}

async function collectSubcollectionDocs(collectionRef, includeData = false) {
  const docs = [];
  await scanCollection(collectionRef, async (doc) => {
    docs.push({
      id: doc.id,
      path: doc.ref.path,
      data: includeData ? doc.data() : null,
    });
  });
  return docs;
}

async function buildPlan(ctx, config) {
  const { db, auth, storage } = ctx;
  const users = [];
  const userReasons = new Map();
  const userIds = new Set();

  await scanCollection(db.collection('users'), async (doc) => {
    const data = doc.data() || {};
    const reason = userDeletionReason(data, config.cutoffDate);
    if (!reason.shouldDelete) return;

    const inboxDocs = await collectSubcollectionDocs(doc.ref.collection('inbox'), true);
    const tokenDocs = await collectSubcollectionDocs(doc.ref.collection('fcmTokens'), true);

    users.push({
      id: doc.id,
      path: doc.ref.path,
      data,
      reason,
      inboxDocs,
      tokenDocs,
    });
    userReasons.set(doc.id, reason);
    userIds.add(doc.id);
  });

  const conversations = [];
  for (const collectionName of ['conversations', 'chats']) {
    await scanCollection(db.collection(collectionName), async (doc) => {
      const data = doc.data() || {};
      const members = normalizeMemberList(data);
      const hasTargetMember = members.some((uid) => userIds.has(uid));
      const isOld = isOlderThanCutoff(data, config.cutoffDate);
      if (!hasTargetMember && !isOld) return;

      const messages = await collectSubcollectionDocs(doc.ref.collection('messages'), true);
      conversations.push({
        id: doc.id,
        path: doc.ref.path,
        collection: collectionName,
        members,
        data,
        messageDocs: messages,
      });
    });
  }

  const stories = [];
  if (config.includeStories) {
    await scanCollection(db.collection('stories'), async (doc) => {
      const data = doc.data() || {};
      const ownerId = String(
        data.ownerId || data.uid || data.ownerUid || data.userId || '',
      ).trim();
      const ownerIsTarget = ownerId && userIds.has(ownerId);
      const markedTest = data.isTest === true || data.test === true;
      const isOld = isOlderThanCutoff(data, config.cutoffDate);
      const isExpired = (() => {
        const expires = toDate(data.expiresAt);
        return !!expires && expires < new Date();
      })();

      if (!ownerIsTarget && !markedTest) return;
      if (!isOld && !isExpired && !ownerIsTarget && !markedTest) return;

      const views = await collectSubcollectionDocs(doc.ref.collection('views'), true);
      stories.push({
        id: doc.id,
        path: doc.ref.path,
        ownerId,
        data,
        viewDocs: views,
      });
    });
  }

  const storageFiles = [];
  if (config.deleteStorage) {
    try {
      const bucket = storage.bucket();
      for (const user of users) {
        const [files] = await bucket.getFiles({ prefix: `stories/${user.id}/` });
        for (const file of files) {
          storageFiles.push(file.name);
        }
      }
    } catch (e) {
      console.error('[WARN] Failed to scan storage files:', e.message || e);
    }
  }

  const authUsers = [];
  if (config.deleteAuth) {
    for (const user of users) {
      const reason = userReasons.get(user.id);
      if (!reason || !reason.isTest) continue;
      try {
        const authUser = await auth.getUser(user.id);
        const authEmail = String(authUser.email || '').trim();
        const authMarkedTest =
          isTestEmail(authEmail) || (authUser.customClaims || {}).isTest === true;
        if (!authMarkedTest && !reason.byFlag) continue;
        authUsers.push({
          uid: authUser.uid,
          email: authEmail,
        });
      } catch (e) {
        if (e && e.code === 'auth/user-not-found') continue;
        console.error(`[WARN] Failed to inspect auth user ${user.id}:`, e.message || e);
      }
    }
  }

  const summary = {
    users: users.length,
    userInboxDocs: users.reduce((acc, u) => acc + u.inboxDocs.length, 0),
    userTokenDocs: users.reduce((acc, u) => acc + u.tokenDocs.length, 0),
    conversations: conversations.length,
    messages: conversations.reduce((acc, c) => acc + c.messageDocs.length, 0),
    stories: stories.length,
    storyViews: stories.reduce((acc, s) => acc + s.viewDocs.length, 0),
    storageFiles: storageFiles.length,
    authUsers: authUsers.length,
  };

  return { users, conversations, stories, storageFiles, authUsers, summary };
}

function buildBackupPayload(plan, config) {
  return sanitizeForJson({
    metadata: {
      generatedAt: nowIso(),
      projectId: config.projectId,
      cutoffDate: config.cutoffRaw || null,
      includeStories: config.includeStories,
      deleteAuth: config.deleteAuth,
      deleteStorage: config.deleteStorage,
    },
    summary: plan.summary,
    users: plan.users,
    conversations: plan.conversations,
    stories: plan.stories,
    storageFiles: plan.storageFiles,
    authUsers: plan.authUsers,
  });
}

function backupFilePath() {
  const stamp = nowIso().replace(/[:.]/g, '-');
  return path.join(__dirname, '..', 'backups', `cleanup-backup-${stamp}.json`);
}

function ensureDirectory(filePath) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
}

function printSummary(plan, config, backupPath, modeLabel) {
  console.log(`\n=== ${modeLabel} ===`);
  console.log(`Project: ${config.projectId}`);
  console.log(`Cutoff date: ${config.cutoffRaw || '(not set)'}`);
  console.log(`Backup: ${backupPath}`);
  console.log(`Users: ${plan.summary.users}`);
  console.log(`User inbox docs: ${plan.summary.userInboxDocs}`);
  console.log(`User fcm token docs: ${plan.summary.userTokenDocs}`);
  console.log(`Conversations: ${plan.summary.conversations}`);
  console.log(`Messages: ${plan.summary.messages}`);
  console.log(`Stories: ${plan.summary.stories}`);
  console.log(`Story views: ${plan.summary.storyViews}`);
  console.log(`Storage files: ${plan.summary.storageFiles}`);
  console.log(`Auth users: ${plan.summary.authUsers}`);
}

async function deletePathsInBatches(db, paths, label) {
  let deleted = 0;
  let failed = 0;
  for (let i = 0; i < paths.length; i += DELETE_BATCH_SIZE) {
    const chunk = paths.slice(i, i + DELETE_BATCH_SIZE);
    const batch = db.batch();
    for (const p of chunk) {
      batch.delete(db.doc(p));
    }
    try {
      await batch.commit();
      deleted += chunk.length;
      continue;
    } catch (e) {
      console.error(`[WARN] Batch delete failed for ${label}, fallback to single deletes.`);
    }

    for (const p of chunk) {
      try {
        await db.doc(p).delete();
        deleted += 1;
      } catch (e) {
        failed += 1;
        console.error(`[WARN] Failed deleting ${p}:`, e.message || e);
      }
    }
  }
  return { deleted, failed };
}

async function executeDelete(ctx, plan, config) {
  const { db, auth, storage } = ctx;
  const deleteStats = {
    users: { deleted: 0, failed: 0 },
    userInboxDocs: { deleted: 0, failed: 0 },
    userTokenDocs: { deleted: 0, failed: 0 },
    conversations: { deleted: 0, failed: 0 },
    messages: { deleted: 0, failed: 0 },
    stories: { deleted: 0, failed: 0 },
    storyViews: { deleted: 0, failed: 0 },
    storageFiles: { deleted: 0, failed: 0 },
    authUsers: { deleted: 0, failed: 0 },
  };

  const allMessagePaths = plan.conversations.flatMap((c) => c.messageDocs.map((m) => m.path));
  const allConversationPaths = plan.conversations.map((c) => c.path);
  const allStoryViewPaths = plan.stories.flatMap((s) => s.viewDocs.map((v) => v.path));
  const allStoryPaths = plan.stories.map((s) => s.path);
  const allUserInboxPaths = plan.users.flatMap((u) => u.inboxDocs.map((d) => d.path));
  const allUserTokenPaths = plan.users.flatMap((u) => u.tokenDocs.map((d) => d.path));
  const allUserPaths = plan.users.map((u) => u.path);

  deleteStats.messages = await deletePathsInBatches(db, allMessagePaths, 'messages');
  deleteStats.conversations = await deletePathsInBatches(
    db,
    allConversationPaths,
    'conversations',
  );
  deleteStats.storyViews = await deletePathsInBatches(db, allStoryViewPaths, 'story views');
  deleteStats.stories = await deletePathsInBatches(db, allStoryPaths, 'stories');
  deleteStats.userInboxDocs = await deletePathsInBatches(db, allUserInboxPaths, 'user inbox');
  deleteStats.userTokenDocs = await deletePathsInBatches(db, allUserTokenPaths, 'user tokens');
  deleteStats.users = await deletePathsInBatches(db, allUserPaths, 'users');

  if (config.deleteStorage) {
    const bucket = storage.bucket();
    for (const fileName of plan.storageFiles) {
      try {
        await bucket.file(fileName).delete({ ignoreNotFound: true });
        deleteStats.storageFiles.deleted += 1;
      } catch (e) {
        deleteStats.storageFiles.failed += 1;
        console.error(`[WARN] Failed deleting storage file ${fileName}:`, e.message || e);
      }
    }
  }

  if (config.deleteAuth) {
    for (const user of plan.authUsers) {
      try {
        await auth.deleteUser(user.uid);
        deleteStats.authUsers.deleted += 1;
      } catch (e) {
        if (e && e.code === 'auth/user-not-found') continue;
        deleteStats.authUsers.failed += 1;
        console.error(`[WARN] Failed deleting auth user ${user.uid}:`, e.message || e);
      }
    }
  }

  return deleteStats;
}

function printDeleteStats(stats) {
  console.log('\n=== Delete Result ===');
  for (const [key, value] of Object.entries(stats)) {
    console.log(
      `${key}: deleted=${value.deleted || 0}, failed=${value.failed || 0}`,
    );
  }
}

async function runCleanup({ argv = [], forceConfirmMode = false }) {
  const config = readConfig(argv, forceConfirmMode);
  if (forceConfirmMode && !config.confirmDelete) {
    throw new Error('delete-confirm.js requires --confirm-delete');
  }
  const ctx = await initAdmin(config.projectId);

  const plan = await buildPlan(ctx, config);
  const backupPath = backupFilePath();
  const backupPayload = buildBackupPayload(plan, config);
  ensureDirectory(backupPath);
  fs.writeFileSync(backupPath, JSON.stringify(backupPayload, null, 2), 'utf8');

  if (!config.confirmDelete) {
    printSummary(plan, config, backupPath, 'DRY RUN (no delete performed)');
    return {
      mode: 'dry-run',
      backupPath,
      summary: plan.summary,
    };
  }

  ensureSafeDeleteMode(config);
  printSummary(plan, config, backupPath, 'CONFIRM MODE (deleting now)');
  const deleteStats = await executeDelete(ctx, plan, config);
  printDeleteStats(deleteStats);
  return {
    mode: 'confirm-delete',
    backupPath,
    summary: plan.summary,
    deleteStats,
  };
}

module.exports = { runCleanup };
