import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class SelectedImage {
  const SelectedImage({
    required this.name,
    required this.bytes,
    required this.mimeType,
  });

  final String name;
  final Uint8List bytes;
  final String mimeType;
}

class ImageUploadRepository {
  ImageUploadRepository({SupabaseClient? client})
    : _client = client ?? Supabase.instance.client;

  static const bucket = 'app-images';
  static const maxBytes = 5 * 1024 * 1024;

  final SupabaseClient _client;

  Future<SelectedImage?> pickImage() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp'],
      allowMultiple: false,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return null;

    final file = result.files.single;
    final bytes = file.bytes;
    if (bytes == null || bytes.isEmpty) {
      throw StateError('Unable to read the selected image.');
    }
    if (bytes.length > maxBytes) {
      throw StateError('Image must be 5 MB or smaller.');
    }

    final mimeType = _mimeTypeFor(file.name);
    return SelectedImage(name: file.name, bytes: bytes, mimeType: mimeType);
  }

  Future<String> uploadImage({
    required SelectedImage image,
    required String folder,
    required String id,
    String? previousUrl,
  }) async {
    final cleanFolder = _cleanPathPart(folder);
    final cleanId = _cleanPathPart(id);
    final extension = _extensionFor(image.mimeType);
    final path =
        '$cleanFolder/$cleanId/${DateTime.now().millisecondsSinceEpoch}.$extension';

    await _client.storage.from(bucket).uploadBinary(
      path,
      image.bytes,
      fileOptions: FileOptions(
        contentType: image.mimeType,
        upsert: false,
      ),
    );

    if ((previousUrl ?? '').trim().isNotEmpty) {
      await removePublicUrl(previousUrl!);
    }

    return _client.storage.from(bucket).getPublicUrl(path);
  }

  Future<void> removePublicUrl(String url) async {
    final path = _pathFromPublicUrl(url);
    if (path == null || path.isEmpty) return;
    try {
      await _client.storage.from(bucket).remove([path]);
    } catch (_) {
      // Image cleanup is best effort; record updates should not fail because of it.
    }
  }

  String _mimeTypeFor(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    throw StateError('Only JPG, PNG, and WebP images are supported.');
  }

  String _extensionFor(String mimeType) {
    switch (mimeType) {
      case 'image/jpeg':
        return 'jpg';
      case 'image/png':
        return 'png';
      case 'image/webp':
        return 'webp';
      default:
        throw StateError('Unsupported image type.');
    }
  }

  String _cleanPathPart(String value) {
    final clean = value.trim().replaceAll(RegExp(r'[^a-zA-Z0-9_-]+'), '-');
    return clean.isEmpty ? 'image' : clean;
  }

  String? _pathFromPublicUrl(String url) {
    final marker = '/storage/v1/object/public/$bucket/';
    final index = url.indexOf(marker);
    if (index == -1) return null;
    final rawPath = url.substring(index + marker.length);
    return Uri.decodeComponent(rawPath.split('?').first);
  }
}
