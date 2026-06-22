# Ensure we are running in an environment that supports WPF
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Warning "This script requires PowerShell 5.1 or later."
    return
}

# ---------------------------------------------------------------------------
# Require 64-bit PowerShell to guarantee atomic reads/writes of 64-bit values
# (specifically LastFileLength in SharedState). On a 32-bit host, reads of a
# [long] are not guaranteed to be atomic and could produce a torn value that
# causes a nonsensical seek position in the background tailing thread.
# ---------------------------------------------------------------------------
if (-not [System.Environment]::Is64BitProcess) {
    Write-Warning "This script requires a 64-bit PowerShell host."
    return
}

# Load WPF Assemblies — System.Drawing is intentionally excluded; WPF font
# enumeration uses System.Windows.Media.Fonts instead.
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, Microsoft.VisualBasic

# ---------------------------------------------------------------------------
# Define C# classes for performance, low memory overhead, bulk UI updates,
# and native CMTrace log parsing.
# ---------------------------------------------------------------------------
if (-not ("LogParser" -as [type])) {
    Add-Type @"
    using System;
    using System.Collections.Generic;
    using System.Collections.ObjectModel;
    using System.Collections.Specialized;
    using System.ComponentModel;

    // -----------------------------------------------------------------------
    // Named level constants — single source of truth so PowerShell callers
    // and C# helpers cannot diverge from each other over time.
    // NOTE: These represent the CMTrace type-based levels only.
    //       Keyword-matched entries carry the keyword text as their Level
    //       (e.g. "Fatal", "Critical") rather than one of these constants,
    //       because keywords are user-defined and map many-to-one onto
    //       display colours rather than onto a fixed taxonomy.
    // -----------------------------------------------------------------------
    public static class LogLevels {
        public const string Error   = "Error";
        public const string Warning = "Warn";
        public const string Info    = "Info";
        public const string Verbose = "Verbose";
    }

    // Tag string used to identify the "All" filter checkbox.
    // Defined here so PowerShell and C# share a single literal.
    public static class FilterTags {
        public const string All = "__ALL__";
    }

    public class KeywordItem {
        public string Key   { get; set; }
        public string Value { get; set; }
    }

    public class LogEntry {
        public string Message { get; set; }
        public string RawMsg  { get; set; }
        public string Level   { get; set; }
        public string TypeVal { get; set; }
    }

    // -----------------------------------------------------------------------
    // ObservableRangeCollection<T>
    //
    // Always fires Reset so callers get one notification regardless of batch
    // size. DataGrid with UI virtualisation handles Reset efficiently.
    //
    // Both AddRange and ReplaceAll guard against a null argument so callers
    // do not need to perform their own null check before calling.
    // -----------------------------------------------------------------------
    public class ObservableRangeCollection<T> : ObservableCollection<T> {

        public void AddRange(IEnumerable<T> collection) {
            if (collection == null) return;
            CheckReentrancy();
            var list = new List<T>(collection);
            if (list.Count == 0) return;
            foreach (var item in list) { Items.Add(item); }
            OnPropertyChanged(new PropertyChangedEventArgs("Count"));
            OnPropertyChanged(new PropertyChangedEventArgs("Item[]"));
            OnCollectionChanged(new NotifyCollectionChangedEventArgs(
                NotifyCollectionChangedAction.Reset));
        }

        // ReplaceAll clears the existing items and replaces them with the
        // supplied collection in a single Reset notification.  Passing null
        // is equivalent to passing an empty collection — the list is cleared.
        public void ReplaceAll(IEnumerable<T> collection) {
            CheckReentrancy();
            Items.Clear();
            if (collection != null) {
                foreach (var item in collection) { Items.Add(item); }
            }
            OnPropertyChanged(new PropertyChangedEventArgs("Count"));
            OnPropertyChanged(new PropertyChangedEventArgs("Item[]"));
            OnCollectionChanged(new NotifyCollectionChangedEventArgs(
                NotifyCollectionChangedAction.Reset));
        }
    }

    public static class LogParser {

        // -------------------------------------------------------------------
        // Hard limit on the length of a single line fed to the parser.
        // A malformed or malicious log file could otherwise contain a line of
        // arbitrary length that would cause Substring to allocate a
        // multi-gigabyte string and crash the process with OutOfMemoryException.
        // 1 MB is generous for any real CMTrace entry.
        // NOTE: digit separators (1_048_576) require C# 7 and are not
        // supported by the CodeDOM compiler used by Add-Type in PowerShell 5.1.
        // The literal is written without a separator for compatibility.
        // -------------------------------------------------------------------
        private const int MaxLineLength = 1048576;

        // -------------------------------------------------------------------
        // DetermineLevel — private implementation shared by ParseLine and
        // ReEvaluateLevel so the two public entry points cannot diverge.
        //
        // KEYWORD PRIORITY NOTE:
        // Keywords are matched in the order supplied by the caller.  Because
        // Dictionary<TKey,TValue> iteration order is unspecified in .NET, the
        // caller is responsible for passing keywords in a deterministic order
        // (e.g. sorted by key length descending so longer/more-specific keys
        // win over shorter ones).  PowerShell callers must build the dictionary
        // from a sorted sequence — see BuildSortedKeywords().
        //
        // The method returns the matched keyword key (e.g. "Fatal") rather
        // than a normalised LogLevels constant.  This is intentional: the
        // filter bar and row-style triggers are keyed on the exact keyword
        // text so that each keyword can have its own distinct colour.
        // -------------------------------------------------------------------
        private static string DetermineLevel(string rawMsg, string typeVal,
                                             List<KeyValuePair<string,string>> orderedKeywords) {
            // Keyword match takes priority over CMTrace type field.
            foreach (var kw in orderedKeywords) {
                if (rawMsg.IndexOf(kw.Key, StringComparison.OrdinalIgnoreCase) >= 0) {
                    return kw.Key;
                }
            }
            // CMTrace type: 1 = Informational, 2 = Warning, 3 = Error
            if      (typeVal == "3") return LogLevels.Error;
            else if (typeVal == "2") return LogLevels.Warning;
            else if (typeVal == "1") return LogLevels.Info;
            return LogLevels.Info;
        }

        // -------------------------------------------------------------------
        // BuildSortedKeywords — converts a Dictionary into a List of pairs
        // ordered by key length descending so that longer (more specific)
        // keyword matches take precedence over shorter ones in DetermineLevel.
        // This eliminates the non-deterministic matching that arises from
        // iterating a Dictionary whose internal order is hash-dependent.
        // -------------------------------------------------------------------
        public static List<KeyValuePair<string,string>> BuildSortedKeywords(
                Dictionary<string,string> keywords) {
            var list = new List<KeyValuePair<string,string>>(keywords);
            list.Sort((a, b) => b.Key.Length.CompareTo(a.Key.Length));
            return list;
        }

        // -------------------------------------------------------------------
        // Re-evaluate only the level of an already-parsed entry using its
        // stored TypeVal.  Called after keyword configuration changes so the
        // full file does not need to be re-read from disk.
        // Uses a pre-sorted keyword list for deterministic matching.
        // -------------------------------------------------------------------
        public static string ReEvaluateLevel(string rawMsg, string typeVal,
                                             List<KeyValuePair<string,string>> orderedKeywords) {
            return DetermineLevel(rawMsg, typeVal, orderedKeywords);
        }

        // -------------------------------------------------------------------
        // ReEvaluateAll — re-evaluates the Level field of every entry in the
        // supplied list using the new keyword set.  Implemented in C# so the
        // loop runs at native speed rather than in the PowerShell interpreter,
        // keeping the UI thread responsive even with 100 000+ entries.
        // -------------------------------------------------------------------
        public static void ReEvaluateAll(List<LogEntry> entries,
                                         List<KeyValuePair<string,string>> orderedKeywords) {
            for (int i = 0; i < entries.Count; i++) {
                entries[i].Level = DetermineLevel(
                    entries[i].RawMsg, entries[i].TypeVal, orderedKeywords);
            }
        }

        // -------------------------------------------------------------------
        // FilterEntries — returns a new list containing only the entries
        // whose Level is present and true in the activeFilter map.
        // Running the loop in C# avoids per-iteration PowerShell overhead
        // and avoids allocating a List sized to the full master count when
        // only a small fraction of entries pass the filter.
        // -------------------------------------------------------------------
        public static List<LogEntry> FilterEntries(
                List<LogEntry> entries,
                Dictionary<string,bool> activeFilter) {
            var result = new List<LogEntry>();
            foreach (var e in entries) {
                bool visible;
                if (!activeFilter.TryGetValue(e.Level, out visible)) {
                    visible = true;   // Unknown level = visible by default.
                }
                if (visible) { result.Add(e); }
            }
            return result;
        }

        // -------------------------------------------------------------------
        // FindNext — returns the index of the next entry (from startIndex,
        // wrapping around) whose Message contains searchText
        // (case-insensitive).  Returns -1 if no match is found.
        // Implemented in C# for O(n) performance without PowerShell overhead.
        // -------------------------------------------------------------------
        public static int FindNext(IList<LogEntry> items, string searchText, int startIndex) {
            if (items == null || items.Count == 0 ||
                string.IsNullOrEmpty(searchText)) return -1;

            int count = items.Count;
            // Search from startIndex to end.
            for (int i = startIndex; i < count; i++) {
                if (items[i] != null &&
                    items[i].Message.IndexOf(searchText,
                        StringComparison.OrdinalIgnoreCase) >= 0)
                    return i;
            }
            // Wrap around: search from 0 to startIndex.
            for (int i = 0; i < startIndex && i < count; i++) {
                if (items[i] != null &&
                    items[i].Message.IndexOf(searchText,
                        StringComparison.OrdinalIgnoreCase) >= 0)
                    return i;
            }
            return -1;
        }

        public static LogEntry ParseLine(string line,
                                         List<KeyValuePair<string,string>> orderedKeywords) {
            // Reject null and oversized lines before any further processing.
            if (line == null || line.Length > MaxLineLength) return null;

            if (line.StartsWith("<![LOG[", StringComparison.Ordinal) &&
                line.Contains("]LOG]!>")) {

                int msgStart = 7;
                int msgEnd   = line.IndexOf("]LOG]!>", msgStart, StringComparison.Ordinal);
                if (msgEnd < 0) return null;

                string rawMsg = line.Substring(msgStart, msgEnd - msgStart);

                int typeStart = line.IndexOf("type=\"", msgEnd, StringComparison.Ordinal);
                if (typeStart < 0) return null;
                typeStart += 6;
                int typeEnd = line.IndexOf("\"", typeStart, StringComparison.Ordinal);
                if (typeEnd < 0) return null;
                string typeVal = line.Substring(typeStart, typeEnd - typeStart);

                int timeStart = line.IndexOf("time=\"", msgEnd, StringComparison.Ordinal);
                if (timeStart < 0) return null;
                timeStart += 6;
                int timeEnd = line.IndexOf("\"", timeStart, StringComparison.Ordinal);
                if (timeEnd < 0) return null;
                string timeStr = line.Substring(timeStart, timeEnd - timeStart);

                int dateStart = line.IndexOf("date=\"", msgEnd, StringComparison.Ordinal);
                if (dateStart < 0) return null;
                dateStart += 6;
                int dateEnd = line.IndexOf("\"", dateStart, StringComparison.Ordinal);
                if (dateEnd < 0) return null;
                string dateStr = line.Substring(dateStart, dateEnd - dateStart);

                int tzIndex      = timeStr.IndexOfAny(new char[] { '+', '-' });
                string cleanTime = (tzIndex > 0) ? timeStr.Substring(0, tzIndex) : timeStr;

                string combinedStr = dateStr + " " + cleanTime;
                DateTime dt;
                bool parsed = DateTime.TryParse(
                    combinedStr,
                    System.Globalization.CultureInfo.InvariantCulture,
                    System.Globalization.DateTimeStyles.None,
                    out dt);
                // If parsing fails leave dt as MinValue so it is clearly wrong
                // rather than silently stamping DateTime.Now.
                if (!parsed) dt = DateTime.MinValue;

                string level = DetermineLevel(rawMsg, typeVal, orderedKeywords);

                string timestamp = (dt == DateTime.MinValue)
                    ? "[??:??:??.???]"
                    : "[" + dt.ToString("HH:mm:ss.fff") + "]";

                return new LogEntry {
                    Message = timestamp + " " + rawMsg,
                    RawMsg  = rawMsg,
                    Level   = level,
                    TypeVal = typeVal
                };
            } else {
                string level = DetermineLevel(line, "0", orderedKeywords);
                return new LogEntry {
                    Message = line,
                    RawMsg  = line,
                    Level   = level,
                    TypeVal = "0"
                };
            }
        }
    }
"@
}

# ---------------------------------------------------------------------------
# Named constants — no magic numbers scattered through the code.
# ---------------------------------------------------------------------------
 $script:MaxDrainPerTick     = 25000
 $script:PollIntervalMs      = 500
 $script:InitialCapacity     = 50000
 $script:FastTimerIntervalMs = 100
 $script:MaxRetainedEntries  = 100000
# Trim is only triggered at 110 % of the retained ceiling to avoid trimming
# on every tick when the list hovers near the limit (hysteresis).
 $script:TrimThreshold       = [int]($script:MaxRetainedEntries * 1.1)
 $script:MinFontSize         = 6
 $script:MaxFontSize         = 72
 $script:MinUpdateSpeed      = 1
 $script:MaxUpdateSpeed      = 60
 $script:MinWindowWidth      = 400
 $script:MaxWindowWidth      = 7680
 $script:MinWindowHeight     = 300
 $script:MaxWindowHeight     = 4320

# ---------------------------------------------------------------------------
# Title suffix constants — single source of truth to prevent divergence
# between the code that appends and the code that strips the suffix.
# ---------------------------------------------------------------------------
 $script:SearchPausedSuffix = " [Searching — tailing paused]"

# Maximum number of keyword entries accepted from the INI or the settings
# dialog.  Prevents excessive DataTrigger generation that degrades WPF
# row-style performance.
 $script:MaxKeywordCount = 100

# ---------------------------------------------------------------------------
# Script-level operational error log.
# Replaces silent Write-Debug so faults are visible without requiring changes
# to $DebugPreference.  Bounded at 500 entries to prevent memory growth in
# long-running sessions.
# Uses a List<string> so RemoveRange can trim in O(excess) rather than
# O(n * excess) that repeated RemoveAt(0) would incur.
# ---------------------------------------------------------------------------
 $script:ErrorLog = New-Object System.Collections.Generic.List[string]

function Write-OperationalError {
    param([string]$Context, [string]$Message)
    $entry = "[$(Get-Date -Format 'HH:mm:ss')] $Context : $Message"
    $script:ErrorLog.Add($entry)
    $excess = $script:ErrorLog.Count - 500
    if ($excess -gt 0) {
        $script:ErrorLog.RemoveRange(0, $excess)
    }
}

# ---------------------------------------------------------------------------
# Helper: safe XML-escape for XAML string interpolation.
# Used whenever a config value is embedded in a XAML here-string to prevent
# malformed markup.
# Note: SecurityElement.Escape handles < > & " ' but does NOT escape XAML
# markup-extension braces { }.  Numeric and font-name values used in the
# main XAML template are unlikely to contain braces; this function is
# defence-in-depth for the cases it does cover.
# ---------------------------------------------------------------------------
function ConvertTo-XmlSafe {
    param([string]$Text)
    return [System.Security.SecurityElement]::Escape($Text)
}

# ---------------------------------------------------------------------------
# Helper: iterative visual-tree walk to find a ScrollViewer.
# Iterative rather than recursive to avoid stack overflow on deep WPF trees.
# Only Visual-derived nodes are enqueued; ContentElement objects would cause
# VisualTreeHelper.GetChildrenCount to throw ArgumentException.
# ---------------------------------------------------------------------------
function Find-ScrollViewer {
    param($Root)
    if ($null -eq $Root) { return $null }
    $queue = New-Object System.Collections.Generic.Queue[object]
    $queue.Enqueue($Root)
    while ($queue.Count -gt 0) {
        $node = $queue.Dequeue()
        if ($node -is [System.Windows.Controls.ScrollViewer]) { return $node }
        if ($node -isnot [System.Windows.Media.Visual]) { continue }
        $childCount = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($node)
        for ($i = 0; $i -lt $childCount; $i++) {
            $child = [System.Windows.Media.VisualTreeHelper]::GetChild($node, $i)
            if ($child -is [System.Windows.Media.Visual]) {
                $queue.Enqueue($child)
            }
        }
    }
    return $null
}

function Add-SlowScroll {
    param($UIElement)
    if ($null -eq $UIElement) { return }
    $UIElement.Add_PreviewMouseWheel({
        param($sender, $e)
        $scroller = Find-ScrollViewer $sender
        if ($null -ne $scroller) {
            $scroller.ScrollToVerticalOffset($scroller.VerticalOffset - ($e.Delta / 4))
            $e.Handled = $true
        }
    })
}

# ---------------------------------------------------------------------------
# Helper: centralise timer stop/interval/start so every call site uses the
# same pattern and cannot forget to restart.
# ---------------------------------------------------------------------------
function Set-TimerInterval {
    param([TimeSpan]$Interval)
    $script:RefreshTimer.Stop()
    $script:RefreshTimer.Interval = $Interval
    $script:RefreshTimer.Start()
}

# ---------------------------------------------------------------------------
# Helper: build a sorted keyword list for deterministic level matching.
# Keywords are ordered by key length descending so that longer (more
# specific) keywords take precedence when a message contains multiple
# matching keywords.  This replaces Dictionary iteration whose order is
# hash-dependent and therefore non-deterministic.
# ---------------------------------------------------------------------------
function Get-SortedKeywords {
    $dict = New-Object 'System.Collections.Generic.Dictionary[string,string]'
    foreach ($kv in $script:Config.Keywords.GetEnumerator()) {
        $dict[$kv.Key] = $kv.Value
    }
    return [LogParser]::BuildSortedKeywords($dict)
}

# ---------------------------------------------------------------------------
# Configuration & INI Management
# ---------------------------------------------------------------------------
 $script:ConfigPath = "$env:APPDATA\PS_CMTraceViewer.ini"

 $script:ColorMap = @{
    "Red"    = "#FFFFCDD2"
    "Orange" = "#FFFFE0B2"
    "Yellow" = "#FFFFF9C4"
    "Green"  = "#FFC8E6C9"
    "Blue"   = "#FFE1F5FE"
    "Purple" = "#FFE1BEE7"
    "White"  = "#FFFFFFFF"
}

# ReverseColorMap is kept to handle legacy INI files that may have stored hex
# values instead of colour names.  It is not produced by current Export-Config
# but the import path handles it defensively.
 $script:ReverseColorMap = @{}
foreach ($k in $script:ColorMap.Keys) {
    $script:ReverseColorMap[$script:ColorMap[$k]] = $k
}

# ---------------------------------------------------------------------------
# Get-DefaultConfig — single source of truth for all default setting values.
# Import-Config and its fallback catch blocks both call this so that changing
# a default requires editing only one place.
# ---------------------------------------------------------------------------
function Get-DefaultConfig {
    return @{
        FontFamily        = "Consolas"
        FontSize          = 12
        BottomPanelHeight = 250
        FormatJson        = $true
        SplitComma        = $true
        SplitSpace        = $false
        SplitPeriod       = $false
        CustomDelimiters  = @()
        UpdateSpeed       = 3
        LastLogFile       = ""
        WindowWidth       = 1100
        WindowHeight      = 700
        Keywords          = @{
            "Critical"  = "Red"
            "Error"     = "Red"
            "Exception" = "Red"
            "Failed"    = "Red"
            "Warn"      = "Orange"
            "Success"   = "Green"
            "Verbose"   = "Blue"
            "Info"      = "White"
        }
    }
}

 $script:Config = Get-DefaultConfig

function Import-Config {
    if (-not (Test-Path $script:ConfigPath)) { return }

    $defaults = Get-DefaultConfig

    $section  = ""
    $kw       = @{}
    $delims   = @()
    $settings = @{
        FontFamily        = $defaults.FontFamily
        FontSize          = $defaults.FontSize
        BottomPanelHeight = $defaults.BottomPanelHeight
        FormatJson        = $defaults.FormatJson
        SplitComma        = $defaults.SplitComma
        SplitSpace        = $defaults.SplitSpace
        SplitPeriod       = $defaults.SplitPeriod
        UpdateSpeed       = $defaults.UpdateSpeed
        LastLogFile       = ""
        WindowWidth       = $defaults.WindowWidth
        WindowHeight      = $defaults.WindowHeight
    }

    # Use [System.IO.File]::ReadLines for streaming access rather than
    # Get-Content which loads the entire file into memory at once.
    foreach ($line in [System.IO.File]::ReadLines($script:ConfigPath,
                           [System.Text.Encoding]::UTF8)) {
        $trimLine = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimLine)) { continue }

        if ($trimLine -match '^\[(.+)\]$') {
            $section = $matches[1]
            continue
        }

        # Split on the FIRST '=' only so that values containing '=' are preserved.
        $eqIndex = $trimLine.IndexOf('=')
        if ($eqIndex -lt 0) { continue }
        $key = $trimLine.Substring(0, $eqIndex).Trim()
        if ([string]::IsNullOrWhiteSpace($key)) { continue }
        $val = $trimLine.Substring($eqIndex + 1).Trim()

        if ($section -eq "Settings") {
            if ($settings.ContainsKey($key)) {
                $settings[$key] = $val
            }
            # Unknown keys in [Settings] are silently ignored; no action needed.
        } elseif ($section -eq "Keywords") {
            # Defensively convert legacy hex values to colour names if present.
            if ($script:ReverseColorMap.ContainsKey($val)) {
                $val = $script:ReverseColorMap[$val]
            }

            # Validate that the colour name is one we recognise so invalid
            # entries are caught at import time rather than failing later
            # when Set-GuiFromConfig attempts to create a brush.
            if (-not $script:ColorMap.ContainsKey($val)) {
                Write-OperationalError "Import-Config" `
                    "Unknown colour '$val' for keyword '$key' — defaulting to White."
                $val = "White"
            }

            if (-not [string]::IsNullOrWhiteSpace($key) -and
                $kw.Count -lt $script:MaxKeywordCount) {
                $kw[$key] = $val
            } elseif ($kw.Count -ge $script:MaxKeywordCount) {
                Write-OperationalError "Import-Config" `
                    "Keyword limit ($script:MaxKeywordCount) reached — '$key' ignored."
            }
        } elseif ($section -eq "Delimiters") {
            if (-not [string]::IsNullOrWhiteSpace($val)) {
                $delims += $val
            }
        }
    }

    $script:Config.FontFamily = if ($settings.ContainsKey("FontFamily") -and
        -not [string]::IsNullOrWhiteSpace($settings["FontFamily"])) {
        $settings["FontFamily"]
    } else { $defaults.FontFamily }

    try {
        $script:Config.FontSize = [Math]::Max(
            $script:MinFontSize,
            [Math]::Min($script:MaxFontSize, [int]$settings["FontSize"]))
    } catch { $script:Config.FontSize = $defaults.FontSize }

    try {
        $script:Config.BottomPanelHeight = [Math]::Max(80, [int]$settings["BottomPanelHeight"])
    } catch { $script:Config.BottomPanelHeight = $defaults.BottomPanelHeight }

    # Use string comparison rather than [bool]::Parse so that common
    # representations such as "1"/"0" or "true"/"false" all work correctly.
    # [bool]::Parse only accepts "True" and "False" (case-insensitive in
    # .NET) and throws FormatException for anything else, silently falling
    # back to the default.  The string-comparison approach is explicit and
    # consistent with how INI authors typically write boolean values.
    $script:Config.FormatJson  = ($settings["FormatJson"]  -eq "True")
    $script:Config.SplitComma  = ($settings["SplitComma"]  -eq "True")
    $script:Config.SplitSpace  = ($settings["SplitSpace"]  -eq "True")
    $script:Config.SplitPeriod = ($settings["SplitPeriod"] -eq "True")

    try {
        $script:Config.UpdateSpeed = [Math]::Max(
            $script:MinUpdateSpeed,
            [Math]::Min($script:MaxUpdateSpeed, [int]$settings["UpdateSpeed"]))
    } catch { $script:Config.UpdateSpeed = $defaults.UpdateSpeed }

    $script:Config.LastLogFile = if ($settings.ContainsKey("LastLogFile") -and
        -not [string]::IsNullOrWhiteSpace($settings["LastLogFile"])) {
        $settings["LastLogFile"]
    } else { "" }

    try {
        $script:Config.WindowWidth = [Math]::Max(
            $script:MinWindowWidth,
            [Math]::Min($script:MaxWindowWidth, [int]$settings["WindowWidth"]))
    } catch { $script:Config.WindowWidth = $defaults.WindowWidth }

    try {
        $script:Config.WindowHeight = [Math]::Max(
            $script:MinWindowHeight,
            [Math]::Min($script:MaxWindowHeight, [int]$settings["WindowHeight"]))
    } catch { $script:Config.WindowHeight = $defaults.WindowHeight }

    if ($kw.Count     -gt 0) { $script:Config.Keywords         = $kw }
    if ($delims.Count -gt 0) { $script:Config.CustomDelimiters = $delims }
}

function Export-Config {
    try {
        # Strip newline characters from string values so a crafted font name
        # or file path cannot inject extra INI sections into the saved file.
        # The INI parser splits line-by-line, so removing CR/LF is sufficient
        # to prevent section-injection via these two string fields.
        $safeFontFamily  = ($script:Config.FontFamily  -replace '[\r\n]', '')
        $safeLastLogFile = ($script:Config.LastLogFile -replace '[\r\n]', '')

        $lines  = @()
        $lines += "[Settings]"
        $lines += "FontFamily=$safeFontFamily"
        $lines += "FontSize=$($script:Config.FontSize)"
        $lines += "BottomPanelHeight=$($script:Config.BottomPanelHeight)"
        $lines += "FormatJson=$($script:Config.FormatJson)"
        $lines += "SplitComma=$($script:Config.SplitComma)"
        $lines += "SplitSpace=$($script:Config.SplitSpace)"
        $lines += "SplitPeriod=$($script:Config.SplitPeriod)"
        $lines += "UpdateSpeed=$($script:Config.UpdateSpeed)"
        $lines += "LastLogFile=$safeLastLogFile"
        $lines += "WindowWidth=$($script:Config.WindowWidth)"
        $lines += "WindowHeight=$($script:Config.WindowHeight)"
        $lines += ""
        $lines += "[Keywords]"
        foreach ($kv in $script:Config.Keywords.GetEnumerator()) {
            $safeKey = ($kv.Key   -replace '[\r\n]', '')
            $safeVal = ($kv.Value -replace '[\r\n]', '')
            $lines += "$safeKey=$safeVal"
        }
        $lines += ""
        $lines += "[Delimiters]"
        $i = 1
        foreach ($d in $script:Config.CustomDelimiters) {
            $safeDelim = ($d -replace '[\r\n]', '')
            $lines += "$i=$safeDelim"
            $i++
        }
        $lines | Out-File $script:ConfigPath -Encoding UTF8 -Force
    } catch {
        [System.Windows.MessageBox]::Show(
            "Failed to save settings: $_", "Error", "OK", "Error")
    }
}

Import-Config

# ---------------------------------------------------------------------------
# Background runspace — tails the log file and enqueues LogEntry objects.
#
# DESIGN NOTES
# ------------
# 1. $PollIntervalMs is passed explicitly as a parameter because $script:-
#    scoped variables from the parent session are NOT visible inside a
#    runspace.  ALL dependencies must travel through the parameter list.
#
# 2. [LogParser] IS available because Add-Type loads the assembly into the
#    shared AppDomain for the entire process.
#
# 3. The queue element type is [object] rather than [LogEntry] to avoid
#    type-resolution issues at runspace initialisation time.  The UI thread
#    casts back to [LogEntry] after dequeue.  If the cast returns null the
#    entry is logged and skipped rather than silently discarded.
#
# 4. Cancellation-aware sleeping uses CancellationToken.WaitHandle.WaitOne
#    instead of Start-Sleep so that the thread wakes promptly when the token
#    is cancelled rather than waiting up to PollIntervalMs for the next poll.
#
# 5. Write-Warning inside a background runspace goes nowhere visible because
#    there is no host attached.  Errors are routed through the SharedState
#    hashtable so the UI thread can surface them via Write-OperationalError.
#
# 6. Cross-thread safety: [hashtable]::Synchronized guarantees individual
#    key-access atomicity.  LastFileLength (a [long]) is only ever written
#    by the background thread, so there is no write-write race.  The boolean
#    flags (InitialLoadComplete, IsFlushingInitialQueue) transition in one
#    direction only (false -> true or true -> false), so a torn read — which
#    cannot occur on a 64-bit process — would still produce a safe outcome.
#    The 64-bit process requirement is enforced at script startup.
#
# 7. LastFileLength and PendingBuffer are written back to SharedState on
#    every successful read cycle (not only on cancellation) so that the UI
#    thread always observes the current tail position and a mid-cycle crash
#    does not cause a full re-read from byte zero on the next open.
#    NOTE: SharedState is used for signalling only (InitialLoadComplete,
#    IsFlushingInitialQueue, LastError).  The UI thread does not read
#    LastFileLength or PendingBuffer — those fields exist solely so the
#    background thread can preserve tail state across restarts.
#
# 8. No maximum queue depth is enforced at the runspace level.  If the UI
#    thread is unable to drain entries (e.g. settings dialog is open) the
#    queue will grow.  The MaxDrainPerTick constant on the UI side bounds
#    the per-tick work; users opening very large files should be aware of
#    the memory implications.
# ---------------------------------------------------------------------------
 $bgScript = {
    # IMPORTANT: This scriptblock executes in a separate runspace.
    # It has NO access to $script: variables, functions, or modules from the
    # parent session.  All dependencies must be passed as parameters below.
    param(
        [string]   $FilePath,
        # Ordered keyword list built by LogParser.BuildSortedKeywords so that
        # longer keywords match before shorter ones regardless of hash order.
        [System.Collections.Generic.List[System.Collections.Generic.KeyValuePair[string,string]]] $OrderedKeywords,
        [System.Collections.Concurrent.ConcurrentQueue[object]] $LogQueue,
        [System.Threading.CancellationToken] $CancellationToken,
        [hashtable] $SharedState,
        [int]       $PollIntervalMs
    )

    # Read initial tail position and pending buffer from SharedState.
    # These local copies are updated each cycle and written back to SharedState
    # after every successful read so that the background thread always has a
    # current position in case of restart.
    $lastFileLength = $SharedState["LastFileLength"]
    $pendingBuffer  = $SharedState["PendingBuffer"]
    $buffer         = New-Object System.Text.StringBuilder

    while (-not $CancellationToken.IsCancellationRequested) {
        $stream = $null
        $reader = $null
        try {
            $fileInfo = [System.IO.FileInfo]::new($FilePath)
            $fileInfo.Refresh()

            if (-not $fileInfo.Exists) {
                # File not yet present — wait and try again.
                [void]$CancellationToken.WaitHandle.WaitOne($PollIntervalMs)
                continue
            }

            $currentLength = $fileInfo.Length

            if ($currentLength -lt $lastFileLength) {
                # File was truncated or replaced — restart from the beginning.
                # Clear the StringBuilder so stale partial entries from the
                # previous file version are not prepended to the first entry
                # of the new file.
                $lastFileLength = 0
                $pendingBuffer  = ""
                [void]$buffer.Clear()
            }

            if ($currentLength -gt $lastFileLength) {
                # Open with FileShare.ReadWrite so the log writer is not blocked.
                $stream = [System.IO.File]::Open(
                    $FilePath,
                    [System.IO.FileMode]::Open,
                    [System.IO.FileAccess]::Read,
                    [System.IO.FileShare]::ReadWrite)

                try {
                    # The 3rd parameter ($true) enables BOM detection. The StreamReader
                    # takes ownership of the stream and closes it when disposed. We null
                    # out $stream so the outer finally block does not double-dispose it.
                    $reader = New-Object System.IO.StreamReader(
                        $stream, [System.Text.Encoding]::UTF8, $true)
                    $stream = $null
                } catch {
                    # Dispose the stream here because StreamReader construction
                    # failed so it will not take ownership.  The finally block
                    # will see $stream as $null and skip its dispose path.
                    if ($null -ne $stream) { $stream.Dispose(); $stream = $null }
                    throw
                }

                [void]$reader.BaseStream.Seek($lastFileLength, [System.IO.SeekOrigin]::Begin)
                $lastFileLength = $currentLength

                [void]$buffer.Clear()
                if ($pendingBuffer.Length -gt 0) {
                    [void]$buffer.Append($pendingBuffer)
                    $pendingBuffer = ""
                }

                $line = $null
                while (($line = $reader.ReadLine()) -ne $null) {
                    if ($line.StartsWith('<![LOG[') -and $buffer.Length -gt 0) {
                        # Flush the previously accumulated multi-line CMTrace entry.
                        $entry = [LogParser]::ParseLine($buffer.ToString(), $OrderedKeywords)
                        if ($null -ne $entry) { $LogQueue.Enqueue($entry) }
                        [void]$buffer.Clear().Append($line)
                    } elseif ($line.StartsWith('<![LOG[')) {
                        [void]$buffer.Clear().Append($line)
                    } elseif ($buffer.Length -gt 0) {
                        [void]$buffer.AppendLine($line)
                    } else {
                        # Plain (non-CMTrace) line.
                        $entry = [LogParser]::ParseLine($line, $OrderedKeywords)
                        if ($null -ne $entry) { $LogQueue.Enqueue($entry) }
                    }
                }

                # Handle data remaining in the buffer after all lines are read.
                if ($buffer.Length -gt 0) {
                    $bufferStr = $buffer.ToString()
                    if ($bufferStr.StartsWith('<![LOG[') -and
                        -not $bufferStr.Contains("]LOG]!>")) {
                        # Incomplete CMTrace record — hold for the next poll cycle.
                        $pendingBuffer = $bufferStr
                    } else {
                        $entry = [LogParser]::ParseLine($bufferStr, $OrderedKeywords)
                        if ($null -ne $entry) { $LogQueue.Enqueue($entry) }
                        $pendingBuffer = ""
                    }
                }

                # Write updated tail position and pending buffer back to SharedState
                # on every successful read cycle so the background thread always
                # has a current position and a crash does not force a full re-read.
                $SharedState["LastFileLength"] = $lastFileLength
                $SharedState["PendingBuffer"]  = $pendingBuffer

                # Signal the UI thread that the first full read has completed.
                if (-not $SharedState["InitialLoadComplete"]) {
                    $SharedState["InitialLoadComplete"] = $true
                }
            }
        } catch [System.IO.IOException] {
            # Route the error through SharedState so the UI thread can surface it.
            $SharedState["LastError"] = "IO error at $(Get-Date -Format 'HH:mm:ss') on '$FilePath': $_"
            [void]$CancellationToken.WaitHandle.WaitOne($PollIntervalMs)
            continue
        } catch {
            $SharedState["LastError"] = "Unexpected error at $(Get-Date -Format 'HH:mm:ss'): $_"
            [void]$CancellationToken.WaitHandle.WaitOne($PollIntervalMs)
            continue
        } finally {
            # Dispose in reverse acquisition order.  $stream is null if
            # StreamReader construction succeeded (it takes ownership) or if
            # it was already disposed in the inner catch block.
            if ($null -ne $reader) { $reader.Dispose() }
            if ($null -ne $stream) { $stream.Dispose() }
        }

        # Cancellation-aware sleep: wakes immediately when the token fires
        # instead of blocking for the full PollIntervalMs duration.
        [void]$CancellationToken.WaitHandle.WaitOne($PollIntervalMs)
    }
}

# ---------------------------------------------------------------------------
# Main XAML UI
# All config values embedded in the XAML string are passed through
# ConvertTo-XmlSafe so that unusual font names or dimensions cannot produce
# malformed markup.  Numeric values are already integers after Import-Config
# validation; ConvertTo-XmlSafe on them is defence-in-depth.
# ---------------------------------------------------------------------------
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:sys="clr-namespace:System;assembly=mscorlib"
        Title="Configuration Manager Trace Log Tool"
        Height="$(ConvertTo-XmlSafe $script:Config.WindowHeight)"
        Width="$(ConvertTo-XmlSafe $script:Config.WindowWidth)"
        WindowStartupLocation="CenterScreen">
    <Window.Resources>
        <Style TargetType="DataGridCell">
            <Setter Property="Background"       Value="Transparent"/>
            <Setter Property="BorderBrush"      Value="Transparent"/>
            <Setter Property="FocusVisualStyle"  Value="{x:Null}"/>
            <Setter Property="Foreground"
                    Value="{Binding RelativeSource={RelativeSource AncestorType=DataGridRow},
                                    Path=Foreground}"/>
        </Style>
        <x:Array x:Key="ColorList" Type="sys:String">
            <sys:String>Red</sys:String>
            <sys:String>Orange</sys:String>
            <sys:String>Yellow</sys:String>
            <sys:String>Green</sys:String>
            <sys:String>Blue</sys:String>
            <sys:String>Purple</sys:String>
            <sys:String>White</sys:String>
        </x:Array>
    </Window.Resources>

    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*" MinHeight="100"/>
            <RowDefinition Height="5"/>
            <RowDefinition Height="$(ConvertTo-XmlSafe $script:Config.BottomPanelHeight)"
                           MinHeight="80"/>
        </Grid.RowDefinitions>

        <!-- Menu -->
        <Menu Grid.Row="0" Background="#FFF0F0F0">
            <MenuItem Header="_File">
                <MenuItem Header="_Open..."    Name="OpenMenu"     InputGestureText="Ctrl+O"/>
                <Separator/>
                <MenuItem Header="_Exit"       Name="ExitMenu"/>
            </MenuItem>
            <MenuItem Header="_Edit">
                <MenuItem Header="_Find..."    Name="FindMenu"     InputGestureText="Ctrl+F"/>
            </MenuItem>
            <MenuItem Header="_Tools">
                <MenuItem Header="_Settings..." Name="SettingsMenu"/>
                <Separator/>
                <MenuItem Header="View _Error Log" Name="ErrorLogMenu"/>
            </MenuItem>
        </Menu>

        <!-- Toolbar -->
        <DockPanel Grid.Row="1" Background="#FFF0F0F0" Margin="0,2,0,2">
            <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" Margin="0,0,5,0">
                <TextBlock Text="Find:" VerticalAlignment="Center" Margin="5,0,0,0" FontWeight="Bold"/>
                <TextBox  Name="SearchBox"      Width="250" Margin="5,0,0,0" VerticalAlignment="Center"/>
                <Button   Name="SearchBtn"      Content="Find Next" Width="80" Margin="5,0,0,0"/>
                <Button   Name="ClearSearchBtn" Content="Clear"     Width="50" Margin="5,0,0,0"/>
            </StackPanel>
            <StackPanel Orientation="Horizontal">
                <ToggleButton Name="PauseBtn"  Content="Pause Auto-Refresh" Width="150" Margin="5,0,0,0"/>
                <ToggleButton Name="ScrollBtn" Content="Auto-Scroll: ON"    Width="150" Margin="5,0,0,0" IsChecked="True"/>
            </StackPanel>
        </DockPanel>

        <!-- Filter Bar -->
        <Border Grid.Row="2" Background="#FFE8E8E8"
                BorderBrush="#FFD0D0D0" BorderThickness="0,1,0,1"
                Padding="4,3,4,3">
            <DockPanel>
                <TextBlock Text="Filter:" FontWeight="Bold"
                           VerticalAlignment="Center" Margin="2,0,6,0"
                           DockPanel.Dock="Left"/>
                <WrapPanel Name="FilterPanel" Orientation="Horizontal"
                           VerticalAlignment="Center"/>
            </DockPanel>
        </Border>

        <!-- DataGrid -->
        <DataGrid Grid.Row="3" Name="LogDataGrid"
                  Background="White" Foreground="Black"
                  GridLinesVisibility="Horizontal"
                  HorizontalGridLinesBrush="#FFD0D0D0"
                  HeadersVisibility="Column"
                  AutoGenerateColumns="False"
                  IsReadOnly="True"
                  SelectionMode="Extended"
                  SelectionUnit="FullRow"
                  CanUserAddRows="False"
                  CanUserDeleteRows="False"
                  CanUserResizeRows="False"
                  CanUserReorderColumns="False"
                  BorderThickness="1,0,1,1" BorderBrush="#FFD0D0D0"
                  ScrollViewer.HorizontalScrollBarVisibility="Auto"
                  ScrollViewer.VerticalScrollBarVisibility="Auto"
                  VirtualizingPanel.ScrollUnit="Pixel"
                  VirtualizingPanel.IsVirtualizing="True"
                  VirtualizingPanel.VirtualizationMode="Recycling">
            <DataGrid.Columns>
                <DataGridTextColumn Header="Log Entry" Binding="{Binding Message}" Width="*">
                    <DataGridTextColumn.ElementStyle>
                        <Style TargetType="TextBlock">
                            <Setter Property="TextWrapping" Value="NoWrap"/>
                        </Style>
                    </DataGridTextColumn.ElementStyle>
                </DataGridTextColumn>
            </DataGrid.Columns>
        </DataGrid>

        <!-- Splitter -->
        <GridSplitter Grid.Row="4" Height="5"
                      HorizontalAlignment="Stretch" Background="#FFD0D0D0"
                      ResizeDirection="Rows" ResizeBehavior="PreviousAndNext"/>

        <!-- Detail Panel -->
        <TextBox Grid.Row="5" Name="DetailTextBox"
                 IsReadOnly="True"
                 Background="#FFF8F8F8"
                 BorderThickness="1,0,1,1" BorderBrush="#FFD0D0D0"
                 VerticalScrollBarVisibility="Auto"
                 HorizontalScrollBarVisibility="Auto"
                 TextWrapping="Wrap"
                 Padding="5,5,5,5"/>
    </Grid>
</Window>
"@

 $xmlReader = New-Object System.Xml.XmlNodeReader $xaml
try {
    $Window = [Windows.Markup.XamlReader]::Load($xmlReader)
} finally {
    $xmlReader.Dispose()
}

 $OpenMenu       = $Window.FindName("OpenMenu")
 $ExitMenu       = $Window.FindName("ExitMenu")
 $FindMenu       = $Window.FindName("FindMenu")
 $SettingsMenu   = $Window.FindName("SettingsMenu")
 $ErrorLogMenu   = $Window.FindName("ErrorLogMenu")
 $LogDataGrid    = $Window.FindName("LogDataGrid")
 $DetailTextBox  = $Window.FindName("DetailTextBox")
 $PauseBtn       = $Window.FindName("PauseBtn")
 $ScrollBtn      = $Window.FindName("ScrollBtn")
 $SearchBox      = $Window.FindName("SearchBox")
 $SearchBtn      = $Window.FindName("SearchBtn")
 $ClearSearchBtn = $Window.FindName("ClearSearchBtn")
 $FilterPanel    = $Window.FindName("FilterPanel")

# ---------------------------------------------------------------------------
# Keyboard shortcuts — Ctrl+O and Ctrl+F handled at window level so they
# work regardless of which control currently has focus.
# MenuItem.Command is null for click-event-driven items, so KeyBinding
# objects cannot be constructed from them.  The Window.KeyDown handler
# below is the correct approach for this pattern.
# ---------------------------------------------------------------------------
 $Window.Add_KeyDown({
    param($sender, $e)
    if ($e.Key -eq [System.Windows.Input.Key]::O -and
        $e.KeyboardDevice.Modifiers -eq [System.Windows.Input.ModifierKeys]::Control) {
        $e.Handled = $true
        $OpenMenu.RaiseEvent(
            (New-Object System.Windows.RoutedEventArgs(
                [System.Windows.Controls.MenuItem]::ClickEvent)))
    } elseif ($e.Key -eq [System.Windows.Input.Key]::F -and
              $e.KeyboardDevice.Modifiers -eq [System.Windows.Input.ModifierKeys]::Control) {
        $e.Handled = $true
        $SearchBox.Focus()
    }
})

# ---------------------------------------------------------------------------
# Resolve the bottom RowDefinition by index (row 5, 0-based).
# x:Name on RowDefinition is not part of the documented WPF name-scope
# contract and can fail silently on some host configurations.
# ---------------------------------------------------------------------------
 $rootGrid = $Window.Content
 $BottomRow = $rootGrid.RowDefinitions[5]
if ($null -eq $BottomRow) {
    Write-OperationalError "Init" "Could not resolve BottomRow RowDefinition by index — bottom panel height persistence will be unavailable."
}

Add-SlowScroll $LogDataGrid
Add-SlowScroll $DetailTextBox

# ---------------------------------------------------------------------------
# Global state
# ---------------------------------------------------------------------------
 $script:CurrentLogFile  = $null
 $script:RefreshTimer    = $null
 $script:Cts             = $null
 $script:RunspacePS      = $null
 $script:RunspaceObj     = $null
 $script:AsyncResult     = $null
 $script:LogQueue        = $null
 $script:SharedState     = $null

# Master list holds every parsed entry regardless of active filters.
 $script:MasterList = New-Object System.Collections.Generic.List[LogEntry]($script:InitialCapacity)

# Filtered display collection bound to the DataGrid.
 $script:DisplayCollection = New-Object ObservableRangeCollection[LogEntry]

# ---------------------------------------------------------------------------
# Filter state
# ---------------------------------------------------------------------------
 $script:FilterCheckboxes  = @{}
 $script:ActiveLevelFilter = @{}

# ---------------------------------------------------------------------------
# Debounce timer for filter changes so rapid checkbox clicks do not each
# trigger a full master-list walk.
# ---------------------------------------------------------------------------
 $script:FilterDebounceTimer          = New-Object System.Windows.Threading.DispatcherTimer
 $script:FilterDebounceTimer.Interval = [TimeSpan]::FromMilliseconds(300)
 $script:FilterDebounceTimer.Add_Tick({
    $script:FilterDebounceTimer.Stop()
    Invoke-ApplyFilter
})

# ---------------------------------------------------------------------------
# Rebuild the checkbox strip from the current keyword set.
# ---------------------------------------------------------------------------
function Invoke-RebuildFilterBar {
    $FilterPanel.Children.Clear()
    $script:FilterCheckboxes  = @{}
    $script:ActiveLevelFilter = @{}

    # Collect the union of all keyword keys plus the four well-known CMTrace
    # level names so they always appear even if the user has no keyword for them.
    $levels = New-Object System.Collections.Generic.HashSet[string](
                  [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($k in $script:Config.Keywords.Keys) { [void]$levels.Add($k) }
    foreach ($l in @(
        [LogLevels]::Error,
        [LogLevels]::Warning,
        [LogLevels]::Info,
        [LogLevels]::Verbose
    )) { [void]$levels.Add($l) }

    # Use the FilterTags constant from C# rather than a bare magic string.
    $allTag = [FilterTags]::All

    $allCb            = New-Object System.Windows.Controls.CheckBox
    $allCb.Content    = "All"
    $allCb.IsChecked  = $true
    $allCb.Margin     = "4,0,8,0"
    $allCb.FontWeight = "Bold"
    $allCb.Tag        = $allTag
    $allCb.Add_Click({
        param($s, $e)
        $checked = ($s.IsChecked -eq $true)
        $filterTag = [FilterTags]::All
        foreach ($cb in $script:FilterCheckboxes.Values) {
            if ($cb.Tag -ne $filterTag) {
                $cb.IsChecked = $checked
                $script:ActiveLevelFilter[$cb.Tag] = $checked
            }
        }
        Request-FilterUpdate
    })
    [void]$FilterPanel.Children.Add($allCb)
    $script:FilterCheckboxes[$allTag] = $allCb

    foreach ($level in ($levels | Sort-Object)) {
        $cb           = New-Object System.Windows.Controls.CheckBox
        $cb.Content   = $level
        $cb.Tag       = $level
        $cb.IsChecked = $true
        $cb.Margin    = "4,0,4,0"

        $colorName = $script:Config.Keywords[$level]
        if ($colorName -and $script:ColorMap.ContainsKey($colorName)) {
            $hex = $script:ColorMap[$colorName]
            try {
                $brush = New-Object System.Windows.Media.SolidColorBrush(
                             [System.Windows.Media.ColorConverter]::ConvertFromString($hex))
                $cb.Background = $brush
            } catch {
                Write-OperationalError "Invoke-RebuildFilterBar" "Brush error for level '$level': $_"
            }
        }

        $script:ActiveLevelFilter[$level] = $true

        $cb.Add_Click({
            param($s, $e)
            $script:ActiveLevelFilter[$s.Tag] = ($s.IsChecked -eq $true)
            $filterTag   = [FilterTags]::All
            $anyUnchecked = $script:FilterCheckboxes.Values |
                            Where-Object { $_.Tag -ne $filterTag -and $_.IsChecked -ne $true }
            $script:FilterCheckboxes[$filterTag].IsChecked = ($null -eq $anyUnchecked)
            Request-FilterUpdate
        })

        [void]$FilterPanel.Children.Add($cb)
        $script:FilterCheckboxes[$level] = $cb
    }
}

# ---------------------------------------------------------------------------
# Schedule a debounced filter rebuild.
# ---------------------------------------------------------------------------
function Request-FilterUpdate {
    $script:FilterDebounceTimer.Stop()
    $script:FilterDebounceTimer.Start()
}

# ---------------------------------------------------------------------------
# Full rebuild of DisplayCollection from MasterList.
# The filtering loop runs in C# (LogParser.FilterEntries) to avoid
# per-iteration PowerShell overhead across potentially 100 000 entries.
#
# NOTE: All calls to this function must use [void] or $null = to suppress
# pipeline output.  PowerShell functions implicitly return any uncaptured
# output; callers that inspect the return value of functions which call
# Invoke-ApplyFilter (e.g. Invoke-TrimMasterList) must not receive leaked
# output or the boolean return value will be wrapped in an array.
# ---------------------------------------------------------------------------
function Invoke-ApplyFilter {
    # Build a typed dictionary from the PowerShell hashtable for the C# helper.
    $filterDict = New-Object 'System.Collections.Generic.Dictionary[string,bool]'
    foreach ($kv in $script:ActiveLevelFilter.GetEnumerator()) {
        $filterDict[$kv.Key] = [bool]$kv.Value
    }

    $visible = [LogParser]::FilterEntries($script:MasterList, $filterDict)
    $script:DisplayCollection.ReplaceAll($visible)

    if ($script:ScrollBtn.IsChecked -and $script:DisplayCollection.Count -gt 0) {
        $script:LogDataGrid.ScrollIntoView(
            $script:DisplayCollection[$script:DisplayCollection.Count - 1])
    }
}

# ---------------------------------------------------------------------------
# Append only filter-passing entries from a fresh batch during live tailing.
# Reuses the C# FilterEntries helper to keep the loop out of the interpreter.
# ---------------------------------------------------------------------------
function Add-VisibleEntries {
    param([System.Collections.Generic.List[LogEntry]]$entries)

    $filterDict = New-Object 'System.Collections.Generic.Dictionary[string,bool]'
    foreach ($kv in $script:ActiveLevelFilter.GetEnumerator()) {
        $filterDict[$kv.Key] = [bool]$kv.Value
    }

    $toAdd = [LogParser]::FilterEntries($entries, $filterDict)
    if ($toAdd.Count -gt 0) {
        try {
            $script:DisplayCollection.AddRange($toAdd)
        } catch {
            Write-OperationalError "Add-VisibleEntries" "AddRange reentrancy error: $_"
        }
    }
}

# ---------------------------------------------------------------------------
# Runspace management
# ---------------------------------------------------------------------------
function Stop-LogTailing {
    if ($null -ne $script:Cts) { $script:Cts.Cancel() }
    if ($null -ne $script:RunspacePS) {
        try {
            if ($null -ne $script:AsyncResult -and -not $script:AsyncResult.IsCompleted) {
                [void]$script:AsyncResult.AsyncWaitHandle.WaitOne(2000)
            }
            $script:RunspacePS.EndInvoke($script:AsyncResult)
        } catch {
            Write-OperationalError "Stop-LogTailing" "EndInvoke error: $_"
        }
        try { $script:RunspacePS.Stop()    } catch { Write-OperationalError "Stop-LogTailing" "Stop error: $_"    }
        try { $script:RunspacePS.Dispose() } catch { Write-OperationalError "Stop-LogTailing" "Dispose error: $_" }
        $script:RunspacePS  = $null
        $script:AsyncResult = $null
    }
    if ($null -ne $script:RunspaceObj) {
        try { $script:RunspaceObj.Close()   } catch { Write-OperationalError "Stop-LogTailing" "Runspace.Close error: $_"   }
        try { $script:RunspaceObj.Dispose() } catch { Write-OperationalError "Stop-LogTailing" "Runspace.Dispose error: $_" }
        $script:RunspaceObj = $null
    }
    if ($null -ne $script:Cts) {
        $script:Cts.Dispose()
        $script:Cts = $null
    }
}

function Start-LogTailing {
    param([string]$FilePath, [bool]$ResetState = $false)

    # Always stop any previously running tailing session first.
    Stop-LogTailing

    if ($ResetState -or $null -eq $script:SharedState) {
        $script:SharedState = [hashtable]::Synchronized(@{
            LastFileLength         = [long]0
            PendingBuffer          = ""
            InitialLoadComplete    = $false
            IsFlushingInitialQueue = $true
            LastError              = $null
        })

        Set-TimerInterval ([TimeSpan]::FromMilliseconds($script:FastTimerIntervalMs))
    } else {
        # Resume after pause: reset the flushing flag so the timer transition
        # logic fires again once the newly-appended entries have been drained.
        $script:SharedState["InitialLoadComplete"]    = $false
        $script:SharedState["IsFlushingInitialQueue"] = $true
        $script:SharedState["LastError"]              = $null

        Set-TimerInterval ([TimeSpan]::FromMilliseconds($script:FastTimerIntervalMs))
    }

    # Drain and discard any stale entries from the previous queue.
    if ($null -ne $script:LogQueue) {
        $discarded = $null
        while ($script:LogQueue.TryDequeue([ref]$discarded)) {}
    }

    $script:LogQueue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()

    # Build the sorted keyword list once and pass it to the background thread.
    # Sorting by key length descending ensures deterministic first-match-wins
    # behaviour regardless of Dictionary hash order.
    $orderedKeywords = Get-SortedKeywords

    # Wrap runspace creation in try/catch so any failure cleans up partial
    # state rather than leaking a runspace or PowerShell instance.
    try {
        $script:Cts         = New-Object System.Threading.CancellationTokenSource
        $script:RunspaceObj = [runspacefactory]::CreateRunspace()
        $script:RunspaceObj.Open()

        $script:RunspacePS          = [System.Management.Automation.PowerShell]::Create()
        $script:RunspacePS.Runspace = $script:RunspaceObj

        [void]$script:RunspacePS.AddScript($bgScript).
            AddArgument($FilePath).
            AddArgument($orderedKeywords).
            AddArgument($script:LogQueue).
            AddArgument($script:Cts.Token).
            AddArgument($script:SharedState).
            AddArgument($script:PollIntervalMs)

        $script:AsyncResult = $script:RunspacePS.BeginInvoke()
    } catch {
        Write-OperationalError "Start-LogTailing" "Failed to start background runspace: $_"
        # Clean up whatever was partially created.
        Stop-LogTailing
    }
}

# ---------------------------------------------------------------------------
# Dynamic row styling built programmatically to avoid XAML string injection.
# ---------------------------------------------------------------------------
function Set-GuiFromConfig {
    try {
        $font = New-Object System.Windows.Media.FontFamily($script:Config.FontFamily)
        $LogDataGrid.FontFamily   = $font
        $DetailTextBox.FontFamily = $font
        $LogDataGrid.FontSize     = $script:Config.FontSize
        $DetailTextBox.FontSize   = $script:Config.FontSize

        if ($null -ne $BottomRow) {
            $BottomRow.Height = New-Object System.Windows.GridLength(
                                    [double]$script:Config.BottomPanelHeight)
        } else {
            Write-OperationalError "Set-GuiFromConfig" "BottomRow RowDefinition is null — panel height not applied."
        }

        # Build the DataGridRow style entirely in code to eliminate any risk
        # of XAML string injection from keyword or colour values.
        $rowStyle = New-Object System.Windows.Style([System.Windows.Controls.DataGridRow])

        $rowStyle.Setters.Add(
            (New-Object System.Windows.Setter(
                [System.Windows.Controls.DataGridRow]::BackgroundProperty,
                [System.Windows.Media.Brushes]::White)))
        $rowStyle.Setters.Add(
            (New-Object System.Windows.Setter(
                [System.Windows.Controls.DataGridRow]::ForegroundProperty,
                [System.Windows.Media.Brushes]::Black)))

        # One DataTrigger per keyword sets Background based on the Level binding.
        # Keywords are the exact Level values stored on LogEntry so the trigger
        # value matches what DetermineLevel returned.
        foreach ($kw in $script:Config.Keywords.Keys) {
            $colorName = $script:Config.Keywords[$kw]
            $hex = if ($script:ColorMap.ContainsKey($colorName)) {
                $script:ColorMap[$colorName]
            } else { "#FFFFFFFF" }

            try {
                $brush = New-Object System.Windows.Media.SolidColorBrush(
                             [System.Windows.Media.ColorConverter]::ConvertFromString($hex))
                $brush.Freeze()  # Frozen brushes are thread-safe and cache-friendly.

                $trigger         = New-Object System.Windows.DataTrigger
                $trigger.Binding = New-Object System.Windows.Data.Binding("Level")
                $trigger.Value   = $kw
                $trigger.Setters.Add(
                    (New-Object System.Windows.Setter(
                        [System.Windows.Controls.DataGridRow]::BackgroundProperty,
                        $brush)))
                $rowStyle.Triggers.Add($trigger)
            } catch {
                Write-OperationalError "Set-GuiFromConfig" "Brush error for keyword '$kw': $_"
            }
        }

        # Selected-row trigger ensures the selection highlight overrides keyword colours.
        $selectedBrush = New-Object System.Windows.Media.SolidColorBrush(
                             [System.Windows.Media.ColorConverter]::ConvertFromString("#FF3399FF"))
        $selectedBrush.Freeze()
        $selectedFg = [System.Windows.Media.Brushes]::White

        $selectedTrigger          = New-Object System.Windows.Trigger
        $selectedTrigger.Property = [System.Windows.Controls.DataGridRow]::IsSelectedProperty
        $selectedTrigger.Value    = $true
        $selectedTrigger.Setters.Add(
            (New-Object System.Windows.Setter(
                [System.Windows.Controls.DataGridRow]::BackgroundProperty,
                $selectedBrush)))
        $selectedTrigger.Setters.Add(
            (New-Object System.Windows.Setter(
                [System.Windows.Controls.DataGridRow]::ForegroundProperty,
                $selectedFg)))
        $rowStyle.Triggers.Add($selectedTrigger)

        $LogDataGrid.ItemContainerStyle = $rowStyle
    } catch {
        [System.Windows.MessageBox]::Show(
            "Failed to apply UI styles: $_", "UI Error", "OK", "Warning")
    }
}

Set-GuiFromConfig

# ---------------------------------------------------------------------------
# Detail panel formatter
# ---------------------------------------------------------------------------
function Format-LogDetails {
    param([string]$RawMsg)
    $msg = $RawMsg
    if ($script:Config.FormatJson) {
        $trimMsg = $msg.TrimStart()
        if ($trimMsg.StartsWith("{") -or $trimMsg.StartsWith("[")) {
            try {
                $msg = ($msg | ConvertFrom-Json -ErrorAction Stop |
                        ConvertTo-Json -Depth 10)
            } catch {
                Write-OperationalError "Format-LogDetails" "JSON formatting skipped: $_"
            }
        }
    }
    # Use [string]::Replace instead of -replace (regex) for all delimiter
    # substitutions so that delimiter values containing '$' or '\' are never
    # misinterpreted as regex back-references.  The built-in delimiters
    # (comma, space, period) are also migrated to String.Replace for
    # consistency — they are not special regex characters so behaviour is
    # identical, but the pattern is now uniform across all delimiter types.
    if ($script:Config.SplitComma)  { $msg = $msg.Replace(',',  ",`r`n") }
    if ($script:Config.SplitSpace)  { $msg = $msg.Replace(' ',  " `r`n") }
    if ($script:Config.SplitPeriod) { $msg = $msg.Replace('.',  ".`r`n") }
    if ($script:Config.CustomDelimiters.Count -gt 0) {
        foreach ($d in $script:Config.CustomDelimiters) {
            if (-not [string]::IsNullOrWhiteSpace($d)) {
                $msg = $msg.Replace($d, "$d`r`n")
            }
        }
    }
    return $msg
}

# ---------------------------------------------------------------------------
# Trim master list to the configured maximum so memory stays bounded.
#
# Trimming is only triggered at TrimThreshold (110 % of MaxRetainedEntries)
# to avoid thrashing when the list hovers near the limit (hysteresis).
# RemoveRange is O(n) in the number of elements shifted, which is much
# better than repeated RemoveAt(0) calls which would be O(n * excess).
#
# Returns $true if a trim occurred so the caller knows whether
# Invoke-ApplyFilter already rebuilt DisplayCollection and Add-VisibleEntries
# must therefore be skipped.
#
# IMPORTANT: All pipeline output inside this function is suppressed with
# [void] to prevent unintended objects from being included in the return
# value.  PowerShell wraps multiple return objects in an array; callers that
# check the boolean return via -not $trimmed would receive $false for any
# array (even @($true)) if they forget that PowerShell is not a typed
# language.  Using [void] on every statement that could emit pipeline output
# is the safe practice here.
# ---------------------------------------------------------------------------
function Invoke-TrimMasterList {
    if ($script:MasterList.Count -gt $script:TrimThreshold) {
        $excess = $script:MasterList.Count - $script:MaxRetainedEntries
        $script:MasterList.RemoveRange(0, $excess)
        # Suppress pipeline output from Invoke-ApplyFilter so it does not
        # contaminate this function's return value.
        $null = Invoke-ApplyFilter
        return $true
    }
    return $false
}

# ---------------------------------------------------------------------------
# Bind the DataGrid to the filtered display collection.
# ---------------------------------------------------------------------------
 $LogDataGrid.ItemsSource = $script:DisplayCollection
Invoke-RebuildFilterBar

# ---------------------------------------------------------------------------
# Event handlers
# ---------------------------------------------------------------------------
 $PauseBtn.Add_Click({
    if ($PauseBtn.IsChecked) {
        $PauseBtn.Content = "Resume Auto-Refresh"
        Stop-LogTailing
    } else {
        $PauseBtn.Content = "Pause Auto-Refresh"
        if ($null -ne $script:CurrentLogFile) {
            Start-LogTailing -FilePath $script:CurrentLogFile -ResetState $false
        }
    }
})

 $ScrollBtn.Add_Click({
    if ($ScrollBtn.IsChecked) {
        $ScrollBtn.Content = "Auto-Scroll: ON"
    } else {
        $ScrollBtn.Content = "Auto-Scroll: OFF"
    }
})

 $LogDataGrid.Add_SelectionChanged({
    if ($null -ne $LogDataGrid.SelectedItem) {
        $DetailTextBox.Text = Format-LogDetails -RawMsg $LogDataGrid.SelectedItem.RawMsg
    }
})

 $OpenMenu.Add_Click({
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = "Log files (*.log)|*.log|Text files (*.txt)|*.txt|All files (*.*)|*.*"
    if ($dlg.ShowDialog() -eq $true) {
        $script:CurrentLogFile     = $dlg.FileName
        $script:Config.LastLogFile = $dlg.FileName
        $Window.Title = "Configuration Manager Trace Log Tool - $($dlg.FileName)"

        $script:MasterList.Clear()
        $script:DisplayCollection.ReplaceAll($null)
        $DetailTextBox.Text        = ""

        # Clear search state so stale highlights from the previous file do not persist.
        $SearchBox.Text            = ""
        $LogDataGrid.SelectedIndex = -1

        Invoke-RebuildFilterBar
        Start-LogTailing -FilePath $script:CurrentLogFile -ResetState $true
    }
})

 $ExitMenu.Add_Click({ $Window.Close() })

# ---------------------------------------------------------------------------
# Error log viewer — surfaces the operational error log that was previously
# collected silently and invisible to the user.
# ---------------------------------------------------------------------------
 $ErrorLogMenu.Add_Click({
    if ($script:ErrorLog.Count -eq 0) {
        [System.Windows.MessageBox]::Show(
            "No operational errors have been recorded in this session.",
            "Error Log",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information)
        return
    }

    [xml]$errXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="Operational Error Log" Height="400" Width="700"
        WindowStartupLocation="CenterOwner" Background="#FFF4F4F4"
        ResizeMode="CanResize">
    <Grid Margin="5">
        <Grid.RowDefinitions>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBox Grid.Row="0" Name="ErrorText"
                 IsReadOnly="True"
                 Background="White"
                 FontFamily="Consolas"
                 FontSize="11"
                 VerticalScrollBarVisibility="Auto"
                 HorizontalScrollBarVisibility="Auto"
                 TextWrapping="NoWrap"
                 Padding="4"/>
        <StackPanel Grid.Row="1" Orientation="Horizontal"
                    HorizontalAlignment="Right" Margin="0,5,0,0">
            <Button Name="ClearErrBtn" Content="Clear Log" Width="80" Margin="0,0,5,0"/>
            <Button Name="CloseErrBtn" Content="Close"     Width="70" IsCancel="True"/>
        </StackPanel>
    </Grid>
</Window>
"@
    $errReader = New-Object System.Xml.XmlNodeReader $errXaml
    try {
        $errWindow = [Windows.Markup.XamlReader]::Load($errReader)
    } finally {
        $errReader.Dispose()
    }
    $errWindow.Owner   = $Window
    $errText           = $errWindow.FindName("ErrorText")
    $clearErrBtn       = $errWindow.FindName("ClearErrBtn")
    $closeErrBtn       = $errWindow.FindName("CloseErrBtn")

    $errText.Text = $script:ErrorLog -join "`r`n"

    $clearErrBtn.Add_Click({
        $script:ErrorLog.Clear()
        $errText.Text = ""
    })
    $closeErrBtn.Add_Click({ $errWindow.Close() })

    [void]$errWindow.ShowDialog()
})

# ---------------------------------------------------------------------------
# Search
# Delegates the loop to LogParser.FindNext (C#) to keep the O(n) scan out
# of the PowerShell interpreter.  Auto-pauses tailing while searching so
# new entries don't shift the list under the user's cursor.
#
# UX NOTE: Searching automatically pauses live tailing and disables
# auto-scroll so that new entries do not shift the result list while the
# user is navigating matches.  The title bar shows a "[Searching — tailing
# paused]" suffix to make the paused state visible.  To resume tailing the
# user must click "Resume Auto-Refresh" explicitly.  The Clear button
# removes the search text and the title suffix but does NOT auto-resume
# tailing — that is intentional so the user has full control over when
# live updates restart.
# ---------------------------------------------------------------------------
function Find-NextMatch {
    $searchText = $SearchBox.Text
    if ([string]::IsNullOrWhiteSpace($searchText)) { return }

    # Pause live tailing while searching so new entries don't shift the list
    # under the user's cursor.
    if (-not $PauseBtn.IsChecked) {
        $PauseBtn.IsChecked = $true
        $PauseBtn.Content   = "Resume Auto-Refresh"
        Stop-LogTailing
        # Append the search-pause indicator to the title if not already present.
        if (-not $Window.Title.EndsWith($script:SearchPausedSuffix)) {
            $Window.Title = $Window.Title + $script:SearchPausedSuffix
        }
    }
    if ($ScrollBtn.IsChecked) {
        $ScrollBtn.IsChecked = $false
        $ScrollBtn.Content   = "Auto-Scroll: OFF"
    }

    if ($null -eq $script:DisplayCollection -or $script:DisplayCollection.Count -eq 0) { return }

    $startIndex = $LogDataGrid.SelectedIndex + 1
    if ($startIndex -ge $script:DisplayCollection.Count -or $startIndex -lt 0) { $startIndex = 0 }

    # Show a wait cursor and delegate the search loop to C# for performance.
    $Window.Cursor = [System.Windows.Input.Cursors]::Wait
    try {
        # Cast ItemCollection to IList<LogEntry> via the typed master/display list.
        # LogParser.FindNext accepts IList<LogEntry>; pass DisplayCollection directly
        # since it is an ObservableRangeCollection<LogEntry> which implements IList<LogEntry>.
        $idx = [LogParser]::FindNext($script:DisplayCollection, $searchText, $startIndex)
        if ($idx -ge 0) {
            $LogDataGrid.SelectedIndex = $idx
            $LogDataGrid.ScrollIntoView($script:DisplayCollection[$idx])
            $LogDataGrid.Focus()
        }
    } finally {
        $Window.Cursor = $null
    }
}

 $SearchBtn.Add_Click({ Find-NextMatch })

 $SearchBox.Add_KeyDown({
    if ($_.Key -eq 'Return' -or $_.Key -eq 'Enter') {
        $_.Handled = $true
        Find-NextMatch
    }
})

 $ClearSearchBtn.Add_Click({
    $SearchBox.Text            = ""
    $LogDataGrid.SelectedIndex = -1
    $DetailTextBox.Text        = ""
    $SearchBox.Focus()
    # Remove the search-pause indicator from the title if present.
    # Use the shared constant so the strip pattern cannot diverge from the
    # append pattern in Find-NextMatch.
    if ($Window.Title.EndsWith($script:SearchPausedSuffix)) {
        $Window.Title = $Window.Title.Substring(
            0, $Window.Title.Length - $script:SearchPausedSuffix.Length)
    }
})

 $FindMenu.Add_Click({ $SearchBox.Focus() })

 $Window.Add_Closing({
    try {
        if ($null -ne $script:FilterDebounceTimer) { $script:FilterDebounceTimer.Stop() }
        if ($null -ne $script:RefreshTimer)        { $script:RefreshTimer.Stop()        }
        Stop-LogTailing

        if ($null -ne $BottomRow) {
            $script:Config.BottomPanelHeight = [int]$BottomRow.Height.Value
        }
        $script:Config.WindowWidth  = [Math]::Max(
            $script:MinWindowWidth,
            [Math]::Min($script:MaxWindowWidth, [int]$Window.Width))
        $script:Config.WindowHeight = [Math]::Max(
            $script:MinWindowHeight,
            [Math]::Min($script:MaxWindowHeight, [int]$Window.Height))

        Export-Config
    } catch {
        Write-OperationalError "Window.Closing" "$_"
    }

    # Flush any errors collected during the session to the host console so
    # they are not silently lost when the process exits.
    if ($script:ErrorLog.Count -gt 0) {
        Write-Host "`n--- Operational Error Log ---" -ForegroundColor Yellow
        foreach ($entry in $script:ErrorLog) {
            Write-Host $entry -ForegroundColor Red
        }
    }
})

# ---------------------------------------------------------------------------
# Settings dialog
# ---------------------------------------------------------------------------
 $SettingsMenu.Add_Click({
    [xml]$settingsXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:sys="clr-namespace:System;assembly=mscorlib"
        Title="Settings" Height="680" Width="450" FontSize="11"
        WindowStartupLocation="CenterOwner" Background="#FFF4F4F4"
        ResizeMode="CanResize">
    <Window.Resources>
        <x:Array x:Key="ColorList" Type="sys:String">
            <sys:String>Red</sys:String>
            <sys:String>Orange</sys:String>
            <sys:String>Yellow</sys:String>
            <sys:String>Green</sys:String>
            <sys:String>Blue</sys:String>
            <sys:String>Purple</sys:String>
            <sys:String>White</sys:String>
        </x:Array>
    </Window.Resources>
    <Grid Margin="5">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <GroupBox Header=" General Settings " Grid.Row="0" Margin="0,0,0,5" Padding="3">
            <Grid Margin="2">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock Text="Font Family:" Grid.Column="0" VerticalAlignment="Center" Margin="2"/>
                <ComboBox  Name="FontCombo"    Grid.Column="1" Margin="2"/>
                <TextBlock Text="Size:"        Grid.Column="2" Margin="5,0,2,0" VerticalAlignment="Center"/>
                <ComboBox  Name="SizeCombo"    Grid.Column="3" Width="40" Margin="2"/>
                <TextBlock Text="Speed (s):"   Grid.Column="4" Margin="5,0,2,0" VerticalAlignment="Center"/>
                <ComboBox  Name="SpeedCombo"   Grid.Column="5" Width="40" Margin="2"/>
            </Grid>
        </GroupBox>

        <GroupBox Header=" Detail Panel Formatting " Grid.Row="1" Margin="0,0,0,5" Padding="3">
            <WrapPanel Margin="2">
                <CheckBox Name="JsonCheck"   Content="Format JSON"   Margin="2"/>
                <CheckBox Name="CommaCheck"  Content="Split Commas"  Margin="2"/>
                <CheckBox Name="SpaceCheck"  Content="Split Spaces"  Margin="2"/>
                <CheckBox Name="PeriodCheck" Content="Split Periods" Margin="2"/>
            </WrapPanel>
        </GroupBox>

        <GroupBox Header=" Custom Delimiters " Grid.Row="2" Margin="0,0,0,5" Padding="3">
            <Grid Margin="2">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="80"/>
                </Grid.RowDefinitions>
                <StackPanel Orientation="Horizontal" Grid.Row="0" Margin="2">
                    <TextBlock Text="Delimiter:" VerticalAlignment="Center" Margin="2"/>
                    <TextBox   Name="NewDelim"        Width="60"  Margin="2"/>
                    <Button    Name="AddDelimBtn"    Content="Add"             Width="50"  Margin="2"/>
                    <Button    Name="RemoveDelimBtn" Content="Remove Selected" Width="100" Margin="2"/>
                </StackPanel>
                <ListBox Name="DelimList" Grid.Row="1" Margin="2"
                         ScrollViewer.CanContentScroll="False"/>
            </Grid>
        </GroupBox>

        <GroupBox Header=" Keyword Highlighting " Grid.Row="3" Margin="0,0,0,5" Padding="3">
            <Grid Margin="2">
                <Grid.RowDefinitions>
                    <RowDefinition Height="*"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>
                <DataGrid Name="KeywordsGrid" Grid.Row="0"
                          AutoGenerateColumns="False" HeadersVisibility="Column"
                          CanUserAddRows="True" CanUserDeleteRows="True"
                          Margin="2" VirtualizingPanel.ScrollUnit="Pixel">
                    <DataGrid.Columns>
                        <DataGridTextColumn Header="Keyword"
                            Binding="{Binding Key}" Width="*" IsReadOnly="False"/>
                        <DataGridTemplateColumn Header="Color" Width="100">
                            <DataGridTemplateColumn.CellTemplate>
                                <DataTemplate>
                                    <ComboBox SelectedItem="{Binding Value, Mode=TwoWay,
                                                  UpdateSourceTrigger=PropertyChanged}"
                                              ItemsSource="{StaticResource ColorList}"
                                              Margin="1"/>
                                </DataTemplate>
                            </DataGridTemplateColumn.CellTemplate>
                        </DataGridTemplateColumn>
                    </DataGrid.Columns>
                </DataGrid>
                <Button Name="RemoveBtn" Content="Remove Selected" Grid.Row="1"
                        Width="100" HorizontalAlignment="Left" Margin="2"/>
            </Grid>
        </GroupBox>

        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right"
                    Grid.Row="4" Margin="5,2,0,2">
            <Button Name="SaveBtn"   Content="Save &amp; Apply" Width="90"
                    Margin="0,0,5,0" IsDefault="True"/>
            <Button Name="CancelBtn" Content="Cancel"           Width="70" IsCancel="True"/>
        </StackPanel>
    </Grid>
</Window>
"@

    $sReader = New-Object System.Xml.XmlNodeReader $settingsXaml
    try {
        $sWindow = [Windows.Markup.XamlReader]::Load($sReader)
    } finally {
        $sReader.Dispose()
    }
    $sWindow.Owner  = $Window

    $FontCombo      = $sWindow.FindName("FontCombo")
    $SizeCombo      = $sWindow.FindName("SizeCombo")
    $SpeedCombo     = $sWindow.FindName("SpeedCombo")
    $JsonCheck      = $sWindow.FindName("JsonCheck")
    $CommaCheck     = $sWindow.FindName("CommaCheck")
    $SpaceCheck     = $sWindow.FindName("SpaceCheck")
    $PeriodCheck    = $sWindow.FindName("PeriodCheck")
    $NewDelim       = $sWindow.FindName("NewDelim")
    $AddDelimBtn    = $sWindow.FindName("AddDelimBtn")
    $RemoveDelimBtn = $sWindow.FindName("RemoveDelimBtn")
    $DelimList      = $sWindow.FindName("DelimList")
    $KeywordsGrid   = $sWindow.FindName("KeywordsGrid")
    $RemoveBtn      = $sWindow.FindName("RemoveBtn")
    $SaveBtn        = $sWindow.FindName("SaveBtn")
    $CancelBtn      = $sWindow.FindName("CancelBtn")

    Add-SlowScroll $KeywordsGrid
    Add-SlowScroll $DelimList

    # -------------------------------------------------------------------
    # Use WPF's native font enumeration rather than System.Drawing so the
    # font names are guaranteed to resolve when applied via
    # System.Windows.Media.FontFamily.  GDI+ and WPF maintain separate
    # font caches and can disagree on available family names.
    # -------------------------------------------------------------------
    foreach ($f in ([System.Windows.Media.Fonts]::SystemFontFamilies |
                    Select-Object -ExpandProperty Source | Sort-Object)) {
        [void]$FontCombo.Items.Add($f)
    }
    # If the currently configured font is not in the WPF enumeration
    # (e.g. it was set by manually editing the INI), insert it at the top
    # so the combo reflects the live setting rather than silently showing
    # nothing selected.
    if (-not $FontCombo.Items.Contains($script:Config.FontFamily)) {
        $FontCombo.Items.Insert(0, $script:Config.FontFamily)
    }
    $FontCombo.SelectedItem = $script:Config.FontFamily

    # Font size combo: show sizes 8-24 (the practical UI range).
    # Import-Config accepts the wider range MinFontSize..MaxFontSize (6-72)
    # so a manually edited INI value may fall outside this list.  Handle
    # that by inserting the current value if it is absent.
    $script:MinFontSize..$script:MaxFontSize |
        Where-Object { $_ -ge 8 -and $_ -le 24 } |
        ForEach-Object { [void]$SizeCombo.Items.Add($_) }
    if (-not $SizeCombo.Items.Contains($script:Config.FontSize)) {
        $SizeCombo.Items.Insert(0, $script:Config.FontSize)
    }
    $SizeCombo.SelectedItem = $script:Config.FontSize

    # Update speed combo: show speeds 1-10 seconds.
    $script:MinUpdateSpeed..$script:MaxUpdateSpeed |
        Where-Object { $_ -ge 1 -and $_ -le 10 } |
        ForEach-Object { [void]$SpeedCombo.Items.Add($_) }
    if (-not $SpeedCombo.Items.Contains($script:Config.UpdateSpeed)) {
        $SpeedCombo.Items.Insert(0, $script:Config.UpdateSpeed)
    }
    $SpeedCombo.SelectedItem = $script:Config.UpdateSpeed

    $JsonCheck.IsChecked   = $script:Config.FormatJson
    $CommaCheck.IsChecked  = $script:Config.SplitComma
    $SpaceCheck.IsChecked  = $script:Config.SplitSpace
    $PeriodCheck.IsChecked = $script:Config.SplitPeriod

    foreach ($d in $script:Config.CustomDelimiters) {
        [void]$DelimList.Items.Add($d)
    }

    $kwList = New-Object System.Collections.ObjectModel.ObservableCollection[KeywordItem]
    foreach ($kv in $script:Config.Keywords.GetEnumerator()) {
        $kwList.Add(
            (New-Object KeywordItem -Property @{
                Key   = $kv.Key
                Value = $kv.Value
            })
        )
    }
    $KeywordsGrid.ItemsSource = $kwList

    $AddDelimBtn.Add_Click({
        if (-not [string]::IsNullOrEmpty($NewDelim.Text)) {
            [void]$DelimList.Items.Add($NewDelim.Text)
            $NewDelim.Text = ""
        }
    })

    $RemoveDelimBtn.Add_Click({
        if ($null -ne $DelimList.SelectedItem) {
            $DelimList.Items.Remove($DelimList.SelectedItem)
        }
    })

    $RemoveBtn.Add_Click({
        if ($null -ne $KeywordsGrid.SelectedItem -and
            $KeywordsGrid.SelectedItem -is [KeywordItem]) {
            $kwList.Remove($KeywordsGrid.SelectedItem)
        }
    })

    $SaveBtn.Add_Click({
        # ------------------------------------------------------------------
        # Force-commit any pending DataGrid cell edit before reading kwList.
        # Without this, a value that the user is actively editing when they
        # click Save will not have been written back to the bound object.
        # ------------------------------------------------------------------
        $KeywordsGrid.CommitEdit(
            [System.Windows.Controls.DataGridEditingUnit]::Row, $true)

        # ------------------------------------------------------------------
        # Validate for duplicate keyword entries before committing anything.
        # ------------------------------------------------------------------
        $duplicates = $kwList |
                      Where-Object { -not [string]::IsNullOrWhiteSpace($_.Key) } |
                      Group-Object Key |
                      Where-Object { $_.Count -gt 1 }

        if ($duplicates) {
            $dupNames = ($duplicates | Select-Object -ExpandProperty Name) -join ', '
            [System.Windows.MessageBox]::Show(
                "The following keywords are duplicated: $dupNames`r`n`r`nPlease remove the duplicates before saving.",
                "Duplicate Keywords",
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Warning)
            return
        }

        # ------------------------------------------------------------------
        # Enforce the keyword count limit so the row-style trigger count
        # stays within performance-safe bounds.
        # ------------------------------------------------------------------
        $validKeywords = @($kwList | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_.Key)
        })
        if ($validKeywords.Count -gt $script:MaxKeywordCount) {
            [System.Windows.MessageBox]::Show(
                "You have defined $($validKeywords.Count) keywords.  The maximum allowed is $script:MaxKeywordCount.`r`nPlease remove some keywords before saving.",
                "Too Many Keywords",
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Warning)
            return
        }

        # ------------------------------------------------------------------
        # Warn the user about rows with a blank key so they are not silently
        # discarded on save without the user's awareness.
        # ------------------------------------------------------------------
        $blankKeyRows = @($kwList | Where-Object { [string]::IsNullOrWhiteSpace($_.Key) })
        if ($blankKeyRows.Count -gt 0) {
            $result = [System.Windows.MessageBox]::Show(
                "$($blankKeyRows.Count) keyword row(s) have an empty key and will be discarded.`r`nContinue saving?",
                "Empty Keywords",
                [System.Windows.MessageBoxButton]::YesNo,
                [System.Windows.MessageBoxImage]::Warning)
            if ($result -ne [System.Windows.MessageBoxResult]::Yes) { return }
        }

        # Validated assignments with fallback defaults.
        $defaults = Get-DefaultConfig
        $script:Config.FontFamily = if ($null -ne $FontCombo.SelectedItem) {
            $FontCombo.SelectedItem
        } else { $defaults.FontFamily }

        $script:Config.FontSize = if ($null -ne $SizeCombo.SelectedItem) {
            [Math]::Max($script:MinFontSize,
                [Math]::Min($script:MaxFontSize, [int]$SizeCombo.SelectedItem))
        } else { $defaults.FontSize }

        $script:Config.UpdateSpeed = if ($null -ne $SpeedCombo.SelectedItem) {
            [Math]::Max($script:MinUpdateSpeed,
                [Math]::Min($script:MaxUpdateSpeed, [int]$SpeedCombo.SelectedItem))
        } else { $defaults.UpdateSpeed }

        $script:Config.FormatJson  = ($JsonCheck.IsChecked  -eq $true)
        $script:Config.SplitComma  = ($CommaCheck.IsChecked -eq $true)
        $script:Config.SplitSpace  = ($SpaceCheck.IsChecked -eq $true)
        $script:Config.SplitPeriod = ($PeriodCheck.IsChecked -eq $true)

        $delims = @()
        foreach ($d in $DelimList.Items) { $delims += $d }
        $script:Config.CustomDelimiters = $delims

        $newKw = @{}
        foreach ($item in $kwList) {
            if ($null -ne $item -and
                -not [string]::IsNullOrWhiteSpace($item.Key)) {
                $newKw[$item.Key] = $item.Value
            }
        }
        $script:Config.Keywords = $newKw

        Export-Config
        Set-GuiFromConfig

        # Re-evaluate levels for all master-list entries using the new keyword
        # set and their stored TypeVal.  ReEvaluateAll runs in C# to keep the
        # 100 000-entry loop out of the PowerShell interpreter.
        $orderedKeywords = Get-SortedKeywords
        [LogParser]::ReEvaluateAll($script:MasterList, $orderedKeywords)

        Invoke-RebuildFilterBar
        $null = Invoke-ApplyFilter

        # Restart tailing with the updated keyword list if a file is open and
        # tailing is not paused.  ResetState is false so the tail position is
        # preserved and only new content is parsed with the new keywords.
        if ($null -ne $script:CurrentLogFile -and -not $PauseBtn.IsChecked) {
            Start-LogTailing -FilePath $script:CurrentLogFile -ResetState $false
        }

        try {
            if ($null -eq $script:SharedState -or
                -not $script:SharedState["IsFlushingInitialQueue"]) {
                Set-TimerInterval ([TimeSpan]::FromSeconds($script:Config.UpdateSpeed))
            }
        } catch {
            Write-OperationalError "Settings.SaveBtn" "Timer reconfigure error: $_"
        }

        $sWindow.Close()
    })

    $CancelBtn.Add_Click({ $sWindow.Close() })
    [void]$sWindow.ShowDialog()
})

# ---------------------------------------------------------------------------
# DispatcherTimer — consumes the background queue and feeds master + display.
#
# The timer is created here but NOT started until a file is opened.  Starting
# it immediately (even with null-guard early exits) wastes 100 ms wake-ups
# when no log file is being tailed.  Start-LogTailing calls Set-TimerInterval
# which starts the timer; Stop-LogTailing does NOT stop it so the timer
# continues draining any remaining queued entries after a pause.  The timer
# is only stopped on window close.
# ---------------------------------------------------------------------------
 $script:RefreshTimer          = New-Object System.Windows.Threading.DispatcherTimer
 $script:RefreshTimer.Interval = [TimeSpan]::FromMilliseconds($script:FastTimerIntervalMs)

 $script:RefreshTimer.Add_Tick({
    try {
        # ------------------------------------------------------------------
        # Surface any error the background thread stored in SharedState.
        # ------------------------------------------------------------------
        if ($null -ne $script:SharedState -and
            $null -ne $script:SharedState["LastError"]) {
            Write-OperationalError "BackgroundThread" $script:SharedState["LastError"]
            $script:SharedState["LastError"] = $null
        }

        # ------------------------------------------------------------------
        # Detect when the initial file load is complete and slow the timer.
        # ------------------------------------------------------------------
        if ($null -ne $script:SharedState -and
            $script:SharedState["InitialLoadComplete"] -and
            $script:SharedState["IsFlushingInitialQueue"]) {

            if ($null -eq $script:LogQueue -or $script:LogQueue.IsEmpty) {
                $script:SharedState["IsFlushingInitialQueue"] = $false

                Set-TimerInterval ([TimeSpan]::FromSeconds([int]$script:Config.UpdateSpeed))

                if ($ScrollBtn.IsChecked -and $script:DisplayCollection.Count -gt 0) {
                    $LogDataGrid.ScrollIntoView(
                        $script:DisplayCollection[$script:DisplayCollection.Count - 1])
                }
            }
        }

        # ------------------------------------------------------------------
        # Drain up to MaxDrainPerTick entries per tick from the background queue.
        # ------------------------------------------------------------------
        if ($null -ne $script:LogQueue -and -not $script:LogQueue.IsEmpty) {

            $queueCount = $script:LogQueue.Count
            $allocSize  = [Math]::Min($queueCount + 1, $script:MaxDrainPerTick)
            $newEntries = New-Object System.Collections.Generic.List[LogEntry]($allocSize)
            $rawEntry   = $null
            $count      = 0

            while ($script:LogQueue.TryDequeue([ref]$rawEntry) -and
                   $count -lt $script:MaxDrainPerTick) {
                # Queue holds [object] to avoid runspace type-resolution issues;
                # cast back to LogEntry here on the UI thread where the type is certain.
                $typedEntry = $rawEntry -as [LogEntry]
                if ($null -ne $typedEntry) {
                    [void]$newEntries.Add($typedEntry)
                } else {
                    # Log unexpected queue contents rather than silently discarding.
                    Write-OperationalError "RefreshTimer.Tick" `
                        "Queue contained a non-LogEntry object of type '$($rawEntry.GetType().FullName)'; entry discarded."
                }
                $count++
            }

            if ($newEntries.Count -gt 0) {
                $script:MasterList.AddRange($newEntries)

                # Invoke-TrimMasterList returns $true if it trimmed and already
                # called Invoke-ApplyFilter (which rebuilds DisplayCollection from
                # scratch).  In that case Add-VisibleEntries must NOT also be called
                # or the newly-trimmed entries will be appended a second time.
                # $null = is used to suppress any pipeline output from the function
                # so the boolean comparison is not accidentally wrapped in an array.
                $trimmed = Invoke-TrimMasterList
                if (-not $trimmed) {
                    Add-VisibleEntries -entries $newEntries
                }

                if ($ScrollBtn.IsChecked) {
                    $shouldScroll = $true
                    if ($null -ne $script:SharedState -and
                        $script:SharedState["IsFlushingInitialQueue"] -and
                        -not $script:LogQueue.IsEmpty) {
                        # Suppress per-batch scrolling during the initial load;
                        # scroll once when fully flushed to avoid thrashing.
                        $shouldScroll = $false
                    }
                    if ($shouldScroll -and $script:DisplayCollection.Count -gt 0) {
                        $LogDataGrid.ScrollIntoView(
                            $script:DisplayCollection[$script:DisplayCollection.Count - 1])
                    }
                }
            }
        }
    } catch {
        Write-OperationalError "RefreshTimer.Tick" "$_"
    }
})

# NOTE: The timer is intentionally NOT started here.  It is started by
# Start-LogTailing via Set-TimerInterval when a file is first opened.
# This avoids 100 ms wake-ups before any log file has been selected.

# ---------------------------------------------------------------------------
# Auto-open the last used file on startup.
# ---------------------------------------------------------------------------
if (-not [string]::IsNullOrWhiteSpace($script:Config.LastLogFile) -and
    (Test-Path $script:Config.LastLogFile)) {

    $script:CurrentLogFile = $script:Config.LastLogFile
    $Window.Title = "Configuration Manager Trace Log Tool - $($script:Config.LastLogFile)"
    Invoke-RebuildFilterBar
    Start-LogTailing -FilePath $script:CurrentLogFile -ResetState $true
}

[void]$Window.ShowDialog()
