# Clipboard Manager

macOS menu bar clipboard history app.

## IMPORTANT: After Building — ALWAYS Redeploy and Relaunch
`/Applications/Clipboard Manager.app` is a **real copy**, NOT a symlink (it used to be one — verify with `ls -ld` before assuming). So building alone changes nothing the user sees: you must quit, replace the bundle, and reopen.
```bash
APP=~/Library/Developer/Xcode/DerivedData/Clipboard_Manager-enxbpizjncmbvoguyhpqnzumfbit/Build/Products/Debug/"Clipboard Manager.app"
pkill -x "Clipboard Manager"; sleep 1
rm -rf "/Applications/Clipboard Manager.app" && ditto "$APP" "/Applications/Clipboard Manager.app" && open "/Applications/Clipboard Manager.app"
```
`open` on a still-running instance just re-activates the STALE binary — always confirm the process is dead first.
**Do NOT re-sign** with `codesign` — changing the signature invalidates the Accessibility permission (needed for Cmd+V paste). The Xcode build signature is sufficient.

Also note: with Xcode 16, app code lives in `Clipboard Manager.debug.dylib`, **not** the small stub executable — grep the dylib when verifying a build actually contains your change.

## Architecture
- **Type**: Menu bar app (LSUIElement, no Dock icon)
- **UI**: NSPanel (floating, non-activating, resizable) with SwiftUI content via NSHostingView
- **Storage**: SwiftData at `~/Library/Application Support/ClipboardManager/ClipboardHistory.store`
- **Monitoring**: Timer polling NSPasteboard.general.changeCount every 0.5s
- **Global Hotkey**: Carbon HotKey API (Cmd+Shift+V default, configurable), multi-hotkey for snippets

## Bundle ID
`com.DNZ.clipboard-manager`

## Structure
```
Clipboard Manager/
  App/
    ClipboardManagerApp.swift    - @main, CommandGroup overrides Cmd+,
    AppDelegate.swift            - NSStatusItem, panel, hotkey, paste-into-app
  Models/
    ClipboardEntry.swift         - SwiftData @Model, ContentType enum
    SavedSnippet.swift           - SwiftData @Model for saved text snippets
  Services/
    ClipboardMonitor.swift       - Pasteboard polling, entry creation, OCR, pruning
    HotkeyManager.swift          - Carbon global hotkey (multi-hotkey: toggle + per-snippet)
    SettingsManager.swift        - UserDefaults preferences, KeyCombo
    SnippetTokenResolver.swift   - Resolves {{clipboard}}, {{date}}, {{time}} etc. in snippets
  Views/
    ClipboardPanel.swift         - NSPanel subclass (borderless, resizable, persists size)
    ClipboardListView.swift      - Main view: search, filters, list, settings overlay, Clipboard/Snippets toggle
    ClipboardRowView.swift       - Row: app icon + text + timestamp + thumbnail
    SnippetListView.swift        - Snippet list with drag-reorder, inline shortcut recording, icon picker, folders
    SnippetEditorView.swift      - Snippet editor: rich text, format toolbar, SF Symbol picker, token buttons, hotkey
    ClipboardDetailView.swift    - Expanded view: zoomable images, RTF, plain text
    FilterBar.swift              - Date/app/type filter popover with FlowLayout
    SettingsView.swift           - TabView: General, Shortcuts, Excluded Apps
  Utilities/
    AppIconResolver.swift        - NSWorkspace app icon cache
    KeyEventHandler.swift        - NSEvent local monitor for in-app shortcuts
```

## Key Features
- Shows source app icon next to each clipboard entry
- Screenshot detection (shows "Mac" + macbook icon)
- Image thumbnails with correct aspect ratio (height-capped, width-capped)
- OCR on images via Vision framework (searchable)
- PDF thumbnail generation via CGPDFDocument
- Filter by date range, source app, content type (multi-select)
- Search across text, app name, and OCR content
- Pinch-to-zoom on expanded image view (NSScrollView magnification)
- Enter key pastes directly into the previously active app (CGEvent Cmd+V)
- Self-paste detection: copying from the app moves entry to top, not duplicate
- Copy as plain text or with formatting (configurable shortcuts)
- Configurable keyboard shortcuts (with live recorder UI)
- Settings overlay within main panel (not separate window)
- History limit with pruning (pinned items exempt)
- Exclude specific apps from tracking
- Launch at login via SMAppService
- Window size persists across relaunches

## Saved Snippets
- Snippets are saved text templates with titles (display-only, not inserted)
- Token support: `{{clipboard}}`, `{{date}}`, `{{time}}`, `{{datetime}}`, `{{timestamp}}`, `{{date:FORMAT}}` (custom DateFormatter pattern)
- Each snippet can have an optional global hotkey (requires modifier key) — fires even when panel is closed
- HotkeyManager refactored to multi-hotkey: uses Carbon EventHotKeyID.id to dispatch to correct action
- Snippet hotkeys registered on launch and re-registered when snippets change (via `.snippetHotkeysChanged` notification)
- ClipboardMonitor has `snippetPasteFlag` to skip recording snippet pastes as history entries
- Save from clipboard: right-click context menu "Save to Snippets" on text/RTF/URL entries
- Snippets tab accessible via segmented control toggle in the top bar
- **Rich text editor**: NSViewRepresentable wrapping NSTextView for RTF editing — format toolbar with font, size, B/I/U, bullet/numbered lists with sublists
- **RTF storage**: `SavedSnippet.rtfData: Data?` stores rich text; pasteboard gets both RTF and plain text on paste
- **SF Symbol icons**: Each snippet/folder has optional `iconName: String?` — defaults to `square.dashed` for snippets, `folder` for folders
- **SF Symbol picker**: Loads all ~6000 symbols from `/System/Library/CoreServices/CoreGlyphs.bundle` plist, categorized, searchable, preloaded at app launch on background thread
- **Folder icons**: Folders render as ZStack — folder shape with custom icon overlaid inside (not yellow standalone icons)
- **Inline shortcut recording**: Tap shortcut badge in snippet list to record hotkey in-place (pulsing red circle indicator)
- **Drag-to-reorder**: DropDelegate distinguishes reorder (between items, blue indicator) vs folder drop (onto folders)
- **Delete shortcut**: Works in both clipboard and snippets tabs via `.snippetDeleteSelected` notification
- **Snippet preview lines**: Configurable via Settings (None, 1, 2, 3, 5 lines)
- **Auto-folder**: Adding new snippet when a folder or child is selected auto-assigns to that folder

## Lessons Learned

### SwiftUI Image Thumbnails
- `.resizable()` with `.frame(width:height:)` can be unreliable in HStack layouts
- **Solution**: Pre-render the NSImage at exact target size, display WITHOUT `.resizable()`
- Use `NSImage.lockFocus()` / `draw(in:)` / `unlockFocus()` to create exact-size image
- `NSImage.size` returns points (may differ from pixels on Retina)
- A live slider (`ThumbnailSizeAdjuster`) was useful for tuning the maxWidth value (settled on 80pt)

### Paste Into Previous App
- Track `NSWorkspace.shared.frontmostApplication` BEFORE showing the panel
- `CGEvent.post(tap: .cghidEventTap)` requires **Accessibility permissions**
  - System Settings → Privacy & Security → Accessibility → add the app
  - Without it, CGEvent posting silently fails (no error)
- Use 0.20s delay after `prevApp.activate()` before posting Cmd+V
- Virtual key code for V = `0x09`
- **Accessibility silently revoked by entitlement/signature changes**: when the app's
  entitlements change (e.g. adding `com.apple.security.personal-information.location` for
  the `{{latlon}}` token), macOS drops the existing Accessibility grant. Symptom: paste
  "fires" (`Cmd+V posted` logs ok) but nothing appears — capture still works, only the
  synthetic keystroke is dead. Fix: re-grant in Accessibility (toggle off/on, or remove +
  re-add) then relaunch. `postCmdV()` now guards with `AXIsProcessTrusted()` and calls
  `promptForAccessibility()` (system prompt + deep link) instead of failing silently.
  Diagnose with: log `AXIsProcessTrusted()` + clipboard contents in `postCmdV`.

### Self-Paste Detection
- When copying from within the app, the ClipboardMonitor detects the pasteboard change
  and would create a duplicate entry
- **Solution**: Set `clipboardMonitor.selfCopiedEntryID` before copying to pasteboard
- Monitor checks this flag: if set, updates the entry's timestamp (moves to top) instead
  of creating a new entry

### NSEvent Local Monitor vs TextField
- `NSEvent.addLocalMonitorForEvents` catches key events app-wide
- BUT: TextField's responder chain swallows Return/Enter before the monitor sees it
- **Solution**: Also add `.onSubmit {}` on the TextField for Enter key handling
- Arrow keys: KeyEventHandler must check `inTextField` flag — only intercept arrows when NOT in a text field, otherwise cursor navigation breaks
- Copy/delete shortcuts in text fields: Only intercept when a real modifier (Cmd/Option/Control) is held (`hasRealModifier` check), so Enter creates newlines and Delete works normally in the editor
- `isRecordingShortcut` global flag suppresses KeyEventHandler during inline shortcut recording

### Settings Within Panel
- Using a separate `Settings {}` scene intercepts Cmd+, even when empty
- **Solution**: Remove Settings scene, use `CommandGroup(replacing: .appSettings)` in Window scene
- Settings rendered as overlay (`ZStack`) within the main panel view
- Don't add `Divider()` between header and TabView — creates unwanted line

### Screenshot Detection
- The frontmost app during screenshot is NOT the screenshot utility
- Bundle ID check alone is unreliable
- **Solution**: Check bundle ID OR (pasteboard has screenshot type AND no text content)
- Screenshot entries get `sourceAppName: "Mac"`, `bundleID: nil`, icon: `macbook` SF Symbol

### Debug Logging in SwiftUI
- `NSLog()` inside SwiftUI ViewBuilder (via `let _ = NSLog(...)`) does NOT reliably execute
- `NSLog()` output may not appear in `log stream` for sandboxed/unsigned apps
- **Solution**: Write to a file (`/tmp/clipboard-manager-debug.log`) using FileHandle
- Remember to clean up debug logging after fixing the issue

### NSScrollView for Pinch-to-Zoom
- SwiftUI's `MagnifyGesture` / `.onMagnify` doesn't work on ScrollView
- **Solution**: Use `NSViewRepresentable` wrapping `NSScrollView` with `allowsMagnification = true`
- Constrain `NSImageView` to clip view bounds with Auto Layout
- Use `.scaleProportionallyDown` (not `.scaleProportionallyUpOrDown` which crops large images)

### Clipboard Persistence
- Default SwiftData store path changes between launches
- **Solution**: Use fixed `ModelConfiguration(url:)` pointing to App Support directory

### Rich Text Editor (NSTextView)
- SwiftUI TextEditor doesn't support rich text — must use NSViewRepresentable wrapping NSTextView
- Coordinator manages formatting commands (bold/italic/underline/font/size/lists)
- Lists implemented via NSTextList in paragraph style — sublists need indented NSTextList arrays
- RTF data stored via `NSAttributedString.rtf(from:documentAttributes:)`
- On paste, both `.rtf` and `.string` types set on pasteboard for maximum compatibility

### SF Symbol Loading
- CoreGlyphs.bundle contains `symbol_search.plist` with all system SF Symbol names
- Loading ~6000 symbols is slow — preload via `SFSymbolLoader.shared.load()` on background thread at app launch
- Filter out locale-specific variants (containing `.`) for cleaner results
- Categories assigned by keyword matching on symbol names

### Smooth Deletion
- When deleting items, compute the next selection BEFORE performing the delete
- Otherwise SwiftUI re-renders with stale selection causing visual jump
- Pattern: find next item in list → update selection → then delete from model context

### Custom Date Token
- `{{date:FORMAT}}` uses NSRegularExpression (not Swift regex literals — those cause parser errors in complex SwiftUI files)
- Pattern: `\{\{date:([^}]+)\}\}` — capture group is the DateFormatter format string

### Multi-Item Paste (Enter / Shift+Enter)
- **Enter and Shift+Enter are NOT `onEnter` / `onShiftEnter`.** They are the *default key
  combos* of the configurable **Copy Plain** (`Return`) and **Copy Formatted**
  (`Shift+Return`) shortcuts, and `KeyEventHandler.handleKeyEvent` matches those
  shortcut combos **first**, so `onEnter` / `onShiftEnter` never fire for them. Any change
  to Enter behaviour must go through `onCopyPlain` / `onCopyFormatted` (both now just call
  `pastePrimary()` / `pasteAlternate()`, and `onEnter`/`onShiftEnter` call the same two, so
  either route works).
- Selection order is tracked in `selectionOrder: [UUID]` alongside `selectedIDs: Set<UUID>`.
  Cmd-click appends; shift-click / shift+arrow **replaces** it with list order (so a range
  selection always pastes top-to-bottom). `selectedEntriesInOrder` resolves it and falls back
  to list order for anything missing. Every place that mutates `selectedIDs` must also mutate
  `selectionOrder` or the order silently degrades.
- Separators: `multiPasteSeparator` (Enter) + `multiPasteAltSeparator` (Shift+Enter), each
  with a `...CustomSeparator` companion. `SettingsManager.unescape` turns `\n` / `\t` / `\r`
  into real characters — **required**, because the custom separator is a single-line
  `TextField` and a literal newline can't be typed into it. Alt separator also supports
  `"ask"`, which pops a numbered NSMenu (`SeparatorMenuTarget`) to choose per-paste.

### Pasting Multiple Images
- A pasteboard holding several image `NSPasteboardItem`s pastes as **only the first image**
  in virtually every app (Mail included) — apps read item 0's types and stop.
- **Solution**: for a multi-selection containing images (`multiPasteboardItems(for:)`), write
  each image to a temp PNG under `NSTemporaryDirectory()/ClipboardManager/<uuid>.png` and put
  it on the pasteboard as a **`.fileURL`** item (plus `.png`/`.tiff` on the same item). Mail,
  Word, Notes and Finder all accept a multi-file paste and inline/attach every one.
- Single-image paste still uses raw image data — don't route it through the file-URL path.

### Typing Text Directly (snippets) — and the modifier-leak trap
- Plain-text snippets are **typed** with `CGEvent.keyboardSetUnicodeString`, not pasted, so
  the clipboard is never touched (no snapshot/restore, no paste race). Rich/formatted
  snippets still must go through the pasteboard — typing can't carry formatting.
- **The trap that cost hours**: a typed event is built with `virtualKey: 0`, which is the
  **`a` key**. With `CGEventSource(stateID: .combinedSessionState)` the event merges with the
  **physical** keyboard state, so while the user is still holding a snippet hotkey's
  modifiers (⌘⌥⌃ for the date snippet) the very first typed keystroke is delivered as
  **⌘⌥⌃A** — which fired Window Manager's "cascade all windows" hotkey. Symptom: "my date
  shortcut cascades my windows."
- **Fix**: use `CGEventSource(stateID: .privateState)` **and** set `event.flags = []` on both
  the keyDown and keyUp of every chunk. Never use the combined source for typing.
- **Diagnosing it**: don't trust a synthetic keypress. macOS frequently refuses to let
  simulated key events trigger **global (Carbon) hotkeys** — the ability comes and goes, so a
  "no cascade" result can be a dead test rig, not a fix. **Always run a control** (synthesize a
  hotkey you know works and confirm it fires) before believing any negative result. What *is*
  reliable is a `CGEvent.tapCreate` listen-only tap that reports the `flags` on the events you
  post — that measures the real delivered event and needs no hotkey dispatch.
- A conflicting hotkey in another app is worth ruling out, but check each app's OWN log/config
  for what it actually registered. Here neither BetterTouchTool nor Window Manager had `;`
  bound at all — the caller was this app the whole time.
