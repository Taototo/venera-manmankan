# Due to my limited time and energy, this project is no longer maintained. Feel free to fork it.
# 由于本人精力有限, 此项目已停止维护, 欢迎fork

# 漫漫看
[![flutter](https://img.shields.io/badge/flutter-3.41.4-blue)](https://flutter.dev/)
[![License](https://img.shields.io/github/license/Taototo/venera-manmankan)](https://github.com/Taototo/venera-manmankan/blob/master/LICENSE)
[![stars](https://img.shields.io/github/stars/Taototo/venera-manmankan?style=flat)](https://github.com/Taototo/venera-manmankan/stargazers)

[![Download](https://img.shields.io/github/v/release/Taototo/venera-manmankan)](https://github.com/Taototo/venera-manmankan/releases)

漫漫看是一款 Android 漫画阅读器，支持本地漫画和网络漫画源。

## Features
- Read local comics
- Use javascript to create comic sources
- Read comics from network sources
- Manage favorite comics
- Download comics
- View comments, tags, and other information of comics if the source supports
- Login to comment, rate, and other operations if the source supports

## Build for Android
1. Clone the repository
2. Install Flutter 3.41.4 and Rust
3. Run `flutter pub get`
4. Run `flutter build apk --release`

## Create a new comic source
See [Comic Source](doc/comic_source.md)

## Thanks

### Tags Translation
[EhTagTranslation](https://github.com/EhTagTranslation/Database)

The Chinese translation of the manga tags is from this project.

## Headless Mode
See [Headless Doc](doc/headless_doc.md)

