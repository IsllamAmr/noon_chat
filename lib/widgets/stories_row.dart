import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../models/story.dart';
import '../services/story_service.dart';
import 'story_ring_avatar.dart';

class StoriesRow extends StatelessWidget {
  final EdgeInsetsGeometry padding;
  final Future<void> Function()? onAddStoryTap;
  final Future<void> Function(List<Story> stories, int initialIndex)?
  onOpenStories;

  const StoriesRow({
    super.key,
    this.padding = const EdgeInsets.fromLTRB(16, 0, 16, 6),
    this.onAddStoryTap,
    this.onOpenStories,
  });

  List<_OwnerStories> _groupByOwner(List<Story> stories) {
    final grouped = <String, List<Story>>{};
    for (final story in stories) {
      grouped.putIfAbsent(story.ownerId, () => <Story>[]).add(story);
    }

    final result = <_OwnerStories>[];
    for (final entry in grouped.entries) {
      final ownerStories = [...entry.value]
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      final sample = ownerStories.last;
      result.add(
        _OwnerStories(
          ownerId: entry.key,
          ownerName: sample.ownerName,
          ownerPhotoUrl: sample.ownerPhotoUrl,
          stories: ownerStories,
          latestAt: sample.createdAt,
        ),
      );
    }

    result.sort((a, b) => b.latestAt.compareTo(a.latestAt));
    return result;
  }

  bool _allViewed(List<Story> stories, Set<String> viewedIds) {
    if (stories.isEmpty) return false;
    return stories.every((s) => viewedIds.contains(s.storyId));
  }

  Future<void> _handleMyStoryTap(
    BuildContext context, {
    required _OwnerStories? mine,
    required Future<void> Function()? onAddStoryTap,
    required Future<void> Function(List<Story> stories, int initialIndex)?
    onOpenStories,
  }) async {
    if (mine == null) {
      if (onAddStoryTap != null) {
        await onAddStoryTap();
      }
      return;
    }

    final action = await showModalBottomSheet<_MyStoryAction>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.visibility_outlined),
                title: const Text('View your story'),
                onTap: () => Navigator.of(context).pop(_MyStoryAction.view),
              ),
              ListTile(
                leading: const Icon(Icons.add_circle_outline_rounded),
                title: const Text('Add new story'),
                onTap: () => Navigator.of(context).pop(_MyStoryAction.add),
              ),
              ListTile(
                leading: Icon(
                  Icons.delete_outline_rounded,
                  color: Theme.of(context).colorScheme.error,
                ),
                title: Text(
                  'Delete active stories',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                onTap: () =>
                    Navigator.of(context).pop(_MyStoryAction.deleteAll),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
    if (!context.mounted) return;

    switch (action) {
      case _MyStoryAction.view:
        if (onOpenStories != null) {
          await onOpenStories(mine.stories, mine.stories.length - 1);
        }
        break;
      case _MyStoryAction.add:
        if (onAddStoryTap != null) {
          await onAddStoryTap();
        }
        break;
      case _MyStoryAction.deleteAll:
        final confirm = await showDialog<bool>(
          context: context,
          builder: (context) {
            return AlertDialog(
              title: const Text('Delete all active stories?'),
              content: Text(
                'You have ${mine.stories.length} active story'
                '${mine.stories.length > 1 ? 'ies' : ''}.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('Delete'),
                ),
              ],
            );
          },
        );
        if (confirm != true) return;

        try {
          for (final story in mine.stories) {
            await StoryService.deleteStory(story.storyId);
          }
          if (!context.mounted) return;
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Stories deleted')));
        } catch (e) {
          if (!context.mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to delete stories: $e')),
          );
        }
        break;
      case null:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = FirebaseAuth.instance.currentUser;
    final myUid = me?.uid ?? '';
    final myPhoto = (me?.photoURL ?? '').trim();

    return Padding(
      padding: padding,
      child: Column(
        children: [
          Row(
            children: [
              Text(
                'Stories',
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              Text(
                '24h',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          SizedBox(
            height: 90,
            child: StreamBuilder<List<Story>>(
              stream: StoryService.watchActiveStories(limit: 140),
              builder: (context, storiesSnap) {
                final stories = storiesSnap.data ?? const <Story>[];
                final owners = _groupByOwner(stories);

                _OwnerStories? mine;
                final others = <_OwnerStories>[];
                for (final owner in owners) {
                  if (owner.ownerId == myUid) {
                    mine = owner;
                  } else {
                    others.add(owner);
                  }
                }

                return StreamBuilder<Set<String>>(
                  stream: StoryService.watchViewedStoryIds(),
                  builder: (context, viewedSnap) {
                    final viewedIds = viewedSnap.data ?? const <String>{};
                    final mineViewed = mine == null
                        ? false
                        : _allViewed(mine.stories, viewedIds);
                    final openStories = onOpenStories;
                    final addStoryTap = onAddStoryTap;

                    return ListView.builder(
                      scrollDirection: Axis.horizontal,
                      itemCount: others.length + 1,
                      itemBuilder: (context, index) {
                        if (index == 0) {
                          return StoryRingAvatar(
                            label: 'Your Story',
                            imageUrl: mine?.ownerPhotoUrl ?? myPhoto,
                            hasStory: mine != null,
                            isViewed: mineViewed,
                            isMine: true,
                            onTap: () => _handleMyStoryTap(
                              context,
                              mine: mine,
                              onAddStoryTap: addStoryTap,
                              onOpenStories: openStories,
                            ),
                          );
                        }

                        final owner = others[index - 1];
                        final seenAll = _allViewed(owner.stories, viewedIds);
                        return StoryRingAvatar(
                          label: owner.ownerName,
                          imageUrl: owner.ownerPhotoUrl,
                          hasStory: true,
                          isViewed: seenAll,
                          onTap: () async {
                            if (openStories != null) {
                              await openStories(
                                owner.stories,
                                owner.stories.length - 1,
                              );
                            }
                          },
                        );
                      },
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

class _OwnerStories {
  final String ownerId;
  final String ownerName;
  final String? ownerPhotoUrl;
  final List<Story> stories;
  final DateTime latestAt;

  const _OwnerStories({
    required this.ownerId,
    required this.ownerName,
    required this.ownerPhotoUrl,
    required this.stories,
    required this.latestAt,
  });
}

enum _MyStoryAction { view, add, deleteAll }
