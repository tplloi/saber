import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:saber/components/canvas/_canvas_background_painter.dart';
import 'package:saber/components/canvas/_editor_image.dart';
import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:worker_manager/worker_manager.dart';

class EditorCoreInfo {
  /// The version of the file format.
  /// Increment this if earlier versions of the app can't satisfiably read the file.
  static const int sbnVersion = 8;
  bool readOnly = false;
  bool readOnlyBecauseOfVersion = false;

  String filePath;

  int nextImageId;
  Color? backgroundColor;
  String backgroundPattern;
  int lineHeight;
  List<EditorPage> pages;

  /// Stores the current page index so that it can be restored when the file is reloaded.
  int? initialPageIndex;

  static final empty = EditorCoreInfo._(
    filePath: '',
    readOnly: true,
    readOnlyBecauseOfVersion: false,
    nextImageId: 0,
    backgroundColor: null,
    backgroundPattern: '',
    lineHeight: Prefs.lastLineHeight.value,
    pages: [EditorPage()],
    initialPageIndex: null,
  )..migrateOldStrokesAndImages(strokesJson: null, imagesJson: null);

  bool get isEmpty => pages.every((EditorPage page) => page.isEmpty);

  EditorCoreInfo({
    required this.filePath,
    this.readOnly = true, // default to read-only, until it's loaded with [loadFromFilePath]
  }):
        nextImageId = 0,
        backgroundPattern = Prefs.lastBackgroundPattern.value,
        lineHeight = Prefs.lastLineHeight.value,
        pages = [];

  EditorCoreInfo._({
    required this.filePath,
    required this.readOnly,
    required this.readOnlyBecauseOfVersion,
    required this.nextImageId,
    this.backgroundColor,
    required this.backgroundPattern,
    required this.lineHeight,
    required this.pages,
    required this.initialPageIndex,
  }) {
    _handleEmptyImageIds();
  }

  factory EditorCoreInfo.fromJson(Map<String, dynamic> json, {
    required String filePath,
    bool readOnly = false,
  }) {
    bool readOnlyBecauseOfVersion = (json["v"] as int? ?? 0) > sbnVersion;
    readOnly = readOnly || readOnlyBecauseOfVersion;

    return EditorCoreInfo._(
      filePath: filePath,
      readOnly: readOnly,
      readOnlyBecauseOfVersion: readOnlyBecauseOfVersion,
      nextImageId: json["ni"] as int? ?? 0,
      backgroundColor: json["b"] != null ? Color(json["b"] as int) : null,
      backgroundPattern: json["p"] as String? ?? CanvasBackgroundPatterns.none,
      lineHeight: json["l"] as int? ?? Prefs.lastLineHeight.value,
      pages: _parsePagesJson(json["z"] as List?),
      initialPageIndex: json["c"] as int?,
    )
      ..migrateOldStrokesAndImages(
        strokesJson: json["s"] as List?,
        imagesJson: json["i"] as List?,
        fallbackPageWidth: json["w"] as double?,
        fallbackPageHeight: json["h"] as double?,
      );
  }
  /// Old json format is just a list of strokes
  EditorCoreInfo.fromOldJson(List<dynamic> json, {
    required this.filePath,
    this.readOnly = false,
  }): nextImageId = 0,
      backgroundPattern = CanvasBackgroundPatterns.none,
      lineHeight = Prefs.lastLineHeight.value,
      pages = [] {
    migrateOldStrokesAndImages(
      strokesJson: json,
      imagesJson: null,
    );
  }

  static List<EditorPage> _parsePagesJson(List<dynamic>? pages) {
    if (pages == null || pages.isEmpty) return [];
    if (pages[0] is List) { // old format (list of [width, height])
      return pages
        .map((dynamic page) => EditorPage(
          width: page[0] as double?,
          height: page[1] as double?,
        ))
        .toList();
    } else {
      return pages
          .map((dynamic page) => EditorPage.fromJson(page as Map<String, dynamic>))
          .toList();
    }
  }

  void _handleEmptyImageIds() {
    for (EditorPage page in pages) {
      for (EditorImage image in page.images) {
        if (image.id == -1) image.id = nextImageId++;
      }
    }
  }

  /// Migrates from fileVersion 7 to 8.
  /// In version 8, strokes and images are stored in their respective pages.
  ///
  /// Also creates a page if there are no pages.
  void migrateOldStrokesAndImages({
    required List<dynamic>? strokesJson,
    required List<dynamic>? imagesJson,
    double? fallbackPageWidth,
    double? fallbackPageHeight,
  }) {
    if (strokesJson != null) {
      final strokes = EditorPage.parseStrokesJson(strokesJson);
      for (Stroke stroke in strokes) {
        while (stroke.pageIndex >= pages.length) {
          pages.add(EditorPage(width: fallbackPageWidth, height: fallbackPageHeight));
        }
        pages[stroke.pageIndex].strokes.add(stroke);
      }
    }

    if (imagesJson != null) {
      final images = EditorPage.parseImagesJson(
          imagesJson,
          allowCalculations: !readOnly
      );
      for (EditorImage image in images) {
        while (image.pageIndex >= pages.length) {
          pages.add(EditorPage(width: fallbackPageWidth, height: fallbackPageHeight));
        }
        pages[image.pageIndex].images.add(image);
      }
    }

    // add a page if there are no pages,
    // or if the last page is not empty
    if (pages.isEmpty || !pages.last.isEmpty) {
      pages.add(EditorPage(width: fallbackPageWidth, height: fallbackPageHeight));
    }
  }

  static Future<EditorCoreInfo> loadFromFilePath(String path, {bool readOnly = false}) async {
    String? jsonString = await FileManager.readFile(path + Editor.extension);
    if (jsonString == null) return EditorCoreInfo(filePath: path, readOnly: readOnly);

    try {
      final dynamic json = await Executor().execute(fun1: _jsonDecodeIsolate, arg1: jsonString);
      if (json == null) {
        throw Exception("Failed to parse json from $path");
      } else if (json is List) { // old format
        return EditorCoreInfo.fromOldJson(
          json,
          filePath: path,
          readOnly: readOnly,
        );
      } else {
        return EditorCoreInfo.fromJson(
          json as Map<String, dynamic>,
          filePath: path,
          readOnly: readOnly
        );
      }
    } catch (e) {
      if (kDebugMode) {
        rethrow;
      } else {
        return EditorCoreInfo(filePath: path, readOnly: readOnly);
      }
    }
  }

  static dynamic _jsonDecodeIsolate(String json, TypeSendPort port) {
    try {
      return jsonDecode(json);
    } catch (e) {
      if (kDebugMode) print("_jsonDecodeIsolate: $e");
      return null;
    }
  }

  Map<String, dynamic> toJson() => {
    'v': sbnVersion,
    'ni': nextImageId,
    'b': backgroundColor?.value,
    'p': backgroundPattern,
    'l': lineHeight,
    'z': pages,
    'c': initialPageIndex,
  };

  EditorCoreInfo copyWith({
    String? filePath,
    bool? readOnly,
    bool? readOnlyBecauseOfVersion,
    int? nextImageId,
    Color? backgroundColor,
    String? backgroundPattern,
    int? lineHeight,
    QuillController? quillController,
    List<EditorPage>? pages,
  }) {
    return EditorCoreInfo._(
      filePath: filePath ?? this.filePath,
      readOnly: readOnly ?? this.readOnly,
      readOnlyBecauseOfVersion: readOnlyBecauseOfVersion ?? this.readOnlyBecauseOfVersion,
      nextImageId: nextImageId ?? this.nextImageId,
      backgroundColor: backgroundColor ?? this.backgroundColor,
      backgroundPattern: backgroundPattern ?? this.backgroundPattern,
      lineHeight: lineHeight ?? this.lineHeight,
      pages: pages ?? this.pages,
      initialPageIndex: initialPageIndex,
    );
  }
}
