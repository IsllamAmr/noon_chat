import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/story_service.dart';
import '../widgets/text_story_canvas.dart';

enum _AddStoryMode { text, photo }

class AddStoryScreen extends StatefulWidget {
  const AddStoryScreen({super.key});

  @override
  State<AddStoryScreen> createState() => _AddStoryScreenState();
}

class _AddStoryScreenState extends State<AddStoryScreen> {
  final TextEditingController _textController = TextEditingController();
  final TextEditingController _captionController = TextEditingController();
  final ImagePicker _picker = ImagePicker();

  _AddStoryMode _mode = _AddStoryMode.text;
  String _selectedBackgroundId = TextStoryCanvas.backgroundPresets.first.id;
  String _selectedTextStyleId = TextStoryCanvas.textStylePresets.first.id;
  XFile? _pickedImage;
  bool _posting = false;
  bool _picking = false;

  @override
  void dispose() {
    _textController.dispose();
    _captionController.dispose();
    super.dispose();
  }

  Future<void> _pickImage(ImageSource source) async {
    if (_picking || _posting) return;
    setState(() => _picking = true);
    try {
      final picked = await _picker.pickImage(
        source: source,
        imageQuality: 90,
        maxWidth: 1600,
      );
      if (picked == null || !mounted) return;
      setState(() {
        _pickedImage = picked;
        _mode = _AddStoryMode.photo;
      });
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _postTextStory() async {
    final text = _textController.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Write something first.')));
      return;
    }

    setState(() => _posting = true);
    try {
      await StoryService.createTextStory(
        text: text,
        backgroundId: _selectedBackgroundId,
        textStyleId: _selectedTextStyleId,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to post story: $e')));
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  Future<void> _postPhotoStory() async {
    final image = _pickedImage;
    if (image == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Pick a photo first.')));
      return;
    }

    setState(() => _posting = true);
    try {
      await StoryService.createImageStory(
        imageFile: File(image.path),
        caption: _captionController.text.trim(),
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on StoryUploadException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to post story: $e')));
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  Widget _buildTextComposer() {
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: TextStoryCanvas(
              text: _textController.text,
              backgroundId: _selectedBackgroundId,
              textStyleId: _selectedTextStyleId,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            controller: _textController,
            maxLines: 4,
            minLines: 1,
            maxLength: 220,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              hintText: 'Write your story text...',
              prefixIcon: Icon(Icons.edit_note_rounded),
            ),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 44,
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            scrollDirection: Axis.horizontal,
            itemCount: TextStoryCanvas.backgroundPresets.length,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (context, index) {
              final preset = TextStoryCanvas.backgroundPresets[index];
              final selected = preset.id == _selectedBackgroundId;
              return GestureDetector(
                onTap: () => setState(() => _selectedBackgroundId = preset.id),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      colors: preset.colors,
                      begin: preset.begin,
                      end: preset.end,
                    ),
                    border: Border.all(
                      color: selected
                          ? Theme.of(context).colorScheme.primary
                          : Colors.white.withValues(alpha: 0.38),
                      width: selected ? 2.2 : 1.2,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 40,
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            scrollDirection: Axis.horizontal,
            itemCount: TextStoryCanvas.textStylePresets.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              final preset = TextStoryCanvas.textStylePresets[index];
              final selected = preset.id == _selectedTextStyleId;
              return ChoiceChip(
                selected: selected,
                label: Text('Aa', style: preset.style.copyWith(fontSize: 16)),
                onSelected: (_) =>
                    setState(() => _selectedTextStyleId = preset.id),
              );
            },
          ),
        ),
        const SizedBox(height: 14),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: FilledButton.icon(
            onPressed: _posting ? null : _postTextStory,
            icon: _posting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2.2),
                  )
                : const Icon(Icons.upload_rounded),
            label: Text(_posting ? 'Posting...' : 'Post text story'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(50),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPhotoComposer() {
    final image = _pickedImage;
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: image == null
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.image_outlined,
                              size: 42,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            const SizedBox(height: 10),
                            const Text('Pick a photo to post a story'),
                          ],
                        ),
                      )
                    : Image.file(
                        File(image.path),
                        fit: BoxFit.cover,
                        width: double.infinity,
                        height: double.infinity,
                      ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _posting || _picking
                      ? null
                      : () => _pickImage(ImageSource.gallery),
                  icon: const Icon(Icons.photo_library_outlined),
                  label: const Text('Gallery'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _posting || _picking
                      ? null
                      : () => _pickImage(ImageSource.camera),
                  icon: const Icon(Icons.photo_camera_outlined),
                  label: const Text('Camera'),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            controller: _captionController,
            maxLines: 2,
            maxLength: 160,
            decoration: const InputDecoration(
              hintText: 'Add a caption (optional)',
              prefixIcon: Icon(Icons.short_text_rounded),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: FilledButton.icon(
            onPressed: _posting ? null : _postPhotoStory,
            icon: _posting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2.2),
                  )
                : const Icon(Icons.upload_rounded),
            label: Text(_posting ? 'Posting...' : 'Post photo story'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(50),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Add story')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
            child: SegmentedButton<_AddStoryMode>(
              segments: const [
                ButtonSegment<_AddStoryMode>(
                  value: _AddStoryMode.text,
                  label: Text('Text story'),
                  icon: Icon(Icons.text_fields_rounded),
                ),
                ButtonSegment<_AddStoryMode>(
                  value: _AddStoryMode.photo,
                  label: Text('Photo story'),
                  icon: Icon(Icons.image_outlined),
                ),
              ],
              selected: <_AddStoryMode>{_mode},
              onSelectionChanged: (selection) {
                if (selection.isEmpty) return;
                setState(() => _mode = selection.first);
              },
            ),
          ),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: _mode == _AddStoryMode.text
                  ? _buildTextComposer()
                  : _buildPhotoComposer(),
            ),
          ),
        ],
      ),
    );
  }
}
