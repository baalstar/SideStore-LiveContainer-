# LiveContainer + SideStore (объединённая сборка)

Сборка: macOS + Xcode 27.2 + rustup, `brew install ldid xcbeautify`, затем `./scripts/build.sh`.
Либо залить папку в GitHub и запустить workflow. Результат: `dist/LiveContainer+SideStore.ipa`.

**Статус: iOS-сборка и установка на устройство не проверялись.** Проверен только Rust-подписчик
на Linux с тестовым сертификатом и синтетическим bundle.

## Что изменено
- SideStore берётся из локальных исходников (ветка LiveContainerSupport).
- Обычная установка и переподпись идут через isideload из SideInstaller (`SideStore/Dependencies/sisign`):
  вход, App ID, app group, Increased Memory Limit (кроме магазинов), профиль, подпись.
- Ключ активного сертификата SideStore передаётся в isideload, чтобы не запрашивать второй сертификат.
- Через старый SideSign: пользовательский bundle ID, Info.plist и entitlements, свой профиль,
  SideBackup (activate/deactivate), симулятор и tvOS.
- Экран входа, управление сертификатами и refresh остаются на SideSign. Сессии две, поэтому 2FA могут спросить дважды.
- В фоне запрос 2FA отменяется с ошибкой; подпись нужно запустить в открытом приложении.
- Новые установки используют один App ID; исправлены ID расширений при своём bundle ID.
- Патч SideSign: `macOS;` → `Mac OS X;` (HTTP 503 при входе).

## Первая установка и проверка
Ставить IPA через iloader / SideInstaller. Проверить: вход, установку приложения с расширением,
refresh, refresh самого LiveContainer, виджет, запуск приложения внутри LiveContainer.
Проверяйте на запасном Apple ID.

## Диагностика
- Сборка: `dist/diagnostics.zip` (в Actions — артефакт `diagnostics`). Начинать с `summary.txt`.
- iPhone: файл `diagnostics.log` в Documents SideStore (и `diagnostics.log.old`).
  Внутри LiveContainer ищите его через «Файлы» или файловый браузер LiveContainer.
- Личные данные скрываются по шаблонам, это не гарантия: перед отправкой просмотрите файл.
  Team ID, bundle ID и серийные номера сертификатов остаются.
- Вылет самого приложения в этот лог может не попасть: пришлите `.ips` из
  Настройки → Конфиденциальность и безопасность → Аналитика и улучшения → Данные аналитики.

## Репозиторий
Для GitHub Actions используйте приватный репозиторий: workflow сохраняет IPA как артефакт.

## Лицензии
LiveContainer и SideStore: AGPL-3.0.
`SideStore/Dependencies/sisign` основан на SideInstaller by FrizzleM (https://github.com/FrizzleM/SideInstaller),
лицензия в `sisign/LICENSE.md`: только некоммерческое использование, распространение только в исходниках.
Собранную IPA не раздавайте. Изменения: убран idevice-ffi, добавлен `src/adopt.rs`,
правки `lib.rs`, `Cargo.toml`, заголовка и modulemap. У вложенных библиотек свои лицензии.
