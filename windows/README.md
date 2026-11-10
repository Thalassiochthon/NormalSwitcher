# NormalSwitcher for Windows

**Status: preview 0.1.0.** A Windows tray application based on [RuSwitcher](https://github.com/rashn/RuSwitcher).
The portable x64 build includes the .NET runtime. Extract the archive, run `NormalSwitcher.exe`,
then use the tray icon for settings or to quit. Add both keyboard layouts in Windows and tap
**Ctrl twice** to correct the last word or the selected text.

The dictionary checks run on your device. The preview leaves automatic update checks off by default.

## Features

- **Manual trigger** — double-tap Ctrl (default), double-tap Shift, or the Pause/Break key.
  Converts the last typed word, the current selection, or the whole line into the other layout,
  and switches the keyboard. Trigger it again with nothing typed since to reverse (toggle).
- **Whole-line conversion** (issue #24) — convert the entire current line, not just the last word.
- **Smart selection conversion** (issue #22) — keeps words that are already correct, flips only the
  gibberish (dictionary-driven).
- **Trailing punctuation** kept literally (issue #15) — `ghbdtn,` → `привет,`.
- **As-you-type auto conversion** (beta, off by default) — flips a word right after Space when the
  dictionary is confident it was typed in the wrong layout. This preview applies automatic edits only
  to supported native text fields where the caret and original text can be verified. A later keypress
  or mouse click cancels a pending edit. Reversing an auto-conversion teaches a "never convert"
  exception.
- **Exception lists** — never-convert / always-convert, editable in Settings → Exceptions.
- **Layout-switch hotkey** (issue #14) — a separate hotkey that only switches the layout.
- **Per-app layout memory** — remembers and restores each application's last-used layout.
- **Layout sound** (issue #7) and a **layout indicator** in the tray menu.
- **Launch at startup**, **auto-update check**, and a settings window.
- **Localized UI** — English and Russian (more languages to follow; falls back to English).

## Engine mapping

| macOS mechanism | Windows counterpart |
|---|---|
| CGEventTap | `SetWindowsHookEx(WH_KEYBOARD_LL)` |
| CGEvent keyboardSetUnicodeString | `SendInput` + `KEYEVENTF_UNICODE` |
| Carbon `UCKeyTranslate` | `ToUnicodeEx` |
| TIS layout switching | `WM_INPUTLANGCHANGEREQUEST` |
| NSSpellChecker | `ISpellChecker` (Windows 8+) |
| NSStatusItem | `Shell_NotifyIcon` |
| per-app frontmost observer | `SetWinEventHook(EVENT_SYSTEM_FOREGROUND)` |

## Build & test

Requires the .NET 8 SDK. On Windows:

```
dotnet build   windows/src/RuSwitcher.Win/RuSwitcher.Win.csproj -c Release
dotnet test    windows/tests/RuSwitcher.Win.Tests/RuSwitcher.Win.Tests.csproj -c Release
dotnet publish windows/src/RuSwitcher.Win/RuSwitcher.Win.csproj -c Release -r win-x64 `
  --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true
```

The project sets `EnableWindowsTargeting`, so it also **compiles** on macOS/Linux (a fast
compile-check); the real build/test/exe come from the `windows-build` CI on a Windows runner. The
P/Invoke code cannot *run* off Windows.

## Distribution

- **Release track:** push a `win-vX.Y.Z` tag → the `windows-release` workflow builds, tests, publishes
  the single-file exe (x64 + arm64), compiles the Inno Setup installer, computes SHA-256, and creates
  a GitHub release (pre-release for `0.x`). Code signing runs automatically **if** the
  `WINDOWS_CERT_PFX_BASE64` + `WINDOWS_CERT_PASSWORD` secrets are set; otherwise it ships unsigned.
- **Update feed:** `windows/version.json` (separate from the repository-root `version.json`, which is
  the **macOS** feed and must stay where it is). The app checks it once a day and offers to open the
  download page.
- **Installer:** [`installer/RuSwitcher.iss`](installer/RuSwitcher.iss) (Inno Setup, per-user).
- **WinGet:** the checked-in manifests describe the upstream RuSwitcher package. NormalSwitcher
  has no WinGet package in this preview.

The Windows version is versioned **separately** from macOS (`win-vX.Y.Z`).
