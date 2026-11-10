<p align="center">
  <img src="macos/icon.png" width="112" alt="NormalSwitcher">
</p>

<h1 align="center">NormalSwitcher</h1>

<p align="center">
  Исправляет текст, набранный в другой раскладке, и переключает клавиатуру.<br>
  Corrects text typed in the wrong keyboard layout and switches your keyboard.
</p>

<p align="center">
  <a href="https://github.com/antonjas/NormalSwitcher/releases/tag/v1.1.3"><b>Скачать для macOS</b></a>
  ·
  <a href="https://github.com/antonjas/NormalSwitcher/releases/tag/win-v0.2.4"><b>Скачать для Windows</b></a>
  ·
  <a href="https://github.com/antonjas/NormalSwitcher/releases">Все версии</a>
</p>

Набрали `ghbdtn` вместо `привет`? Нажмите горячую клавишу, чтобы исправить последнее слово или выделенный текст. Можно включить автоматическое исправление при наборе. Для проверки слов приложение использует словарь вашей системы, проверка выполняется на устройстве.

| Возможность | macOS | Windows Preview |
| --- | --- | --- |
| Исправить последнее слово или выделение | Настраиваемая клавиша, по умолчанию Option ⌥ | Настраиваемая клавиша, по умолчанию два нажатия Ctrl |
| Исправлять раскладку при наборе | По пробелу, с настройками для Enter и Tab | По пробелу в поддерживаемых полях ввода |
| Исключения для слов | Есть | Есть |
| История буфера обмена | До 30 текстовых записей, своё сочетание клавиш | — |
| Настройки и индикатор раскладки | В строке меню | В области уведомлений |

## macOS

Сборка для **Apple Silicon**. Требуется **macOS 13 или новее**. Откройте [страницу релиза macOS](https://github.com/antonjas/NormalSwitcher/releases/tag/v1.1.3), перенесите приложение в «Программы» и запустите. macOS попросит разрешения для работы с клавиатурой. В настройках NormalSwitcher можно выбрать пару раскладок, включить автоисправление и настроить историю буфера обмена.

[Исходники macOS](https://github.com/antonjas/NormalSwitcher/tree/personal/macos)

## Windows

Для **предварительной версии** доступны установщик и переносимые сборки x64 и ARM64. Скачайте подходящий файл со [страницы релиза Windows](https://github.com/antonjas/NormalSwitcher/releases/tag/win-v0.2.4). После запуска настройки доступны по значку в области уведомлений. Автоисправление выключено по умолчанию. В этой версии оно работает в полях, где программа может проверить текст перед заменой.

[Исходники и инструкция по сборке Windows](https://github.com/antonjas/NormalSwitcher/tree/windows-preview/windows)

## О проекте

NormalSwitcher — открытый форк [RuSwitcher](https://github.com/rashn/RuSwitcher) с отдельными выпусками для macOS и Windows. Код доступен по [лицензии MIT](LICENSE).

[Сообщить об ошибке или предложить улучшение](https://github.com/antonjas/NormalSwitcher/issues)
