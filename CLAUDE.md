# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Flutter monorepo for **cached_network_image_ce** — a community fork of the original `cached_network_image` package that replaces the `sqflite` caching backend with `hive_ce` for significantly faster, non-blocking cache metadata operations.

@guidelines.md

## Communication Style

Use the **caveman** skill for all replies in this project — terse, no filler, technical precision preserved. Relax only for safety/irreversible-op confirmations or when the user explicitly asks for normal prose.

## Monorepo Structure

Three Dart packages live at the root level:

- **`cached_network_image/`** — main consumer package (`cached_network_image_ce` on pub.dev). Contains the `CachedNetworkImage` widget, `CachedNetworkImageProvider`, and `DefaultCacheManager`.
- **`cached_network_image_platform_interface/`** — abstract platform contracts (`BaseCacheManager`, `CacheManager`, `ImageCacheManager` mixin, `FileResponse`, `ConnectionParameters`). All packages depend on this.
- **`cached_network_image_web/`** — web platform implementation of `ImageLoader` using `dart:ui_web` and `IndexedDB` via `hive_ce`.

## Workflow Rules

- **TDD preferred:** write failing tests first for new behavior or bug fixes, implement until green.
- **Subagent-driven development** for implementation plans with independent tasks — use `superpowers:subagent-driven-development` skill.
- **MCP over CLI** for Dart/Flutter tooling (analysis, fixes, project queries) when the MCP tool covers the task.
- **Prefer `final class`** for models and protocol messages (sealed for `SyncMessage` variants).
- `analysis_options.yaml` enforces `prefer_final_locals`; `avoid_print: false` (allowed during dev).
- write commits according to commit_style.md file but get confirmation from the user before committing
- dont write with claude to the commit message
```

## Architecture

### Cache data flow (IO / mobile / desktop)
1. `CachedNetworkImage` widget uses `CachedNetworkImageProvider` (an `ImageProvider`).
2. `CachedNetworkImageProvider` delegates to `DefaultCacheManager.getImageFile()`.
3. `DefaultCacheManager` uses **two storage layers**:
   - **Hive CE** (`_kBoxName = 'cached_network_image_cache'`) — stores `CacheEntryMetadata` (URL, relative path, `validTill`, eTag, byte length). Uses a **private `HiveImpl` instance** to avoid colliding with the host app's global Hive singleton.
   - **Native filesystem** — stores raw image bytes under `<temporaryDirectory>/cached_network_image_ce/<hash>.<ext>`.
4. Cache keys longer than 255 characters are sha256-hashed via `_sanitizeBoxKey()`.
5. `DefaultCacheManager` is selected via conditional exports in `default_cache_manager_factory.dart` (`dart.library.io` → IO impl, `dart.library.js_interop` → web impl, stub for unsupported platforms).

### Cache data flow (web)
- `DefaultCacheManagerWeb` stores both metadata **and** image bytes in Hive/IndexedDB (no native FS access on web).
- `ImageLoader` (web) supports two render modes: `HtmlImage` (default, uses browser caching) and `HttpGet` (enables custom headers, goes through the cache manager).

### Platform interface
- `BaseCacheManager` — abstract interface for `getFileStream`, `getFileFromCache`, `putFile`, `removeFile`, `emptyCache`, `dispose`.
- `CacheManager extends BaseCacheManager` — adds `static CacheManagerLogLevel logLevel`.
- `ImageCacheManager mixin on BaseCacheManager` — adds `getImageFile` with `maxWidth`/`maxHeight` resize support.

### Initialization guard
`DefaultCacheManager._ensureInitialized()` uses a `Completer` so concurrent callers on cold start share a single init future. On Hive box corruption, it deletes the box and clears cache files, then reopens fresh.

### Key files
- `cached_network_image/lib/src/cache/default_cache_manager.dart` — core IO cache logic
- `cached_network_image/lib/src/cache/default_cache_manager_web.dart` — web cache logic
- `cached_network_image/lib/src/image_provider/cached_network_image_provider.dart` — `ImageProvider` implementation
- `cached_network_image/lib/src/cached_image_widget.dart` — `CachedNetworkImage` widget (uses `octo_image` internally)
- `cached_network_image_platform_interface/lib/src/cache_manager.dart` — abstract contracts

## Commit Style

Follow Conventional Commits (see `commit_style.md`):
```
<type>[optional scope]: <description>
```
Types: `feat`, `fix`, `docs`, `refactor`, `perf`, `test`, `chore`, `improvement`.  
Use `BREAKING CHANGE:` in the body/footer for breaking API changes (triggers a major version bump).

## Testing Notes

- Tests use `mocktail` for mocking. Fake implementations live in `test/fake_cache_manager.dart`.
- `test/image_data.dart` contains raw byte fixtures for various image formats.
- The web cache manager has its own test file: `default_cache_manager_web_test.dart`.
- Debug mode may pause on caught network exceptions (404s etc.); this is expected Flutter behavior.
