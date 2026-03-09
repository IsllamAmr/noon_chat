import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../models/story.dart';
import '../services/story_service.dart';
import '../widgets/story_progress_bar.dart';
import '../widgets/text_story_canvas.dart';

class StoryViewerScreen extends StatefulWidget {
  final List<Story> stories;
  final int initialIndex;

  const StoryViewerScreen({
    super.key,
    required this.stories,
    this.initialIndex = 0,
  });

  @override
  State<StoryViewerScreen> createState() => _StoryViewerScreenState();
}

class _StoryViewerScreenState extends State<StoryViewerScreen> {
  late final PageController _pageController;
  late final List<Story> _stories;

  int _index = 0;
  double _progress = 0;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _stories = [...widget.stories]
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    _index = widget.initialIndex.clamp(
      0,
      _stories.isEmpty ? 0 : _stories.length - 1,
    );
    _pageController = PageController(initialPage: _index);
    _markCurrentViewed();
    _startProgressTicker();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  Duration _storyDuration(Story story) {
    return story.isImage
        ? const Duration(seconds: 7)
        : const Duration(seconds: 6);
  }

  Future<void> _markCurrentViewed() async {
    if (_stories.isEmpty) return;
    unawaited(StoryService.markViewed(_stories[_index].storyId));
  }

  void _startProgressTicker() {
    _ticker?.cancel();
    _progress = 0;
    if (_stories.isEmpty) return;

    final duration = _storyDuration(_stories[_index]);
    const tick = Duration(milliseconds: 50);
    final totalMs = duration.inMilliseconds;

    _ticker = Timer.periodic(tick, (timer) {
      if (!mounted) return;
      setState(() {
        _progress += tick.inMilliseconds / totalMs;
      });

      if (_progress >= 1) {
        _goToNext(auto: true);
      }
    });
  }

  void _goToNext({bool auto = false}) {
    if (_stories.isEmpty) return;

    if (_index >= _stories.length - 1) {
      if (auto) {
        Navigator.of(context).maybePop();
      }
      return;
    }

    _pageController.nextPage(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }

  void _goToPrevious() {
    if (_stories.isEmpty || _index <= 0) return;
    _pageController.previousPage(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }

  void _onTapDown(TapDownDetails details) {
    final width = MediaQuery.sizeOf(context).width;
    if (details.globalPosition.dx < width * 0.34) {
      _goToPrevious();
    } else {
      _goToNext();
    }
  }

  String _timeAgo(DateTime dateTime) {
    final diff = DateTime.now().difference(dateTime);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    return '${diff.inDays}d';
  }

  Widget _buildStoryBody(Story story) {
    if (story.isImage && (story.imageUrl ?? '').trim().isNotEmpty) {
      return Stack(
        fit: StackFit.expand,
        children: [
          Image.network(
            story.imageUrl!,
            fit: BoxFit.cover,
            filterQuality: FilterQuality.low,
            loadingBuilder: (context, child, progress) {
              if (progress == null) return child;
              return const Center(
                child: SizedBox(
                  width: 26,
                  height: 26,
                  child: CircularProgressIndicator(strokeWidth: 2.2),
                ),
              );
            },
            errorBuilder: (_, _, _) => const Center(
              child: Icon(Icons.broken_image_outlined, size: 34),
            ),
          ),
          if ((story.text ?? '').trim().isNotEmpty)
            Align(
              alignment: Alignment.bottomCenter,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 18),
                color: Colors.black.withValues(alpha: 0.24),
                child: Text(
                  story.text!.trim(),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
        ],
      );
    }

    return TextStoryCanvas(
      text: story.text ?? '',
      backgroundId: story.backgroundId ?? 'sunset',
      textStyleId: story.textStyleId ?? 'modernBold',
      borderRadius: BorderRadius.zero,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 36),
      placeholder: '',
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_stories.isEmpty) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('No story to show.')),
      );
    }

    final current = _stories[_index];
    final isMine = current.ownerId == FirebaseAuth.instance.currentUser?.uid;

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: _onTapDown,
        child: Stack(
          fit: StackFit.expand,
          children: [
            PageView.builder(
              controller: _pageController,
              itemCount: _stories.length,
              onPageChanged: (index) {
                setState(() {
                  _index = index;
                });
                _markCurrentViewed();
                _startProgressTicker();
              },
              itemBuilder: (context, index) {
                return _buildStoryBody(_stories[index]);
              },
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                child: Column(
                  children: [
                    StoryProgressBar(
                      itemCount: _stories.length,
                      currentIndex: _index,
                      currentProgress: _progress,
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        CircleAvatar(
                          radius: 18,
                          backgroundImage:
                              (current.ownerPhotoUrl ?? '').trim().isNotEmpty
                              ? NetworkImage(current.ownerPhotoUrl!.trim())
                              : null,
                          child: (current.ownerPhotoUrl ?? '').trim().isEmpty
                              ? Text(
                                  current.ownerName
                                      .substring(0, 1)
                                      .toUpperCase(),
                                )
                              : null,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                current.ownerName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              Text(
                                _timeAgo(current.createdAt),
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.82),
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (isMine)
                          TextButton.icon(
                            onPressed: () async {
                              await StoryService.deleteStory(current.storyId);
                              if (!context.mounted) return;
                              Navigator.of(context).pop();
                            },
                            icon: const Icon(Icons.delete_outline, size: 18),
                            label: const Text('Delete'),
                            style: TextButton.styleFrom(
                              foregroundColor: Colors.white,
                            ),
                          ),
                        IconButton(
                          onPressed: () => Navigator.of(context).maybePop(),
                          icon: const Icon(Icons.close_rounded),
                          color: Colors.white,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
