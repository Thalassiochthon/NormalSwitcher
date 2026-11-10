<p align="center">
  <img src="macos/icon.png" width="112" alt="NormalSwitcher">
</p>

<h1 align="center">NormalSwitcher</h1>

<p align="center">
  Correct text typed in the wrong keyboard layout.<br>
  Исправляйте текст, набранный в другой раскладке.
</p>

<p align="center">
  <a href="https://github.com/Thalassiochthon/NormalSwitcher/releases">Downloads / Скачать</a> ·
  <a href="https://github.com/Thalassiochthon/NormalSwitcher/issues">Feedback / Обратная связь</a>
</p>

NormalSwitcher is an independent fork of [RuSwitcher](https://github.com/rashn/RuSwitcher),
with separate macOS and Windows builds. This branch contains the macOS app; the
[Windows source and build instructions](https://github.com/Thalassiochthon/NormalSwitcher/tree/windows-preview/windows)
are maintained separately.

Typed `ghbdtn` instead of `привет`? Use a configurable shortcut to convert the last
word or selected text. Optional automatic correction checks words locally, using
the available system dictionaries and optional word packs. Support depends on
the selected layouts and dictionaries; ambiguous words can be left unchanged.

Набрали `ghbdtn` вместо `привет`? Настраиваемая горячая клавиша исправит последнее
слово или выделение. Можно включить автоматическое исправление. Проверка слов
выполняется на устройстве; результат зависит от раскладок и доступных словарей.

## macOS beta: clipboard tasks

**Available in [1.2.0a beta](https://github.com/Thalassiochthon/NormalSwitcher/releases/tag/v1.2.0a).**
Enable **Settings → About → Get beta versions**, then check for updates.
Users with beta updates disabled continue to receive stable releases only.
[Beta publication and promotion process](release/BETA.md).

| Action | Default shortcut |
| --- | --- |
| Open clipboard history | Control + Shift + V |
| Open tasks | Control + Shift + T |
| Save current clipboard text as a task | Control + Option + Shift + V |

Change these in **Settings → Clipboard**. Each task shortcut can be disabled
independently. Tasks remain available from the menu and settings.

- A compact clipboard window shows the latest eight entries. Search covers all
  saved entries; **All entries** shows the full list, up to 30 text entries.
- Select an entry and choose **Add to Tasks** or **Paste**. Return pastes the
  selected entry; double-click also pastes. Escape closes the window.
- Tasks have a title, full text, and Active/Completed state. Click a title or
  select a row and press Return to edit. New tasks, search, completion, deletion,
  and a brief Undo after capture are included. No accounts or sync are required.
- Task files and persistent clipboard history use separate AES-GCM encryption
  keys in this Mac's Keychain. Old clipboard JSON is removed only after the new
  encrypted copy has been read back successfully. An error leaves existing data
  intact and offers **Retry**; new clipboard entries stay in memory until exit.
- Clearing clipboard history does not delete tasks. Turning persistence off
  removes saved history while keeping the current session's entries in memory.
- The menu shows why automatic correction is unavailable, or which word-ending
  keys trigger a check. This is a readiness status, not a guarantee for every word.

### По-русски

Новые возможности доступны в [бете 1.2.0a](https://github.com/Thalassiochthon/NormalSwitcher/releases/tag/v1.2.0a).
Включите «Настройки → О программе → Получать бета-версии», затем проверьте обновления.
Без этой галочки программа получает только стабильные выпуски.

Откройте историю буфера через **Control + Shift + V**, выберите запись и нажмите
**«В задачи»**. **Control + Option + Shift + V** сразу сохраняет текущий текст буфера
как задачу. **Control + Shift + T** открывает задачи. Все сочетания меняются в
«Настройки → Буфер обмена»; сочетания для задач можно отключить по отдельности.

В быстрой истории видны восемь последних записей, поиск работает по всей истории.
Задачи можно создавать, искать, редактировать, завершать и удалять. Они сохраняются
отдельно от буфера, поэтому очистка истории их не затронет. История и задачи
шифруются на этом Mac, ключи хранятся в Связке ключей. При ошибке хранилища нажмите
«Повторить» — новые записи до успешного сохранения остаются только в памяти.

## Build and test

Requires macOS 13 or newer and Swift 6. Use an Xcode toolchain with Swift Testing
for the tests. The build script produces `macos/NormalSwitcher.app`.

```sh
swift test --package-path macos
./macos/build_app.sh
```

Builds use ad-hoc signing unless `RS_SIGN_ID` supplies a signing identity.
Release updates use a stable signing identity and the existing application ID.
The development branch does not publish an update just by pushing source changes.

[macOS audit and remaining verification](docs/audits/macos-2026-11-10.md)

## Credits

Based on [RuSwitcher by rashn](https://github.com/rashn/RuSwitcher).
The original author's copyright and [MIT license](LICENSE) are retained.
NormalSwitcher maintains its own release files, update feeds, and dictionary packs.
