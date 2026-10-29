# Подпись и нотариализация Spy

Обычная локальная сборка использует постоянный локальный сертификат. Она не имеет Developer ID и нотариализации. Скрипт распространения подготовлен, но без платного Apple Developer Program и сертификата **Developer ID Application** его нельзя выполнить. Apple Development для этого не подходит.

## Подготовка аккаунта

1. Создайте Developer ID Application в своём аккаунте Apple Developer и установите сертификат с приватным ключом в свою связку ключей. Ключ не добавляйте в проект.
2. Создайте профиль `notarytool` в Keychain через интерактивную команду `xcrun notarytool store-credentials SpyNotary`. Данные аккаунта вводите локально по запросу инструмента. Пароль не должен находиться в исходниках, переменных проекта или истории команд.
3. Проверьте публичные названия установленных сертификатов: `security find-identity -v -p codesigning`.

## Выпуск

```sh
export SPY_DEVELOPER_ID='Developer ID Application: Your Name (TEAMID)'
export SPY_NOTARY_PROFILE='SpyNotary'
zsh distribute-macos.sh --check
zsh build.sh "$PWD/build/Spy.app"
zsh distribute-macos.sh "$PWD/build/Spy.app" "$PWD/build/notarized-release"
```

Скрипт работает с отдельной копией приложения. Он подписывает вложенный установщик и приложение, включает Hardened Runtime, ставит защищённую временную метку, отправляет ZIP в Apple, проверяет `Accepted`, прикрепляет и проверяет билет. Затем создаёт ZIP/DMG, нотариализует DMG и пересчитывает SHA-256. Исходная локальная сборка и её подпись не меняются. Ошибка любого шага останавливает выпуск. Файлы `notary-*-result.json` служат диагностикой и не предназначены для публикации.

После появления Developer ID новую версию потребуется установить вручную один раз: обновлятор Spy требует совпадения сертификата установленной и новой версии. Проверьте доступ к экрану и микрофону на тестовом Mac, затем дальнейшие обновления подписывайте тем же Developer ID. Пароли, сертификаты с приватными ключами, записи, настройки и локальные отчёты в GitHub не загружаются.

Официальные требования: [подготовка к нотариализации](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution), [сценарий notarytool](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).
