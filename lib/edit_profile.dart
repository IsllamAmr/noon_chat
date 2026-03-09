import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'user_service.dart';

class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({super.key});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  final _nameCtrl = TextEditingController();
  final _statusCtrl = TextEditingController();
  final _picker = ImagePicker();
  late final Future<DocumentSnapshot<Map<String, dynamic>>> _profileFuture;
  bool _saving = false;
  bool _loaded = false;
  String _photoUrl = '';

  @override
  void initState() {
    super.initState();
    final uid = FirebaseAuth.instance.currentUser!.uid;
    _profileFuture = FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .get();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _statusCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    final picked = await _picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1200,
      imageQuality: 85,
    );
    if (picked == null) return;

    setState(() => _saving = true);
    try {
      final bytes = await picked.readAsBytes();
      final url = await UserService.uploadMyPhoto(bytes);
      if (!mounted) return;
      setState(() => _photoUrl = url);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await UserService.updateMyProfile(
        name: _nameCtrl.text.trim(),
        status: _statusCtrl.text.trim(),
        photoUrl: _photoUrl,
      );
      if (!mounted) return;
      Navigator.pop(context);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _deleteAccount() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete account?'),
        content: const Text('This will delete your profile data permanently.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => _saving = true);
    try {
      await UserService.deleteMyAccountData();
      if (!mounted) return;
      Navigator.of(context).popUntil((route) => route.isFirst);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Edit profile')),
      body: FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        future: _profileFuture,
        builder: (context, snap) {
          if (snap.hasError) {
            return const Center(child: Text('Failed to load profile'));
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final data = snap.data?.data() ?? const <String, dynamic>{};
          final dbName = (data['name'] as String?)?.trim() ?? '';
          final dbPhoto = (data['photo'] as String?)?.trim() ?? '';
          final dbStatus = (data['status'] as String?)?.trim() ?? '';

          if (!_loaded) {
            _nameCtrl.text = dbName;
            _statusCtrl.text = dbStatus;
            _photoUrl = dbPhoto;
            _loaded = true;
          }

          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Center(
                child: Stack(
                  children: [
                    CircleAvatar(
                      radius: 54,
                      backgroundColor: scheme.primaryContainer,
                      backgroundImage: _photoUrl.isNotEmpty
                          ? NetworkImage(_photoUrl)
                          : null,
                      child: _photoUrl.isEmpty
                          ? Text(
                              _nameCtrl.text.isNotEmpty
                                  ? _nameCtrl.text[0].toUpperCase()
                                  : 'U',
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 32,
                              ),
                            )
                          : null,
                    ),
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: FilledButton.tonalIcon(
                        onPressed: _saving ? null : _pickPhoto,
                        icon: const Icon(Icons.photo_library_outlined),
                        label: const Text('Photo'),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _nameCtrl,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(
                  labelText: 'Your name',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _statusCtrl,
                textInputAction: TextInputAction.done,
                maxLength: 70,
                decoration: const InputDecoration(
                  labelText: 'Status',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check_rounded),
                label: Text(_saving ? 'Saving...' : 'Save'),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: _saving ? null : _deleteAccount,
                icon: const Icon(Icons.delete_forever_outlined),
                label: const Text('Delete Account'),
              ),
            ],
          );
        },
      ),
    );
  }
}
