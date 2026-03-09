import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../services/chat_service.dart';
import '../services/user_service.dart';
import 'chat_screen.dart';

class UserSearchScreen extends StatefulWidget {
  const UserSearchScreen({super.key});

  @override
  State<UserSearchScreen> createState() => _UserSearchScreenState();
}

class _UserSearchScreenState extends State<UserSearchScreen> {
  final TextEditingController _searchController = TextEditingController();
  Timer? _debounce;

  List<_SearchUserItem> _results = const <_SearchUserItem>[];
  bool _loading = false;
  String _error = '';
  String _activeQuery = '';
  String? _openingUserId;

  String get _myUid => FirebaseAuth.instance.currentUser!.uid;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onTextControllerChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.removeListener(_onTextControllerChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _onTextControllerChanged() {
    if (mounted) setState(() {});
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      unawaited(_runSearch(value));
    });
  }

  Future<void> _runSearch(String rawQuery) async {
    final query = rawQuery.trim();
    if (!mounted) return;

    if (query.isEmpty) {
      setState(() {
        _activeQuery = '';
        _results = const <_SearchUserItem>[];
        _loading = false;
        _error = '';
      });
      return;
    }

    setState(() {
      _activeQuery = query;
      _loading = true;
      _error = '';
    });

    try {
      final docs = query.contains('@')
          ? await UserService.searchUsersByEmailPrefix(query, limit: 30)
          : await UserService.searchUsersByNamePrefix(query, limit: 30);

      final filtered = docs.where((d) => d.id != _myUid).toList();
      final mapped = filtered.map(_SearchUserItem.fromDoc).toList();

      if (!mounted) return;
      setState(() {
        _results = mapped;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Failed to search users';
      });
    }
  }

  Future<void> _openConversation(_SearchUserItem user) async {
    if (_openingUserId != null) return;
    setState(() => _openingUserId = user.uid);

    try {
      final conversationId = await ChatService.getOrCreateConversation(
        otherUid: user.uid,
        otherDisplayName: user.displayName,
        otherPhotoUrl: user.photoUrl,
      );
      if (!mounted) return;

      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ChatScreen(
            conversationId: conversationId,
            otherUser: ChatOtherUser(
              uid: user.uid,
              name: user.displayName,
              avatarUrl: user.photoUrl.isEmpty ? null : user.photoUrl,
            ),
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to open conversation')),
      );
    } finally {
      if (mounted) {
        setState(() => _openingUserId = null);
      } else {
        _openingUserId = null;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final searchByEmail = _activeQuery.contains('@');

    return Scaffold(
      appBar: AppBar(title: const Text('Find people')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
            child: TextField(
              controller: _searchController,
              autofocus: true,
              onChanged: _onQueryChanged,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Search by name or email',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: _searchController.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear',
                        onPressed: () {
                          _searchController.clear();
                          _onQueryChanged('');
                          setState(() {});
                        },
                        icon: const Icon(Icons.close_rounded),
                      ),
              ),
            ),
          ),
          if (_activeQuery.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  searchByEmail
                      ? 'Searching by email'
                      : 'Searching by display name',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          Expanded(
            child: Builder(
              builder: (context) {
                if (_loading) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (_error.isNotEmpty) {
                  return Center(child: Text(_error));
                }
                if (_activeQuery.isEmpty) {
                  return Center(
                    child: Text(
                      'Type a name or email to search',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  );
                }
                if (_results.isEmpty) {
                  return Center(
                    child: Text(
                      'No users found',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  );
                }

                return ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                  itemCount: _results.length,
                  itemBuilder: (context, index) {
                    final user = _results[index];
                    final opening = _openingUserId == user.uid;
                    return ListTile(
                      key: ValueKey(user.uid),
                      leading: CircleAvatar(
                        backgroundImage: user.photoUrl.isNotEmpty
                            ? NetworkImage(user.photoUrl)
                            : null,
                        child: user.photoUrl.isEmpty
                            ? Text(
                                user.displayName.substring(0, 1).toUpperCase(),
                              )
                            : null,
                      ),
                      title: Text(
                        user.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        user.email,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: opening
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.2,
                              ),
                            )
                          : const Icon(Icons.chat_bubble_outline_rounded),
                      onTap: opening ? null : () => _openConversation(user),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _SearchUserItem {
  final String uid;
  final String displayName;
  final String email;
  final String photoUrl;

  const _SearchUserItem({
    required this.uid,
    required this.displayName,
    required this.email,
    required this.photoUrl,
  });

  factory _SearchUserItem.fromDoc(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();
    final displayName = ((data['displayName'] ?? data['name'] ?? '') as String)
        .trim();
    final email = ((data['email'] ?? '') as String).trim();
    final photoUrl = ((data['photoUrl'] ?? data['photo'] ?? '') as String)
        .trim();
    return _SearchUserItem(
      uid: doc.id,
      displayName: displayName.isEmpty ? 'Noon User' : displayName,
      email: email,
      photoUrl: photoUrl,
    );
  }
}
