import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'story_service.dart';

class StoriesScreen extends StatefulWidget {
  const StoriesScreen({super.key});

  @override
  State<StoriesScreen> createState() => _StoriesScreenState();
}

class _StoriesScreenState extends State<StoriesScreen> {
  final _picker = ImagePicker();
  final Map<String, Map<String, dynamic>> _userCache =
      <String, Map<String, dynamic>>{};
  final Set<String> _userLoadsInFlight = <String>{};
  bool _posting = false;

  bool _isActive(Map<String, dynamic> d) {
    final exp = d['expiresAt'];
    if (exp is! Timestamp) return false;
    return exp.toDate().isAfter(DateTime.now());
  }

  Iterable<List<String>> _chunks(List<String> source, int size) sync* {
    for (var i = 0; i < source.length; i += size) {
      final end = (i + size < source.length) ? i + size : source.length;
      yield source.sublist(i, end);
    }
  }

  Future<void> _warmUserCache(Iterable<String> uids) async {
    final missing = uids
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .where(
          (uid) =>
              !_userCache.containsKey(uid) && !_userLoadsInFlight.contains(uid),
        )
        .toList();
    if (missing.isEmpty) return;
    _userLoadsInFlight.addAll(missing);

    final fetched = <String, Map<String, dynamic>>{};
    try {
      for (final chunk in _chunks(missing, 10)) {
        final snap = await FirebaseFirestore.instance
            .collection('users')
            .where(FieldPath.documentId, whereIn: chunk)
            .get();
        for (final doc in snap.docs) {
          fetched[doc.id] = doc.data();
        }
      }
    } catch (e) {
      debugPrint('Stories user cache load failed: $e');
    } finally {
      _userLoadsInFlight.removeAll(missing);
    }

    if (!mounted || fetched.isEmpty) return;
    setState(() => _userCache.addAll(fetched));
  }

  Future<void> _addTextStory() async {
    final ctrl = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('New text story'),
        content: TextField(
          controller: ctrl,
          maxLines: 5,
          maxLength: 700,
          decoration: const InputDecoration(
            hintText: 'Write your status...',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, ctrl.text.trim()),
            child: const Text('Post'),
          ),
        ],
      ),
    );
    if (text == null || text.isEmpty) return;
    setState(() => _posting = true);
    try {
      await StoryService.addTextStory(text);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  Future<void> _addImageStory() async {
    final picked = await _picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1600,
      imageQuality: 85,
    );
    if (picked == null) return;
    if (!mounted) return;

    final captionCtrl = TextEditingController();
    final caption = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Caption (optional)'),
        content: TextField(
          controller: captionCtrl,
          maxLength: 200,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, captionCtrl.text.trim()),
            child: const Text('Post'),
          ),
        ],
      ),
    );
    if (caption == null) return;

    setState(() => _posting = true);
    try {
      await StoryService.createImageStory(
        imageFile: File(picked.path),
        caption: caption,
      );
    } on StoryUploadException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final myUid = FirebaseAuth.instance.currentUser!.uid;
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Stories'),
        actions: [
          IconButton(
            tooltip: 'Text story',
            onPressed: _posting ? null : _addTextStory,
            icon: const Icon(Icons.edit_outlined),
          ),
          IconButton(
            tooltip: 'Photo story',
            onPressed: _posting ? null : _addImageStory,
            icon: const Icon(Icons.image_outlined),
          ),
        ],
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: StoryService.storiesStream(),
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(child: Text('Failed to load stories\n${snap.error}'));
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final activeDocs = snap.data!.docs
              .where((d) => _isActive(d.data()))
              .toList();
          final grouped =
              <String, List<QueryDocumentSnapshot<Map<String, dynamic>>>>{};
          for (final doc in activeDocs) {
            final uid = (doc.data()['uid'] ?? '').toString();
            if (uid.isEmpty) continue;
            grouped.putIfAbsent(
              uid,
              () => <QueryDocumentSnapshot<Map<String, dynamic>>>[],
            );
            grouped[uid]!.add(doc);
          }
          final myStories =
              grouped[myUid] ??
              const <QueryDocumentSnapshot<Map<String, dynamic>>>[];
          final others = grouped.entries.where((e) => e.key != myUid).toList();
          others.sort((a, b) {
            final aTime = a.value.first.data()['createdAt'];
            final bTime = b.value.first.data()['createdAt'];
            final ad = aTime is Timestamp
                ? aTime.toDate()
                : DateTime.fromMillisecondsSinceEpoch(0);
            final bd = bTime is Timestamp
                ? bTime.toDate()
                : DateTime.fromMillisecondsSinceEpoch(0);
            return bd.compareTo(ad);
          });
          unawaited(_warmUserCache(others.map((e) => e.key)));

          return ListView(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 20),
            children: [
              Card(
                color: scheme.surfaceContainerLow,
                child: ListTile(
                  leading: const CircleAvatar(child: Icon(Icons.person)),
                  title: const Text('My stories'),
                  subtitle: Text(
                    myStories.isEmpty
                        ? 'No active stories'
                        : '${myStories.length} active story',
                  ),
                  trailing: _posting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: 'Text story',
                              onPressed: _addTextStory,
                              icon: const Icon(Icons.edit_outlined),
                            ),
                            IconButton(
                              tooltip: 'Photo story',
                              onPressed: _addImageStory,
                              icon: const Icon(Icons.image_outlined),
                            ),
                          ],
                        ),
                  onTap: myStories.isEmpty
                      ? null
                      : () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) =>
                                StoryViewerScreen(uid: myUid, docs: myStories),
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 10),
              if (others.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(18),
                  child: Center(child: Text('No stories from contacts yet')),
                ),
              for (final entry in others)
                _StoryUserTile(
                  uid: entry.key,
                  docs: entry.value,
                  userData: _userCache[entry.key],
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          StoryViewerScreen(uid: entry.key, docs: entry.value),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _StoryUserTile extends StatelessWidget {
  final String uid;
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> docs;
  final Map<String, dynamic>? userData;
  final VoidCallback onTap;
  const _StoryUserTile({
    required this.uid,
    required this.docs,
    this.userData,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final last = docs.first.data();
    final previewText = ((last['text'] ?? '') as String).trim();
    final createdAt = last['createdAt'];
    final subtitleTime = createdAt is Timestamp
        ? TimeOfDay.fromDateTime(createdAt.toDate()).format(context)
        : '';
    final user = userData ?? const <String, dynamic>{};
    final name = ((user['name'] ?? 'Noon User') as String).trim();
    final photo = ((user['photo'] ?? '') as String).trim();
    return Card(
      child: ListTile(
        onTap: onTap,
        leading: CircleAvatar(
          backgroundImage: photo.isNotEmpty ? NetworkImage(photo) : null,
          child: photo.isEmpty
              ? Text(name.isEmpty ? '?' : name[0].toUpperCase())
              : null,
        ),
        title: Text(name.isEmpty ? 'Noon User' : name),
        subtitle: Text(
          previewText.isEmpty ? 'Story' : previewText,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Text(subtitleTime),
      ),
    );
  }
}

class StoryViewerScreen extends StatefulWidget {
  final String uid;
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> docs;
  const StoryViewerScreen({super.key, required this.uid, required this.docs});

  @override
  State<StoryViewerScreen> createState() => _StoryViewerScreenState();
}

class _StoryViewerScreenState extends State<StoryViewerScreen> {
  late final PageController _controller;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _controller = PageController();
    if (widget.docs.isNotEmpty) {
      unawaited(StoryService.markViewed(widget.docs.first.id));
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final myUid = FirebaseAuth.instance.currentUser!.uid;
    final isMine = widget.uid == myUid;
    return Scaffold(
      appBar: AppBar(
        title: Text(isMine ? 'My story' : 'Story'),
        actions: [
          if (isMine && widget.docs.isNotEmpty)
            IconButton(
              tooltip: 'Delete',
              onPressed: () async {
                final id = widget.docs[_index].id;
                await StoryService.deleteStory(id);
                if (!context.mounted) return;
                Navigator.pop(context);
              },
              icon: const Icon(Icons.delete_outline),
            ),
        ],
      ),
      body: PageView.builder(
        controller: _controller,
        itemCount: widget.docs.length,
        onPageChanged: (i) {
          setState(() => _index = i);
          unawaited(StoryService.markViewed(widget.docs[i].id));
        },
        itemBuilder: (context, i) {
          final d = widget.docs[i].data();
          final type = (d['type'] ?? 'text').toString();
          final text = (d['text'] ?? '').toString().trim();
          final mediaUrl = (d['mediaUrl'] ?? '').toString().trim();
          return Container(
            width: double.infinity,
            height: double.infinity,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF0A1520), Color(0xFF111827)],
              ),
            ),
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  children: [
                    Expanded(
                      child: Center(
                        child: type == 'image' && mediaUrl.isNotEmpty
                            ? ClipRRect(
                                borderRadius: BorderRadius.circular(16),
                                child: Image.network(
                                  mediaUrl,
                                  fit: BoxFit.contain,
                                  filterQuality: FilterQuality.low,
                                  cacheWidth: 1080,
                                  loadingBuilder: (context, child, progress) {
                                    if (progress == null) return child;
                                    return const SizedBox(
                                      width: 26,
                                      height: 26,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2.2,
                                      ),
                                    );
                                  },
                                  errorBuilder: (_, _, _) => const Icon(
                                    Icons.broken_image_outlined,
                                    size: 34,
                                  ),
                                ),
                              )
                            : Text(
                                text.isEmpty ? 'Story' : text,
                                style: const TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.w700,
                                ),
                                textAlign: TextAlign.center,
                              ),
                      ),
                    ),
                    if (type == 'image' && text.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Text(
                          text,
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 16),
                        ),
                      ),
                    const SizedBox(height: 8),
                    Text('${i + 1}/${widget.docs.length}'),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
