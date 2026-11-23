# PSTrace (Avalonia edition)

A rewrite of the WPF PSTrace.ps1 log viewer from schrebra/Alternative-CMTrace
as a C# Avalonia application, structured after Brandon's
Powershell-Bootstrap-CSharp pattern: a single PowerShell bootstrap script
that finds or installs a .NET 8 SDK, writes the embedded C# sources into a
clean workspace, publishes a self-contained win-x64 executable, verifies it,
and launches it.

## Layout

| Path | What it is |
| --- | --- |
| `PSTrace.ps1` | The bootstrap script (the deliverable entry point). Same 8-stage flow, helper functions, exit codes, and clean-slate semantics as the bootstrap pattern's Avalonia showcase, with the PSTrace sources embedded and with file-argument forwarding added. |
| `src/PSTrace/` | The same C# project as a normal on-disk project (csproj, Program.cs, App, MainWindow, SettingsWindow, ErrorLogWindow, RemoteOpenWindow, LogParser.cs, LogTailer.cs, AppConfig.cs, RemoteLogPath.cs). This is the copy that was compiled and verified during development; the bootstrap embeds byte-identical sources (verified by a round-trip comparison of all 16 files). |
| `src/PSTrace/publish/PSTrace.exe` | The verified build artifact: self-contained, single-file, win-x64 (43.5 MB, PE32+ x86-64 GUI executable). |
| `tests/` | Four test projects (parser, tailer, remote path, headless view) plus `run-tests.sh`, which runs all of them. |
| `Register-PSTraceContextMenu.ps1` | Per-user (HKCU) Explorer integration for feature A. No admin rights needed. |
| `Unregister-PSTraceContextMenu.ps1` | Removes everything the register script adds. |

How the layout maps to the bootstrap pattern:

- The csproj keeps the pattern's property group: net8.0, WinExe,
  SelfContained, win-x64 only, PublishSingleFile, and the pattern's pinned
  Avalonia 11.0.10 packages (Avalonia, Avalonia.Win32, Avalonia.Skia,
  Avalonia.Themes.Fluent). One package is added: Avalonia.Controls.DataGrid
  11.0.10, because PSTrace's log grid needs it and the showcase app has no
  grid.
- Program.cs keeps the pattern's crash handling: a fatal error is written
  to crash.log next to the executable and shown in a MessageBox.
- The bootstrap's stage flow, SDK detection (Find-DotNetSdk), user-local
  SDK install under %LOCALAPPDATA%\Microsoft\dotnet with no elevation,
  restore with `-r win-x64`, publish flags
  (`/p:UseSharedCompilation=false /p:NodeReuse=false`), artifact check
  (exe exists and is at least 1 MB), and Start-Process launch are carried
  over unchanged in shape.
- Two deliberate deviations from the showcase script, both for feature C:
  the script takes `-FilePath` plus trailing arguments and forwards them
  to the published exe in Start-PublishedApp (the showcase forwards
  nothing), and PositionalBinding is disabled in the param block so a
  bare file path can never be swallowed as the project name.

## Building and running

On Windows, from this folder:

```powershell
.\PSTrace.ps1                # build and launch
.\PSTrace.ps1 -NoLaunch      # build only
```

The executable lands in `PSTrace\publish\PSTrace.exe` next to the script.
Alternatively, with any .NET 8 SDK: `dotnet publish -c Release -r win-x64`
inside `src\PSTrace`.

## Feature A: Explorer right-click "Open with PSTrace"

Two halves:

1. The app accepts a file path as a command-line argument.
   `Program.Main` passes `args` to Avalonia's desktop lifetime, and
   `App.FindFileArgument` returns the first argument that is an existing
   file; `MainWindow` opens it as soon as the window is shown. A UNC
   argument is accepted without the existence check (see feature D for
   why). The original PSTrace.ps1 accepted no file argument at all, so
   this is new.
2. `Register-PSTraceContextMenu.ps1` writes, under
   `HKCU\Software\Classes` only:
   - a `PSTrace.LogFile` progid whose `shell\open\command` is
     `"<path to PSTrace.exe>" "%1"`,
   - a `*\shell\OpenWithPSTrace` verb ("Open with PSTrace") with the same
     `"%1"` command, so the entry appears on the right-click menu of
     every file,
   - a `.log\OpenWithProgids` value, so PSTrace is offered in the
     "Open with" list for .log files without taking over the extension.
   `-SetAsDefaultForLog` additionally makes PSTrace the default .log
   handler. `Unregister-PSTraceContextMenu.ps1` removes the verb, the
   progid, and the OpenWithProgids value, and clears the .log default
   only if it still points at PSTrace.

## Feature D: view logs on remote computers

File, Open Remote opens a small dialog with two fields: a computer name
and the path on that computer. PSTrace composes them into a UNC path
(`\\computer\path`) and opens it through exactly the same code path as a
local file, so tailing (500 ms polling, FileShare.ReadWrite), filters,
statistics, and search all behave identically over plain SMB. No agent,
service, or extra protocol is involved on the remote machine. Details:

- Admin shares work: `C$\Windows\Logs\file.log` on computer `DC1` opens
  `\\DC1\C$\Windows\Logs\file.log`, provided the account running PSTrace
  has rights on that computer.
- Pasting a full UNC path into the Path field works too: it is used
  as-is. The dialog shows the composed path live as you type.
- A UNC path also works everywhere else a path is accepted: as a
  command-line argument (so the Explorer verb opens network files), and
  as a drag-and-drop target. UNC paths are deliberately not probed with
  File.Exists on the UI thread or at startup, because probing a dead
  host would stall for the whole Windows SMB timeout; the tailer
  reports reachability instead.
- Failures are visible, never a silent empty window: if the file cannot
  be reached for a few seconds, the status bar shows a "Cannot reach"
  message naming the path and suggesting the computer name, share, and
  permissions be checked, and the same text lands in Tools, View Error
  Log. IO errors while tailing (access denied, host dropped) appear in
  the status bar the same way and clear on the next successful read.
  One caveat: on a completely dead host the first probe itself can take
  the Windows SMB timeout to return, so the message can take that long
  to appear; the wait happens on the tailer thread and the window stays
  responsive throughout.

## Feature B: drag and drop onto the running window

`MainWindow` enables Avalonia DragDrop on itself
(`DragDrop.SetAllowDrop`). DragOver and DragEnter set the Copy effect
when the drag carries files; the Drop handler reads
`e.Data.GetFiles()`, resolves each `IStorageFile` to its local path, and
opens the first file. If several files are dropped, the rest are not
opened and the status bar says so. Dropping a file behaves exactly like
File, Open: the current tail stops and the new file is tailed from the
start.

## Feature C: drop a file on the PSTrace icon

This is feature A's argument handling seen from the other side: Windows
starts the target of a drop with the dropped path as its first argument.
It works when the icon is:

- the published `PSTrace.exe` itself, or a shortcut to it, or
- a shortcut to the bootstrap used like
  `powershell.exe -File "<folder>\PSTrace.ps1" "%1"` (a bare path lands
  in the script's forwarded arguments, and Start-PublishedApp passes it
  on to the exe with quoting).

The shortcut must point at the built exe (or at a wrapper that forwards
its arguments, such as the bootstrap). A shortcut that points at
something which does not forward `%*` will launch PSTrace with no file
open.

## Carried-over PSTrace behavior

- Parsing: a line is a CMTrace entry only if it starts with `<![LOG[` and
  contains `]LOG]!>` plus `type="..."` and `time="..."` attributes after
  the message; a CMTrace-looking line missing either attribute is dropped,
  exactly as the original. Other lines become plain entries. The grid's
  Time column shows the first 12 characters of the time value
  (HH:mm:ss.fff), or `??:??:??.???` when the value is shorter; the parser
  also keeps the bracketed form (`[HH:mm:ss.fff]`) that the original
  displayed. Each entry additionally carries its date, component, and
  thread as separate fields, shown in their own grid columns and in the
  details pane. Lines longer than 1,048,576 characters are dropped.
  Bracket-format lines (`[2025-10-05 19:53:37] [Info] message`, written
  by tools that prefix each line with a bracketed timestamp and level)
  are recognised when the leading token is a valid date and time: the
  entry gains Date and Time fields from the token, and the grid's Log
  Text column shows only the message after the level token, since the
  timestamp and level already have their own columns. The full original
  line is kept for the details pane, copy, and find, and severity is
  still decided on the whole line, so the level token and message
  keywords combine exactly as they did when the line was treated as
  plain text.
- Severity: the keyword list is checked against the message first
  (case-insensitive substring, longest keyword wins, and the keyword
  itself becomes the level); only when no keyword matches does the
  numeric type decide (3 Error, 2 Warn, 1 Info, anything else Info).
  Default keywords and colors are Brandon's set: Critical, Error,
  Exception, Failed in red; Warn in orange; Success in green; Verbose in
  blue; Info in white. The color maps are dark-palette pairs (a row
  fill and a text color per level, plus a saturated stripe color),
  redesigned for contrast in the theme round below.
- Tailing: a background thread polls the file every 500 ms with
  FileShare.ReadWrite, assembles multi-line CMTrace entries (a plain line
  directly after a CMTrace entry is treated as a continuation of that
  entry, as in the original), holds a trailing partial entry until its
  terminator arrives, resets to offset 0 on truncation or rotation, and
  backs off exponentially on IO errors up to 30 s.
- UI: a single menu strip carries the File menu (Open Ctrl+O, Open
  Remote, Exit), the Edit menu (Search Ctrl+F), and the Tools menu
  (Settings, View Error Log), then the icon-only Pause and Auto-Scroll
  buttons, then a flexible search box (it stretches with the window
  between 150 and 440 px) with an in-box Search watermark, a live
  match count, and Next and Clear buttons; one filter chip per level on its own row below (all chips on
  means no filtering); clicking a row in the statistics panel filters
  to only that type, and a Clear filter button under the statistics
  restores every type; the log as a multi-column grid (Time, Type,
  Component, Thread, Log Text) with row virtualization, where the
  Component and Thread columns hide themselves when no loaded entry
  carries those values (plain and bracket-format logs) and reappear if
  a value shows up; the empty-state
  overlay with an Open button; the bottom details pane (splitter, Copy
  button) with a structured field strip (time, date, type, component,
  thread) above the message body, whose formatter pretty-prints JSON and
  then splits on the configured delimiters; the right-hand statistics
  panel (sortable Type, Count, %, with a total row); the 10,000,000
  entry retention cap with front trimming above 11,000,000; statistics
  refresh throttled to once per second. The Pause button swaps between
  pause bars and a play triangle; the Auto-Scroll button uses the
  CMTrace auto-scroll glyph (log lines with an arrow descending to a
  baseline); both highlight when active, dim when off, and name their
  action and state in a hover tooltip.
- Settings: same INI file as the original, %APPDATA%\PS_CMTraceViewer.ini,
  with the same defaults (Consolas 12, format JSON on,
  split on comma on, update speed 3, window 1200x700, statistics sorted
  by Count ascending, last log file), so existing settings carry over.
  One default differs: the bottom panel starts at 150 instead of 190
  (see the deep UI fixes section); a height already saved in the INI
  still wins. The operational error log keeps the newest 500 entries.
- One adaptation: the original's UpdateSpeed values (1 to 5) scaled how
  many lines each UI tick drained. Here they select the drain timer
  interval (500, 250, 100, 50, 25 ms), still draining up to 10,000 queued
  entries per tick, with a 50 ms interval during the initial load. The
  visible effect is the same: higher speed, faster catch-up.
- The theme is dark only, styled after the Atrium client (see the
  interaction round below). There is no light variant and no toggle;
  a `Theme` key left in the INI by the earlier toggle build is
  ignored.

## Redesign: the CMTrace feel with a modern finish

The first Windows run worked but looked rough. This round restyles the
main window (and harmonizes the Settings, Open Remote, and Error Log
dialogs) around the layout CMTrace users expect, with current Fluent
styling:

- One menu strip instead of a menu bar plus a toolbar row: the File,
  Edit, and Tools menus sit on the left, the Pause and Auto-Scroll icon
  buttons follow them, and the Find controls are docked on the right.
  The toolbar row was folded into the menu bar per Brandon's direction,
  which returns a row of vertical space to the log. The filter chips
  keep their own row underneath and no longer wrap: the row scrolls
  horizontally if the window is too narrow for all of them.
- The log is a structured grid, as in CMTrace: separate Time, Type,
  Component, and Thread columns ahead of the Log Text column, 24 px
  rows, a styled header, and light horizontal rules. Severity still
  fills the row background from the established palette, and monospace
  is used only for log text; the chrome uses the UI font.
- The details pane shows the selected entry the way CMTrace's details
  do: a field strip (Time, Date, Type with its numeric value,
  Component, Thread) above the message body, instead of one
  undifferentiated text block under a large empty header.
- The statistics panel is a clean list: a small color swatch per level,
  aligned count and percent columns, row separators, and the total
  pinned to a footer band.
- Spacing follows one rhythm throughout (8 px steps, 10 px cell
  padding, consistent band backgrounds and hairline borders), and the
  dialogs use the same margins, section headers, and accent button.

Selection follows CMTrace: a selected row is a solid dark highlight
(deep blue) with white text for every cell, whatever the severity, so
contrast never collapses. The severity signal survives selection as a
saturated color stripe in the row's left border, in the same hue as the
row's severity text.

## Defects fixed after the first Windows run

- **Opening a log showed an empty grid.** The statistics panel and the
  status bar were fully populated while the grid rendered nothing: the
  DataGrid had no control template. Referencing the
  Avalonia.Controls.DataGrid package does not merge its theme by
  itself, and App.axaml loaded only the FluentTheme, so the grid had no
  header presenter and no rows presenter at all. Fix: App.axaml now
  includes `avares://Avalonia.Controls.DataGrid/Themes/Fluent.xaml`
  explicitly, with a comment saying why it must stay. The settings
  window's keyword grid had the same defect and is fixed by the same
  line. A headless regression test (tests/ViewTests) now opens real
  files through the window's own open path and asserts that rows are
  actually realised, so this cannot regress silently.
- **Garbled characters in the statistics header** ("Count" followed by
  mojibake). The sort direction markers were unicode triangle glyphs
  (U+25B2 and U+25BC), the only non-ASCII characters in any UI string.
  They are now ASCII (`^` and `v`), and a view test audits every visible
  string in the main window and the remote dialog for non-ASCII text.
- **Pause and Auto-Scroll are icon-only buttons** now, with hover
  tooltips ("Pause auto-refresh" / "Resume auto-refresh",
  "Auto-scroll: on" / "Auto-scroll: off"), as described in the UI
  bullet above.
- **No WebView anywhere.** PSTrace uses no WebView, browser control, or
  embedded browser of any kind, in code, packages, or UI: every surface
  is native Avalonia controls. (The string does not occur in the
  project at all.)
- **Auto-scroll did not stay pinned.** While tailing a growing file
  with auto-scroll on, the viewport stayed parked on older rows: the
  scroll ran before the new rows had been laid out, and ScrollIntoView
  alone can stop short under virtualization. Auto-scroll now posts the
  scroll at a post-layout dispatcher priority, scrolls the last item
  into view and drives the grid's vertical scroll bar to its maximum,
  then repeats the pass once the tail rows have laid out. Turning
  auto-scroll on also pins immediately, and with auto-scroll on, new
  data returns the view to the bottom even after the user scrolled up,
  which is CMTrace's behavior. Headless view tests cover the pin on
  load, no movement with the toggle off, and the re-pin after a manual
  scroll up followed by appends.
- **Selected rows were unreadable.** A selected entry kept its
  severity-colored text (for example orange Warn) on the default
  translucent blue selection wash, and the contrast collapsed. The
  selection is now a solid dark highlight with white text for all cells
  (see the redesign section), with the severity kept as a left border
  stripe; hover and selection no longer fight because the selected
  state fully overrides the hover wash. View tests assert the selected
  row's highlight color and opacity, the white cell text, the stripe,
  and the restored severity colors after deselection.

## Deep UI fixes: bracket logs and rendering polish

The redesign's first Windows run used a bracket-format log (the
appx_downloader log: every line prefixed with `[date time] [Level]`)
and a close look at that screenshot produced this round:

- **Bracket logs get real columns.** The Time column was empty for
  bracket-format files because only CMTrace attributes filled it, and
  the Log Text column repeated the whole raw line, prefix included.
  The parser now recognises the leading timestamp token (see the
  parsing bullet above): Date and Time are filled, and the Log Text
  column shows only the message. The details pane shows the parsed
  fields and keeps the full raw line as its body.
- **Cell text is left-aligned at the header inset.** Every cell's
  text started 22 px into the cell while headers start at 10 px, so
  short values in the Type column read as centred. The extra 12 px
  was the margin on the TextBlock the DataGrid generates for a text
  column, stacked on top of the cell padding; App.axaml now zeroes
  that generated margin, leaving the cell padding as the single
  inset for cells and headers alike.
- **Selection is painted at the row layer.** The dark highlight
  previously depended on the theme's selection rectangle alone. The
  selected row now gets the solid dark background and white text as
  local values in code (the row template's border paints the row's
  Background, so that is the layer that renders), with the matching
  `:selected` styles in App.axaml and the theme rectangle override
  kept, all in the same colour. The rendered screenshots below show
  the result, not just resource assertions.
- **Dead columns hide.** For files where no entry has a Component or
  Thread value (plain and bracket logs), those columns now hide
  instead of costing roughly 270 px of empty grid; visibility is
  re-evaluated as each batch of entries lands, and CMTrace logs keep
  all five columns.
- **The details pane opens populated.** When a file finishes loading
  with auto-scroll on, the newest entry is selected, matching where
  the view is pinned, instead of the pane showing its dash
  placeholders over an empty body. The pane's default height also
  drops from 190 to 150 (a height saved in the INI still wins), so
  the empty state before any file opens takes less room.
- **Statistics swatches and spacing.** The Info swatch was a white
  square with an outline, reading as an empty checkbox next to the
  filled swatches; white-level levels now get a neutral grey filled
  swatch. The panel is narrower (200 px) with tighter count and
  percent columns, so the numbers sit closer to their labels.
- **Filter chips show their state.** Included and excluded chips
  were indistinguishable: the Fluent theme paints every checked
  ToggleButton's presenter with the accent colour whatever the
  control's Background says, so all included chips rendered the same
  blue and the per-level colours never appeared. A chip style in
  App.axaml hands the presenter back the chip's own Background, and
  the code now styles the two states explicitly: included is the
  level's filled colour with a saturated border, excluded is white
  with muted grey text and a grey outline.

Two rendered screenshots from this round, produced by the same
headless Skia harness as the redesign shot: `preview-bracket.png`
(a bracket-format log in the appx_downloader shape, the final Error
entry auto-selected on load, Component and Thread columns hidden,
details pane populated) and `preview-cmtrace.png` (the CMTrace XML
sample reloaded, a Warn entry selected, all five columns shown).

## Theme and polish: dark default, wider Find, legible colors

The deep UI round's Windows run (tailing DC1's muse-commands.log
remotely) produced four directives, addressed here:

- **Dark mode by default, with a light toggle.** The app requests the
  Fluent dark variant at startup and on every fresh config. A toggle
  labelled Light sits at the far right end of the menu strip; checking
  it switches the whole window (chrome, grid, dialogs) to the light
  variant live, and the choice persists in the INI (`Theme=` key), so
  only the factory default is dark, not every launch for a user who
  picked light. All window chrome colors (menu strip, filter band,
  details pane, statistics panel, status bar, grid header) resolve
  through theme dictionaries, so both variants are fully styled rather
  than one being the dark theme's leftovers.
- **The Find box is flexible and roughly double.** It was a fixed
  200 px at the strip's right edge. The strip is now a grid: menus and
  transport buttons keep their natural widths, the Find box takes the
  flexible middle (minimum 150 px, maximum 440 px), and Find Next,
  Clear, and the theme toggle keep fixed slots at the right. At the
  720 px minimum window width the box still gets about 170 px with
  every control visible; at normal widths it renders at 440 px.
- **Strip button labels are centred.** Find Next, Clear, and the
  theme toggle set horizontal and vertical content alignment to
  Center (also enforced by a shared strip-action style), the
  code-built All filter button matches, and the dialog buttons (Open,
  OK, Cancel, Close) were audited and centred the same way.
- **Severity colors redesigned for both themes.** The old maps were
  pastels built for light chrome: pale tints whose labels measured
  around 2:1 contrast, and unusable as a dark theme's palette. Each
  level now has a fill and text pair per theme, every pair verified
  at 4.5:1 or better, with the hue families unchanged (red for Error,
  Exception, Critical, Failed; orange for Warn, plus a yellow map
  entry; green for Success; blue for Verbose; neutral for Info).
  Light theme: deep saturated text on light tints (red #A31212 on
  #F6CFCF, orange #9A4E00 on #FBE3B8, green #14591D on #C9E7CB, blue
  #0B4F9E on #C9E2F7, slate #37474F on white). Dark theme: pale text
  on deep saturated fills (red #FFC9C9 on #7A1F1F, orange #FFD9A3 on
  #7A4A12, green #BEE9C2 on #1E5426, blue #C2DFF7 on #17456E, light
  grey #E8E8E8 on #2F2F33). The selection stripe uses a saturated
  per-theme color (dark Warn stripe #FFA726, light #EF6C00), the
  selection fill stays the deep #14477A with white text in both
  themes, excluded chips use a muted but legible grey pair per theme,
  and the Info statistics swatch stays a filled neutral grey in both
  themes.
- **The invisible chip label had a second cause.** Beyond the pastel
  palette, the Fluent theme forces a chip's template presenter
  Foreground to white in both states, whatever the chip's own
  Foreground is set to (the same override family as the presenter
  Background fixed in the deep UI round). White on the dark fills
  read fine; white on the light tints was the effectively invisible
  label. App.axaml now hands the presenter back the chip's own
  Foreground at the same selector specificity, in both states, and
  view tests assert the presenter colors directly.

Three rendered screenshots from this round: `preview-dark-bracket.png`
and `preview-dark-cmtrace.png` (the two sample logs in the dark
default, a row selected in each) and `preview-light-bracket.png`
(the bracket log in the light variant, toggle checked, for the light
palette).

## Interaction and Atrium theme: statistics filtering, live search

Brandon's review of the dark build produced this round:

- **Statistics rows are click targets.** Clicking a log type in the
  right-hand statistics panel filters the grid to show only that
  type: the filter chips are driven to the same state in the same
  action, the active statistics row is highlighted with an accent
  edge, and any later chip change re-derives the highlight from the
  filter state, so the two controls never disagree. A Clear filter
  button under the statistics (the chips' All button does the same)
  restores every type.
- **Dark only, themed like the Atrium client.** The Light toggle and
  the light theme are gone, and the persisted `Theme` INI key is
  dropped (a stale value is ignored, never an error). The chrome
  brushes are the Atrium client's tokens, taken from
  `src/Client/wwwroot/css/app.css` in the Atrium source: center
  background #18222E for the main surface, sidebar background
  #1B2A3A for the menu strip and chrome, the right-hand panel
  #1E2938 for the secondary bands, the login card #21303F for
  raised panels, the line color rgba(255,255,255,0.08) composited
  for borders, body text rgba(255,255,255,0.92) and the dim text
  rgba(255,255,255,0.56) composited, and the accent #1C58D9, which
  is also now the selection color (white on it measures 6.1:1).
  The severity palette is unchanged: its fill and text pairs are
  self-contained and still measure at least 4.5:1 (re-verified
  numerically against the new surfaces, along with the chrome
  text and muted pairs, the lowest of which is the search
  watermark pair at 4.6:1).
- **Scrollbars never hide.** Every ScrollBar has auto-hide off, and
  the scroll viewers the window owns (chip strip, statistics,
  details pane) are set to always-visible, so the grid, details,
  statistics, and chip strip bars stay on screen.
- **Live search.** Typing in the search box searches as the user
  types (200 ms debounce): the match count appears next to the box
  and the first match at or after the current row is selected
  immediately. The Next button (or Enter) jumps to the following
  match, wrapping around. New lines arriving while a search is
  active refresh the count.
- **Pause icon centered.** Both transport glyphs are redrawn on a
  16x16 field centered on (8,8): the pause bars span x 3 to 13
  symmetrically, and the play triangle's centroid sits at the
  optical center; each path is explicitly centered in its button,
  and view tests measure the realized glyph center against the
  button center.
- **Search field, Atrium style.** The Find label is gone. The box
  carries the word Search as an in-box watermark in muted grey
  (the Atrium `.mm-search-input` placeholder color), on the Atrium
  search field's translucent fill and border with 6 px corners.
  User-visible Find wording became Search (Edit menu, Ctrl+F
  unchanged), and Find Next became Next.

Screenshots from this round: `preview-dark-bracket.png` (bracket
log, Info exclusive filter applied from the statistics panel,
"metadata" typed with 57 matches counted and the first match
selected), `preview-search-placeholder.png` (the same log with the
search box empty, showing the grey Search watermark), and
`preview-dark-cmtrace.png` (CMTrace log, Warn row selected). The
light preview was deleted with the light theme.

## Verification status

Verified in this Linux VM (`tests/run-tests.sh`, 181 checks, all
passing):

- `dotnet build` and the full self-contained publish succeed clean with
  the pinned packages; the artifact is a PE32+ x86-64 Windows GUI exe.
- Parser: 37 of 37 checks: CMTrace parsing, timestamp slicing, the
  structured time, date, component, and thread fields, keyword
  precedence over numeric type, longest keyword wins, case-insensitive
  keywords, type fallback, plain lines, the missing-attribute drop
  rule, the short-time placeholder, the overlong-line cap, statistics,
  filtering, and wrapping find. One check uses the exact line shape of
  DC1's muse-commands.log. The bracket-format checks cover date and
  time extraction, fractional seconds, the missing-level-token shape,
  message-only display text with the raw line preserved, level
  decisions from the token and from message keywords, invalid
  timestamps staying plain, and the display text of the CMTrace and
  plain shapes.
- Tailer: 13 of 13 checks against live files: initial load, appends, an
  entry split across two writes being reassembled, multi-line entry
  assembly, truncation reset, and the cannot-reach error appearing for
  a missing file and clearing once the file shows up.
- Remote path composition: 12 of 12 checks (admin shares, named shares,
  full-UNC passthrough, trimming, empty-input rejection).
- Headless view tests: 119 of 119 checks against the real window: plain
  and CMTrace files render realised rows with the right cell text in
  the Time, Type, Component, Thread, and Log Text columns; a bracket
  file renders its timestamps in the Time column and message-only text
  in the Log Text column, and populates the details pane fields from
  the bracket token; the Component and Thread columns hide for plain
  and bracket files and stay for CMTrace files; loading with
  auto-scroll on selects the newest entry and populates the details
  pane; selecting an entry populates the details pane fields; the
  selected row carries the solid dark highlight at the theme
  rectangle, at the row template's border, and in the row's own
  background, with white cell text and the severity stripe, and
  deselecting restores the severity colors; filter chips paint their
  level colour when included and the muted surface pair when
  excluded, at the template presenter that actually renders them;
  the white-level statistics swatch is a filled grey and coloured
  swatches keep their level colour; auto-scroll pins to the
  bottom on load, does not move with the toggle off, and re-pins after
  a manual scroll up once new lines arrive; filtering swaps the view
  and still renders; an unreachable UNC path surfaces the cannot-reach
  error in the status bar; the icon buttons swap icons and tooltips as
  designed; every visible string is ASCII. Two test-only adaptations,
  both in the trigger rather than the code path: the drain and
  statistics refreshes are invoked directly because DispatcherTimer
  ticks are not delivered by dispatcher pumping under the headless
  platform (on Windows they fire on the message loop, as the first
  run's populated statistics proved). The theme round added the
  dark default and palette contrast assertions (the palette checks
  now cover the single dark palette, and the chip presenter checks
  pin the white-presenter fix). This round adds: a stale `Theme=Light`
  INI value loads without error and the window still opens dark,
  with no theme toggle anywhere in the window; the chrome brushes
  assert the exact Atrium token values; clicking the Error
  statistics row filters the grid to only the Error rows, drives
  the chips to match, and highlights the row with the accent edge,
  and the Clear filter button restores every type and every chip;
  the chip strip, statistics, and details scroll viewers assert
  always-visible bars, and the grid's scroll bars assert auto-hide
  off; live search selects the match and counts 1 match, then 294
  matches, then clears, all without touching the Next button; the
  search box watermark asserts the text Search and no Find label
  remains on the strip; and the pause, play, and auto-scroll glyph
  centers measure within 1.5 px of their button centers. Two more
  trigger adaptations in the new tests, same pattern as the drain:
  the statistics row click is delivered as a routed pointer event
  on the row (the headless window-level mouse simulation does not
  hit-test into the statistics ScrollViewer), and the live search
  debounce tick is invoked directly.
- Rendered screenshots of the window (real Skia rasterisation through
  the headless platform) are saved next to this README:
  `preview-redesign.png` from the redesign round, `preview-bracket.png`
  and `preview-cmtrace.png` from the deep UI round, the theme round's
  dark previews, and this round's `preview-dark-bracket.png`,
  `preview-dark-cmtrace.png`, and `preview-search-placeholder.png`,
  each reviewed for spacing, alignment, header truncation, and
  selection contrast before this round closed.
- The bootstrap's embedded sources round-trip byte-identically to the
  compiled src project (all 16 files), and a payload extracted from the
  bootstrap exactly as the script writes it builds clean.

Needs a Windows session to confirm:

- This round's work against the real Windows theme: the Atrium
  palette as rendered by Segoe UI (the VM screenshots use fallback
  fonts); clicking a statistics type filtering the grid and the
  Clear filter button restoring it; live search keeping up while
  typing in a large live log; the grey Search watermark in the box;
  scrollbars staying visible in the grid, details, statistics, and
  chip strip; the pause and play glyphs centered at real size; and
  the menu strip at the 720 px minimum width with every control
  visible. (The previous round's toggle and light variant items are
  retired with the light theme.)
- The deep UI round's fixes against the real Windows theme: a bracket-format
  log showing its timestamps in the Time column with message-only Log
  Text and the Component and Thread columns hidden; the dark selection
  with white text when a row is clicked; the filter chips in their
  level colours with an excluded chip gone muted; the newest entry
  selected and the details pane populated right after a load. Also
  still open from the redesign: the merged menu strip at the window's
  minimum width, the CMTrace auto-scroll glyph at real size, and
  auto-scroll staying pinned while a live file grows (tailing the DC1
  muse-commands.log is the natural test). The VM screenshots render
  with fallback fonts; on Windows the window uses Segoe UI and
  Consolas, which are narrower, so the columns have more room than
  the screenshots show.
- Remote UNC open: File, Open Remote against a real second computer
  (an admin share such as C$ is the quickest test), including one
  deliberately wrong computer name to see the cannot-reach status
  message. (The grid rendering fix is confirmed: rows render on
  Windows, as the bracket-log screenshot that prompted this round
  shows.)
- The Explorer context menu, the .log association, and icon drop
  (features A and C) use the standard HKCU verb and `"%1"` command
  registration and still need their first live confirmation.
- The icon-only buttons render from standard Avalonia Path geometry,
  but their look and tooltip behaviour should be eyeballed once.
- The bootstrap script itself was not executed here (it needs Windows
  PowerShell); its payload is the verified project, extracted and built
  as described above, and its flow mirrors the pattern script.
- The published exe has no custom icon. The original's cmtrace.ico was
  not copied into this project, so the exe and its shortcuts show the
  default .NET icon until an icon is wired into the csproj.

## 2026 redesign: quiet severity, CMTrace column order

Brandon's verdict on the previous build, with a side-by-side against
the genuine CMTrace open during the review: the saturated full-row
severity fills and the rainbow chip strip fought the content, the
message column sat fifth behind four metadata columns, the statistics
percentages clipped, and the details strip duplicated grid columns
over dead space. This round redesigns the main window on current
desktop practice while keeping the Atrium chrome tokens and every
existing control name and behavior:

- **Severity is a quiet tint plus a saturated signal.** Row fills are
  now low-saturation tints of each level hue (Info rows are the bare
  surface), row text is the pale same-hue tint (8:1 or better against
  its fill, machine-verified), and the saturated color survives in
  exactly two places: the 3 px left stripe on each row and the Type
  column text, so hue is never the sole signal. The statistics dots
  use the stripe colors, so the rail and the grid agree.
- **The grid follows CMTrace order.** Log Text first and dominant,
  then Type, Component, Time, Thread. The Thread column is wide
  enough that its header never clips against the scrollbar.
- **One command bar.** Menu, an accent Open button, the pause and
  auto-scroll transport toggles (active state is a tinted fill with an
  accent border, readable at a glance), then the search cluster: an
  inset well with a magnifier glyph, a borderless box, and the match
  count inside the well, followed by ghost Prev, Next, and Clear
  buttons grouped with the box they act on. Search Previous is new
  (button and Edit menu), symmetric to Next.
- **Filter chips are pills.** Fully rounded, tint fill with pale text
  and a stripe-colored border when included; a quiet band with muted
  but legible text when excluded, so excluded no longer reads as
  disabled.
- **Details are inline.** The field strip is one row of label:value
  pairs, the Copy button is a ghost button, and the message body sits
  in an inset well instead of a second bordered rectangle.
- **Statistics percentages cannot clip.** The rail's count and
  percent columns carry fixed widths sized for 100.0%.

The view tests were updated to pin the new palette, geometry, and
column order; the invariants they protect (contrast at 4.5:1 or
better, legible chip labels in both states, the stripe surviving
selection, glyph centering) are unchanged. 181 of 181 checks pass.
Fresh renders: `preview-dark-cmtrace.png`,
`preview-dark-bracket.png`, and `preview-search-placeholder.png`; the
three-way comparison against the genuine CMTrace and the previous
build is `refs/side-by-side-after.png`.

## Fix round (Nov 22, 2026, late evening)

Directed by Brandon from a screenshot of the running build:

- **Filter chips wrap.** The chip strip has no horizontal scrollbar;
  chips flow onto a second row instead of scrolling.
- **DPI aware.** Per-monitor DPI awareness V2 is set at process start
  before any window exists.
- **Dialogs follow the theme.** Settings, the error log, and the
  remote open dialog are explicitly dark, with themed controls.
- **UI scaling.** A Settings slider (75% to 150%) scales every window
  through a layout transform; stored as UiScale in the INI.
- **Statistics rows click anywhere.** The whole row is hit-testable,
  not just the type text.
- **Search covers the whole file and every field.** Matching runs
  against the display text, raw message, component, thread, level,
  and time. New text starts at the first match; Next and Previous
  wrap around at both ends.
- **Prev, Next, and Clear live inside the search well.**
- **Columns rearrange by dragging their headers.**
- **Dimmer text, user-selectable.** The neutral text default drops
  from #FFE8E8E8 to #FFCCD0D6, and Settings gains a text color picker
  (White, Dim White, Grey, Blue Grey, Soft Green, Sand) that paints
  the neutral rows and the details body. Severity rows keep their
  per-level tints.
- **Statistics scrollbar.** The statistics panel keeps an
  always-visible vertical scrollbar.

197 of 197 checks pass across all suites, including new checks for
wrap-around search, the settings theme and scale seeding, the text
color, and the rendered statistics scrollbar. Fresh renders:
`preview-fix-main.png` and `preview-fix-settings.png`. Exe SHA-256:
1ee38e77e425a5ed33cde61144468e2ce97362741e79c834349a9ac3f5ed218e.

## Fix round 2 (Nov 22, 2026, later evening)

From Brandon's screenshots of the running build on a real log:

- **Details body is themed, not black.** The details well now uses
  the panel brush instead of the near-black inset, and a check pins
  the details font size to the configured log font size.
- **Default column order is Time, Type, Log Text**, then Component
  and Thread. Headers can still be dragged to rearrange.
- **Settings dialog is bigger and scale-safe.** 680x720 at 100%,
  and the window resizes in proportion to the UI scale so content
  is never compressed into overlap or pushed off the bottom at
  150%. Every row is fixed-height, so resizing the dialog cannot
  feed back into a bigger desired size. The font size box is wide
  enough to show its value. Dialog text is normalized to 12.
- **Settings preview live.** The font family, font size, text
  color, and UI scale apply to the main window as they are
  adjusted. OK keeps them; Cancel reverts to the saved config.
- **Keyword colour cells never render blank.** The colour list is
  bound statically, so it is populated before any row binding
  evaluates, and stored colour names from older builds are
  normalized to a palette name instead of showing an empty cell.
- **More text colours, with a preview.** Twelve presets (the
  original six plus Sky Blue, Pale Cyan, Mint, Peach, Lavender,
  Pink) and a sample log line beside the picker painted in the
  picked colour on the log surface.
- **Statistics scrollbar has its own lane.** Rows, the sort
  header, and the totals row all reserve the scroll bar's width,
  so the % column is never under the bar at any scale.
- **Copy-all button.** A toolbar icon button copies every loaded
  log line to the clipboard, filter or no filter, and the status
  bar reports the count.
- **Enter cycles search matches.** Every Enter press in the search
  box moves to the next match, wrapping at the end; Shift+Enter
  moves to the previous match. The main Enter key (Return) and the
  keypad Enter both work: only the keypad value was checked
  before, which left the main key dead.
- **Menu themed, Edit and Error Log removed.** The menu bar and
  its dropdowns wear the chrome palette. The Edit menu is gone
  (search lives in the search well and on Ctrl+F), and the Tools
  menu no longer carries the PSTrace error log item.

222 of 222 checks pass across all suites, including new checks for
the column order, the details well colour and font size, the menu
contents, the statistics lane, Enter cycling through real key
presses, the copy-all text, the keyword colour cells, and the
live preview events. Fresh renders: `preview-fix-main.png`,
`preview-fix-settings.png`, and `preview-fix-settings150.png` (the
settings dialog at 150%: fully readable, nothing cut off). Exe
SHA-256: 1d44a0827c916e1f9ad7dd9ebf488f72a264203a77e4d672ea598c2380e1dcfb.
