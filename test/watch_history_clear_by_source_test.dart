import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nipaplay/models/watch_history_database.dart';
import 'package:nipaplay/models/watch_history_model.dart';
import 'package:nipaplay/providers/watch_history_provider.dart';
import 'package:nipaplay/utils/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 一键清除媒体库记录的持久层与 Provider 层回归：
/// DB 批量删除（deleteHistoryByFilePaths）+ Provider 按谓词删除
/// （removeHistoriesWhere），清除范围不得波及其他来源的记录。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('nipaplay_clear_records');
    StorageService.debugAppStorageDirectoryOverride = tempDir;
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    StorageService.debugAppStorageDirectoryOverride = null;
    try {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    } on FileSystemException {
      // 数据库单例仍持有连接，Windows 下目录会被锁定；临时目录留给系统清理。
    }
  });

  WatchHistoryItem item(String filePath, int animeId) => WatchHistoryItem(
        filePath: filePath,
        animeName: '测试番剧$animeId',
        episodeTitle: '第01话',
        animeId: animeId,
        watchProgress: 0.5,
        lastPosition: 120,
        duration: 1440,
        lastWatchTime: DateTime(2026, 10, 1),
      );

  Future<void> seedHistory() async {
    final db = WatchHistoryDatabase.instance;
    await db.insertOrUpdateWatchHistory(item('webdav://conn-a/1.mp4', 1));
    await db.insertOrUpdateWatchHistory(item('webdav://conn-a/2.mp4', 1));
    await db.insertOrUpdateWatchHistory(item('smb://conn-b/3.mp4', 2));
    await db.insertOrUpdateWatchHistory(item('/local/4.mp4', 3));
  }

  test('deleteHistoryByFilePaths 批量删除目标记录并保留其他来源', () async {
    await seedHistory();
    final db = WatchHistoryDatabase.instance;

    final removed = await db.deleteHistoryByFilePaths([
      'webdav://conn-a/1.mp4',
      'webdav://conn-a/2.mp4',
      'webdav://conn-a/not-exist.mp4',
    ]);

    expect(removed, 2);
    final remaining = (await db.getAllWatchHistory())
        .map((entry) => entry.filePath)
        .toList();
    expect(remaining, containsAll(['smb://conn-b/3.mp4', '/local/4.mp4']));
    expect(remaining.where((path) => path.startsWith('webdav://')), isEmpty);
  });

  test('deleteHistoryByFilePaths 空列表直接返回 0', () async {
    expect(await WatchHistoryDatabase.instance.deleteHistoryByFilePaths([]), 0);
  });

  test('removeHistoriesWhere 删除匹配记录并同步内存列表', () async {
    // 只种远程路径：loadHistory 的有效性验证会把不存在的本地文件过滤掉。
    final db = WatchHistoryDatabase.instance;
    await db.insertOrUpdateWatchHistory(item('webdav://conn-a/1.mp4', 1));
    await db.insertOrUpdateWatchHistory(item('webdav://conn-a/2.mp4', 1));
    await db.insertOrUpdateWatchHistory(item('smb://conn-b/3.mp4', 2));
    final provider = WatchHistoryProvider();
    await provider.loadHistory();
    expect(provider.history.length, 3);

    final removed = await provider.removeHistoriesWhere(
      (entry) => entry.filePath.startsWith('webdav://'),
    );

    expect(removed, 2);
    expect(provider.history.length, 1);
    expect(
      provider.history.any((entry) => entry.filePath.startsWith('webdav://')),
      isFalse,
    );
    // 重启后（重新从库加载）被清除的记录不再出现。
    final reloaded = await WatchHistoryDatabase.instance.getAllWatchHistory();
    expect(
      reloaded.any((entry) => entry.filePath.startsWith('webdav://')),
      isFalse,
    );
  });
}
