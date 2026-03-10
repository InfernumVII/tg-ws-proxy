# iOS prototype

Это черновой нативный iOS-порт TG WS Proxy.

Что внутри:
- SwiftUI-приложение для включения/выключения туннеля и редактирования `DC:IP` маппингов.
- `Network Extension` (`NEAppProxyProvider`) для перехвата TCP-flow.
- Попытка повторить desktop-логику: определить Telegram DC по первым 64 байтам MTProto obfuscation init, затем поднять raw WebSocket к `kws*.telegram.org`, а при ошибке переключиться на прямой TCP.
- Сборка через XcodeGen + GitHub Actions с упаковкой в `.ipa` без подписи, чтобы потом можно было переподписать через AltStore.

Ограничения:
- Для реальной установки и запуска на устройстве понадобятся entitlement'ы `Network Extension`.
- AltStore сможет переподписать `.ipa`, но iOS может отказать в запуске расширения без нужных capability.
- Этот прототип собран без Xcode-валидации в текущем Windows workspace, поэтому перед релизом нужен прогон на macOS/Xcode.

## Структура

- `project.yml` — спецификация XcodeGen
- `TgWsProxyIOS/App` — SwiftUI UI и управление `NETunnelProviderManager`
- `TgWsProxyIOS/Extension` — Network Extension
- `TgWsProxyIOS/Shared` — общая логика MTProto/DC/WebSocket
- `TgWsProxyIOS/Resources` — plist/entitlements

## Локальная сборка на macOS

1. Установить Xcode и XcodeGen.
2. Выполнить:
   - `xcodegen generate --spec ios/project.yml`
   - `xcodebuild -project ios/TgWsProxyIOS.xcodeproj -scheme TgWsProxyIOS -configuration Release -sdk iphoneos CODE_SIGNING_ALLOWED=NO`
3. Упаковать `TgWsProxyIOS.app` в `Payload/*.app` и заархивировать в `.ipa`.

## Что доделать дальше

- Прогнать компиляцию на macOS и исправить Xcode-specific ошибки.
- Проверить entitlement'ы на реальном Apple ID.
- Добавить нормальный логгер и диагностику Network Extension.
- Проверить, достаточно ли `NEAppProxyProvider`, или потребуется `Packet Tunnel`.
