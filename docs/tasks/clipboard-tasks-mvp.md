# Clipboard-to-task MVP

Status: approved for development; implementation pending.
Platforms: macOS and Windows.

## Goal

Capture copied text as a task in one action and return to it through a compact list. No mandatory project selection or form filling.

## Scope

- [ ] Prototype clipboard history with an “Add to tasks” action and a compact task window.
- [ ] Add a specific clipboard-history entry to tasks.
- [ ] Add current clipboard text through a configurable global shortcut.
- [ ] Open tasks through another configurable shortcut and the tray/menu-bar menu.
- [ ] Confirm capture without stealing focus, with a brief “Added to tasks” message and Undo.
- [ ] Support manual creation, editing, completion, reopening, deletion, and search.
- [ ] Provide Active and Completed views.
- [ ] Derive an editable title from the first non-empty line; preserve full text in the body.
- [ ] Use a compact window with bounded previews and internal scrolling; respect display scaling.
- [ ] Store tasks separately from clipboard history in encrypted local storage.
- [ ] Handle empty or non-text clipboard content gracefully.
- [ ] Preserve normal Copy/Paste shortcuts and report shortcut registration conflicts.

## Acceptance checks

- [ ] Both capture paths retain Unicode and multiline text.
- [ ] Capturing does not overwrite the system clipboard or steal focus.
- [ ] Undo removes only the newly created task.
- [ ] Tasks survive restart and application update.
- [ ] Clearing or trimming clipboard history never deletes tasks.
- [ ] Large lists and long text remain usable within the window.
- [ ] Manual creation, editing, completion, reopening, deletion, and search work.
- [ ] Persistence failures are reported and do not silently replace existing data.
- [ ] Layout switching, clipboard insertion, and existing shortcuts remain functional.
- [ ] Record automated tests and actual macOS/Windows smoke tests separately. Untested behavior must not be reported as verified.

## Deferred

Projects and categories, screenshots and attachments, due dates, reminders, Kanban boards, accounts, pairing, and clipboard/task synchronization.

## Delivery

Prototype → implementation → checks on both platforms → release preparation.
Commit and push verified changes to GitHub. This document records the task; the feature has not been implemented or released.
