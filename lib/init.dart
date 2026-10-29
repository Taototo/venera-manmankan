import 'dart:async';
import 'dart:io';

import 'package:display_mode/display_mode.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_saf/flutter_saf.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/cookie_jar.dart';
import 'package:venera/pages/comic_source_page.dart';
import 'package:venera/pages/follow_updates_page.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/utils/app_links.dart';
import 'package:venera/utils/handle_text_share.dart';
import 'package:venera/utils/opencc.dart';
import 'package:venera/utils/tags_translation.dart';
import 'package:venera/utils/translations.dart';
import 'foundation/appdata.dart';

extension _FutureInit<T> on Future<T> {
  /// Prevent unhandled exception
  ///
  /// A unhandled exception occurred in init() will cause the app to crash.
  Future<void> wait() async {
    try {
      await this;
    } catch (e, s) {
      Log.error("init", "$e\n$s");
    }
  }
}

Future<void> init() async {
  await App.init().wait();
  await SingleInstanceCookieJar.createInstance();
  try {
    var futures = [
      App.initComponents(),
      SAFTaskWorker().init().wait(),
      AppTranslation.init().wait(),
      TagsTranslation.readData().wait(),
      JsEngine().init().wait(),
      ComicSourceManager().init().wait(),
      OpenCC.init(),
    ];
    await Future.wait(futures);
  } catch (e, s) {
    Log.error("init", "$e\n$s");
  }
  CacheManager().setLimitSize(appdata.settings['cacheSize']);
  await _checkOldConfigs();
  if (App.isAndroid) {
    handleLinks();
    handleTextShare();
    try {
      await FlutterDisplayMode.setHighRefreshRate();
    } catch (e) {
      Log.error("Display Mode", "Failed to set high refresh rate: $e");
    }
  }
  FlutterError.onError = (details) {
    Log.error("Unhandled Exception", "${details.exception}\n${details.stack}");
  };
}

Future<void> _checkOldConfigs() async {
  var saveSettings = false;
  if (appdata.settings['searchSources'] == null) {
    appdata.settings['searchSources'] = ComicSource.all()
        .where((e) => e.searchPageData != null)
        .map((e) => e.key)
        .toList();
    saveSettings = true;
  }

  if (appdata.implicitData['webdavAutoSync'] == null) {
    var webdavConfig = appdata.settings['webdav'];
    if (webdavConfig is List &&
        webdavConfig.length == 3 &&
        webdavConfig.whereType<String>().length == 3) {
      appdata.implicitData['webdavAutoSync'] = true;
    } else {
      appdata.implicitData['webdavAutoSync'] = false;
    }
    appdata.writeImplicitData();
  }

  if (App.isAndroid) {
    final sourceListUrl = appdata.settings['comicSourceListUrl'].toString();
    const androidSourceListUrl =
        "https://gcore.jsdelivr.net/gh/Taototo/venera-comic-sources@main/comic_index.json";
    if (sourceListUrl != androidSourceListUrl &&
        (sourceListUrl.contains("git.nyne.dev") ||
            sourceListUrl.contains("Taototo/venera-comic-sources") ||
            sourceListUrl ==
                "https://cdn.jsdelivr.net/gh/venera-app/venera-configs@main/index.json" ||
            sourceListUrl ==
                "https://cdn.jsdelivr.net/gh/Taototo/venera-comic-sources@main/comic_index.json")) {
      appdata.settings['comicSourceListUrl'] = androidSourceListUrl;
      saveSettings = true;
    }
  }

  const retiredSourceKey = 'private_55comics';
  const retiredSourceNames = {'55漫画', '55漫畫', '55 Comics'};
  for (final settingKey in [
    'searchSources',
    'explore_pages',
    'category_pages',
  ]) {
    final value = appdata.settings[settingKey];
    if (value is List) {
      final oldLength = value.length;
      value.removeWhere(
        (item) => item == retiredSourceKey || retiredSourceNames.contains(item),
      );
      saveSettings = saveSettings || oldLength != value.length;
    }
  }
  if (appdata.settings['defaultSearchTarget'] == retiredSourceKey) {
    appdata.settings['defaultSearchTarget'] = null;
    saveSettings = true;
  }

  final sourceDirectory = Directory(App.dataPath + '/comic_source');
  var removedSourceFiles = false;
  for (final fileName in ['$retiredSourceKey.js', '$retiredSourceKey.data']) {
    final file = File(sourceDirectory.path + '/' + fileName);
    if (await file.exists()) {
      await file.delete();
      removedSourceFiles = true;
    }
  }
  ComicSourceManager().remove(retiredSourceKey);
  if (removedSourceFiles) {
    await ComicSourceManager().reload();
  }
  if (saveSettings) {
    await appdata.saveData();
  }
}

Future<void> _checkAppUpdates() async {
  var lastCheck = appdata.implicitData['lastCheckUpdate'] ?? 0;
  var now = DateTime.now().millisecondsSinceEpoch;
  if (now - lastCheck < 24 * 60 * 60 * 1000) {
    return;
  }
  appdata.implicitData['lastCheckUpdate'] = now;
  appdata.writeImplicitData();
  ComicSourcePage.checkComicSourceUpdate();
  if (appdata.settings['checkUpdateOnStart']) {
    await checkUpdateUi(false, true);
  }
}

void checkUpdates() {
  _checkAppUpdates();
  FollowUpdatesService.initChecker();
}
