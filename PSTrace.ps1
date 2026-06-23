# ===========================================================================
# Configuration Manager Trace Log Tool
# Requires: PowerShell 5.1+, STA thread, 64-bit host
# ===========================================================================

#region --- Prerequisites ---

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne
    [System.Threading.ApartmentState]::STA) {
    Write-Warning "This script requires an STA thread. Re-launch with: powershell -STA -File `"$PSCommandPath`""
    return
}

if ($PSVersionTable.PSVersion.Major -lt 5) {
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        [System.Windows.Forms.MessageBox]::Show(
            "This script requires PowerShell 5.1 or later.",
            "Startup Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    } catch {
        Write-Warning "This script requires PowerShell 5.1 or later."
    }
    return
}

if (-not [System.Environment]::Is64BitProcess) {
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        [System.Windows.Forms.MessageBox]::Show(
            "This script requires a 64-bit PowerShell host.",
            "Startup Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    } catch {
        Write-Warning "This script requires a 64-bit PowerShell host."
    }
    return
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, Microsoft.VisualBasic

#endregion

#region --- XAML / Startup Diagnostic Helpers ---

function Get-XamlSnippet {
    param(
        [string]$XamlText,
        [int]$LineNumber,
        [int]$Radius = 3
    )
    if ([string]::IsNullOrWhiteSpace($XamlText) -or $LineNumber -le 0) { return $null }
    $lines = $XamlText -split "`r?`n"
    if ($LineNumber -gt $lines.Count) { return $null }
    $start = [Math]::Max(1, $LineNumber - $Radius)
    $end   = [Math]::Min($lines.Count, $LineNumber + $Radius)
    $sb    = New-Object System.Text.StringBuilder
    for ($i = $start; $i -le $end; $i++) {
        $prefix = if ($i -eq $LineNumber) { ">>" } else { "  " }
        [void]$sb.AppendLine(("{0} {1,4}: {2}" -f $prefix, $i, $lines[$i - 1]))
    }
    return $sb.ToString()
}

function Get-ExceptionReport {
    param(
        [System.Exception]$Exception,
        [string]$XamlText
    )
    $sb  = New-Object System.Text.StringBuilder
    $idx = 0
    $ex  = $Exception
    while ($null -ne $ex) {
        $label = if ($idx -eq 0) { "Exception" } else { "Inner Exception $idx" }
        [void]$sb.AppendLine("$label Type    : $($ex.GetType().FullName)")
        [void]$sb.AppendLine("$label Message : $($ex.Message)")
        try {
            $h = $ex.HResult
            [void]$sb.AppendLine(("$label HResult : 0x{0:X8}" -f ($h -band 0xFFFFFFFF)))
        } catch {}
        if ($ex -is [System.Windows.Markup.XamlParseException]) {
            if ($ex.LineNumber -gt 0 -or $ex.LinePosition -gt 0) {
                [void]$sb.AppendLine("XAML Line      : $($ex.LineNumber)")
                [void]$sb.AppendLine("XAML Position  : $($ex.LinePosition)")
            }
            $snippet = Get-XamlSnippet -XamlText $XamlText -LineNumber $ex.LineNumber
            if ($snippet) {
                [void]$sb.AppendLine("")
                [void]$sb.AppendLine("XAML Context:")
                [void]$sb.AppendLine($snippet)
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($ex.StackTrace)) {
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("StackTrace:")
            [void]$sb.AppendLine($ex.StackTrace)
        }
        [void]$sb.AppendLine("")
        $ex = $ex.InnerException
        $idx++
    }
    return $sb.ToString()
}

function Show-FatalError {
    param(
        [string]$Title = "Fatal Error",
        [string]$Context,
        [System.Exception]$Exception,
        [string]$XamlText
    )
    $report = New-Object System.Text.StringBuilder
    if (-not [string]::IsNullOrWhiteSpace($Context)) {
        [void]$report.AppendLine($Context)
        [void]$report.AppendLine("")
    }
    if ($null -ne $Exception) {
        [void]$report.AppendLine((Get-ExceptionReport -Exception $Exception -XamlText $XamlText))
    } else {
        [void]$report.AppendLine("No exception details were available.")
    }
    $fullText    = $report.ToString()
    $logPath     = Join-Path $env:TEMP "PS_CMTraceViewer_FatalError.txt"
    try { [System.IO.File]::WriteAllText($logPath, $fullText, [System.Text.Encoding]::UTF8) } catch {}
    $displayText = $fullText + "`r`n`r`nA copy was written to:`r`n$logPath"
    try {
        [System.Windows.MessageBox]::Show(
            $displayText, $Title,
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error) | Out-Null
        return
    } catch {}
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        [System.Windows.Forms.MessageBox]::Show(
            $displayText, $Title,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        return
    } catch {}
    Write-Host $displayText -ForegroundColor Red
}

function New-XamlWindow {
    param(
        [Parameter(Mandatory)][string]$XamlText,
        [string]$Context = "XAML Window"
    )
    $stringReader = $null
    $xmlReader    = $null
    try {
        $settings               = [System.Xml.XmlReaderSettings]::new()
        $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
        $stringReader           = [System.IO.StringReader]::new($XamlText)
        $xmlReader              = [System.Xml.XmlReader]::Create($stringReader, $settings)
        $window                 = [Windows.Markup.XamlReader]::Load($xmlReader)
        if ($null -eq $window) { throw [System.Exception]::new("XamlReader.Load returned null.") }
        return $window
    } catch {
        Show-FatalError -Title "$Context failed to load" `
                        -Context "$Context could not be created." `
                        -Exception $_.Exception `
                        -XamlText $XamlText
        return $null
    } finally {
        if ($null -ne $xmlReader)    { $xmlReader.Dispose() }
        if ($null -ne $stringReader) { $stringReader.Dispose() }
    }
}

function Get-RequiredNamedControl {
    param(
        [Parameter(Mandatory)]$Root,
        [Parameter(Mandatory)][string]$Name,
        [string]$Context = "Window"
    )
    $obj = $Root.FindName($Name)
    if ($null -eq $obj) {
        throw "Required control '$Name' was not found in $Context."
    }
    return $obj
}

#endregion

#region --- C# Type Definitions ---

if (-not ("LogParser" -as [type])) {
    Add-Type @"
using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Collections.Specialized;
using System.ComponentModel;

public static class LogLevels {
    public const string Error   = "Error";
    public const string Warning = "Warn";
    public const string Info    = "Info";
    public const string Verbose = "Verbose";
}

public static class FilterTags {
    public const string All = "__ALL__";
}

public class KeywordItem : INotifyPropertyChanged {
    private string _key;
    private string _value;

    public string Key {
        get { return _key; }
        set { if (_key != value) { _key = value; OnPropertyChanged("Key"); } }
    }

    public string Value {
        get { return _value; }
        set { if (_value != value) { _value = value; OnPropertyChanged("Value"); } }
    }

    public event PropertyChangedEventHandler PropertyChanged;
    protected void OnPropertyChanged(string name) {
        var h = PropertyChanged;
        if (h != null) h(this, new PropertyChangedEventArgs(name));
    }
}

public class LogEntry : INotifyPropertyChanged {
    private string _message;
    private string _rawMsg;
    private string _level;
    private string _typeVal;

    public string Message {
        get { return _message; }
        set { if (_message != value) { _message = value; OnPropertyChanged("Message"); } }
    }

    public string RawMsg {
        get { return _rawMsg; }
        set { if (_rawMsg != value) { _rawMsg = value; OnPropertyChanged("RawMsg"); } }
    }

    public string Level {
        get { return _level; }
        set { if (_level != value) { _level = value; OnPropertyChanged("Level"); } }
    }

    public string TypeVal {
        get { return _typeVal; }
        set { if (_typeVal != value) { _typeVal = value; OnPropertyChanged("TypeVal"); } }
    }

    public event PropertyChangedEventHandler PropertyChanged;
    protected void OnPropertyChanged(string name) {
        var h = PropertyChanged;
        if (h != null) h(this, new PropertyChangedEventArgs(name));
    }
}

public class LevelCount {
    public string Level      { get; set; }
    public int    Count      { get; set; }
    public double Percentage { get; set; }
}

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

public class SharedLogState : MarshalByRefObject {
    public long LastFileLength;
    public string PendingBuffer = "";
    public bool InitialLoadComplete;
    public bool IsFlushingInitialQueue = true;
    public string LastError;
    public readonly object SyncRoot = new object();
}

public static class LogParser {

    private const int MaxLineLength = 1048576;

    private static string DetermineLevel(
        string rawMsg,
        string typeVal,
        List<KeyValuePair<string, string>> orderedKeywords)
    {
        foreach (var kw in orderedKeywords) {
            if (rawMsg.IndexOf(kw.Key, StringComparison.OrdinalIgnoreCase) >= 0) {
                return kw.Key;
            }
        }
        if      (typeVal == "3") return LogLevels.Error;
        else if (typeVal == "2") return LogLevels.Warning;
        else if (typeVal == "1") return LogLevels.Info;
        return LogLevels.Info;
    }

    public static List<KeyValuePair<string, string>> BuildSortedKeywords(
        Dictionary<string, string> keywords)
    {
        var list = new List<KeyValuePair<string, string>>(keywords);
        list.Sort((a, b) => b.Key.Length.CompareTo(a.Key.Length));
        return list;
    }

    public static string ReEvaluateLevel(
        string rawMsg,
        string typeVal,
        List<KeyValuePair<string, string>> orderedKeywords)
    {
        return DetermineLevel(rawMsg, typeVal, orderedKeywords);
    }

    public static void ReEvaluateAll(
        List<LogEntry> entries,
        List<KeyValuePair<string, string>> orderedKeywords)
    {
        for (int i = 0; i < entries.Count; i++) {
            entries[i].Level = DetermineLevel(
                entries[i].RawMsg, entries[i].TypeVal, orderedKeywords);
        }
    }

    public static List<LogEntry> FilterEntries(
        List<LogEntry> entries,
        Dictionary<string, bool> activeFilter)
    {
        var result = new List<LogEntry>(entries.Count);
        foreach (var e in entries) {
            bool visible;
            if (!activeFilter.TryGetValue(e.Level, out visible)) { visible = true; }
            if (visible) { result.Add(e); }
        }
        return result;
    }

    public static int FindNext(
        IList<LogEntry> items,
        string searchText,
        int startIndex)
    {
        if (items == null || items.Count == 0 || string.IsNullOrEmpty(searchText)) return -1;
        int count = items.Count;
        for (int i = startIndex; i < count; i++) {
            if (items[i] != null &&
                items[i].Message.IndexOf(searchText, StringComparison.OrdinalIgnoreCase) >= 0)
                return i;
        }
        for (int i = 0; i < startIndex && i < count; i++) {
            if (items[i] != null &&
                items[i].Message.IndexOf(searchText, StringComparison.OrdinalIgnoreCase) >= 0)
                return i;
        }
        return -1;
    }

    public static List<LevelCount> GetLevelStatistics(IList<LogEntry> items) {
        var result = new List<LevelCount>();
        if (items == null || items.Count == 0) return result;
        var counts = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        foreach (var e in items) {
            if (e == null || string.IsNullOrEmpty(e.Level)) continue;
            int c;
            if (!counts.TryGetValue(e.Level, out c)) c = 0;
            counts[e.Level] = c + 1;
        }
        int total = items.Count;
        var keys  = new List<string>(counts.Keys);
        keys.Sort(StringComparer.OrdinalIgnoreCase);
        foreach (var k in keys) {
            int cnt    = counts[k];
            double pct = (total > 0) ? (cnt * 100.0 / total) : 0.0;
            result.Add(new LevelCount { Level = k, Count = cnt, Percentage = pct });
        }
        return result;
    }

    public static LogEntry ParseLine(
        string line,
        List<KeyValuePair<string, string>> orderedKeywords)
    {
        if (line == null || line.Length > MaxLineLength) return null;

        if (line.StartsWith("<![LOG[", StringComparison.Ordinal) &&
            line.Contains("]LOG]!>"))
        {
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

            DateTime dt;
            bool parsed = DateTime.TryParse(
                dateStr + " " + cleanTime,
                System.Globalization.CultureInfo.InvariantCulture,
                System.Globalization.DateTimeStyles.None,
                out dt);
            if (!parsed) dt = DateTime.MinValue;

            string level     = DetermineLevel(rawMsg, typeVal, orderedKeywords);
            string timestamp = (dt == DateTime.MinValue)
                ? "[??:??:??.???]"
                : "[" + dt.ToString("HH:mm:ss.fff") + "]";

            return new LogEntry {
                Message = timestamp + " " + rawMsg,
                RawMsg  = rawMsg,
                Level   = level,
                TypeVal = typeVal
            };
        }
        else {
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

#endregion

#region --- Named Constants ---

$script:MaxDrainPerTick     = 25000
$script:PollIntervalMs      = 500
$script:InitialCapacity     = 50000
$script:FastTimerIntervalMs = 100
$script:MaxRetainedEntries  = 100000
$script:TrimThreshold       = [int]($script:MaxRetainedEntries * 1.1)
$script:MinFontSize         = 6
$script:MaxFontSize         = 72
$script:MinUpdateSpeed      = 1
$script:MaxUpdateSpeed      = 60
$script:MinWindowWidth      = 400
$script:MaxWindowWidth      = 7680
$script:MinWindowHeight     = 300
$script:MaxWindowHeight     = 4320
$script:SearchPausedSuffix  = " [Searching - tailing paused]"
$script:MaxKeywordCount     = 100
$script:RunspaceShutdownMs  = 2000
$script:MaxErrorLogEntries  = 500
$script:JsonFormatDepth     = 50
$script:MaxIniLineLength    = 4096
$script:MaxJsonFormatLength = 100000

$script:SortColumns    = @("Type", "Count", "Percentage")
$script:SortDirections = @("Ascending", "Descending")

#endregion

#region --- Operational Error Log ---

$script:ErrorLog = New-Object System.Collections.Generic.List[string]

function Write-OperationalError {
    param(
        [string]$Context,
        [string]$Message
    )
    $entry  = "[$(Get-Date -Format 'HH:mm:ss')] $Context : $Message"
    $script:ErrorLog.Add($entry)
    $excess = $script:ErrorLog.Count - $script:MaxErrorLogEntries
    if ($excess -gt 0) { $script:ErrorLog.RemoveRange(0, $excess) }
}

function Report-Error {
    param(
        [string]$Context,
        [string]$Message,
        [switch]$ShowDialog,
        [System.Windows.MessageBoxImage]$Icon = [System.Windows.MessageBoxImage]::Warning
    )
    Write-OperationalError -Context $Context -Message $Message
    if ($ShowDialog) {
        try {
            [System.Windows.MessageBox]::Show(
                $Message, $Context,
                [System.Windows.MessageBoxButton]::OK,
                $Icon) | Out-Null
        } catch {
            Write-OperationalError "Report-Error" "Could not show dialog: $_"
        }
    }
}

#endregion

#region --- Colour Map (plain Hashtable - OrderedDictionary lacks ContainsKey) ---

$script:ColorMap = @{
    "Red"    = "#FFFFCDD2"
    "Orange" = "#FFFFE0B2"
    "Yellow" = "#FFFFF9C4"
    "Green"  = "#FFC8E6C9"
    "Blue"   = "#FFE1F5FE"
    "Purple" = "#FFE1BEE7"
    "White"  = "#FFFFFFFF"
}

$script:TextColorMap = @{
    "Red"    = "#FFD32F2F"
    "Orange" = "#FFF57C00"
    "Yellow" = "#FFF9A825"
    "Green"  = "#FF388E3C"
    "Blue"   = "#FF1976D2"
    "Purple" = "#FF7B1FA2"
    "White"  = "#FF424242"
}

$script:ReverseColorMap = @{}
foreach ($k in $script:ColorMap.Keys) {
    $script:ReverseColorMap[$script:ColorMap[$k]] = $k
}

#endregion

#region --- Utility Helpers ---

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
            if ($child -is [System.Windows.Media.Visual]) { $queue.Enqueue($child) }
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

function Set-TimerInterval {
    param([TimeSpan]$Interval)
    $sb = {
        param($iv)
        $script:RefreshTimer.Stop()
        $script:RefreshTimer.Interval = $iv
        $script:RefreshTimer.Start()
    }
    if ($null -ne $script:MainWindow -and -not $script:MainWindow.Dispatcher.CheckAccess()) {
        $script:MainWindow.Dispatcher.Invoke($sb, $Interval)
    } else {
        & $sb $Interval
    }
}

function Get-SortedKeywords {
    $dict = New-Object 'System.Collections.Generic.Dictionary[string,string]'
    foreach ($kv in $script:Config.Keywords.GetEnumerator()) {
        $dict[$kv.Key] = $kv.Value
    }
    return [LogParser]::BuildSortedKeywords($dict)
}

function Copy-ToClipboard {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return }
    $retries = 3
    for ($i = 0; $i -lt $retries; $i++) {
        try {
            [System.Windows.Clipboard]::SetText($Text)
            return
        } catch [System.Runtime.InteropServices.ExternalException] {
            if ($i -eq $retries - 1) {
                Report-Error "Copy-ToClipboard" "Failed after $retries attempts: $_"
            } else {
                Start-Sleep -Milliseconds 100
            }
        } catch {
            Report-Error "Copy-ToClipboard" "Unexpected clipboard error: $_"
            return
        }
    }
}

$script:BrushCache = New-Object 'System.Collections.Generic.Dictionary[string,System.Windows.Media.SolidColorBrush]'

function Get-CachedBrush {
    param([string]$Hex)
    $brush = $null
    if (-not $script:BrushCache.TryGetValue($Hex, [ref]$brush)) {
        try {
            $brush = New-Object System.Windows.Media.SolidColorBrush(
                [System.Windows.Media.ColorConverter]::ConvertFromString($Hex))
            $brush.Freeze()
            $script:BrushCache[$Hex] = $brush
        } catch {
            Report-Error "Get-CachedBrush" "Cannot create brush for '$Hex': $_"
            $brush = [System.Windows.Media.Brushes]::White
        }
    }
    return $brush
}

function Clear-BrushCache {
    $script:BrushCache.Clear()
}

function Test-ColorMapKey {
    param([string]$Key)
    return $script:ColorMap.ContainsKey($Key)
}

function Test-TextColorMapKey {
    param([string]$Key)
    return $script:TextColorMap.ContainsKey($Key)
}

#endregion

#region --- Configuration & INI Management ---

$script:ConfigPath = "$env:APPDATA\PS_CMTraceViewer.ini"

function Get-DefaultConfig {
    return @{
        FontFamily         = "Consolas"
        FontSize           = 12
        BottomPanelHeight  = 250
        FormatJson         = $true
        SplitComma         = $true
        SplitSpace         = $false
        SplitPeriod        = $false
        CustomDelimiters   = @()
        UpdateSpeed        = 3
        LastLogFile        = ""
        WindowWidth        = 1200
        WindowHeight       = 700
        StatsSortColumn    = "Count"
        StatsSortDirection = "Ascending"
        Keywords           = @{
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
        FontFamily         = $defaults.FontFamily
        FontSize           = $defaults.FontSize
        BottomPanelHeight  = $defaults.BottomPanelHeight
        FormatJson         = $defaults.FormatJson
        SplitComma         = $defaults.SplitComma
        SplitSpace         = $defaults.SplitSpace
        SplitPeriod        = $defaults.SplitPeriod
        UpdateSpeed        = $defaults.UpdateSpeed
        LastLogFile        = ""
        WindowWidth        = $defaults.WindowWidth
        WindowHeight       = $defaults.WindowHeight
        StatsSortColumn    = $defaults.StatsSortColumn
        StatsSortDirection = $defaults.StatsSortDirection
    }

    foreach ($line in [System.IO.File]::ReadLines($script:ConfigPath, [System.Text.Encoding]::UTF8)) {
        if ($line.Length -gt $script:MaxIniLineLength) { continue }
        $trimLine = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimLine)) { continue }

        if ($trimLine -match '^\[(.+)\]$') {
            $section = $matches[1]
            continue
        }

        $eqIndex = $trimLine.IndexOf('=')
        if ($eqIndex -lt 0) { continue }
        $key = $trimLine.Substring(0, $eqIndex).Trim()
        if ([string]::IsNullOrWhiteSpace($key)) { continue }
        $val = $trimLine.Substring($eqIndex + 1).Trim()

        if ($section -eq "Settings") {
            if ($settings.ContainsKey($key)) { $settings[$key] = $val }
        } elseif ($section -eq "Keywords") {
            if ($script:ReverseColorMap.ContainsKey($val)) {
                $val = $script:ReverseColorMap[$val]
            }
            if (-not (Test-ColorMapKey $val)) {
                Report-Error "Import-Config" "Unknown colour '$val' for keyword '$key' - defaulting to White."
                $val = "White"
            }
            if (-not [string]::IsNullOrWhiteSpace($key)) {
                if ($kw.Count -lt $script:MaxKeywordCount) {
                    $kw[$key] = $val
                } else {
                    Report-Error "Import-Config" "Keyword limit ($($script:MaxKeywordCount)) reached - '$key' ignored."
                }
            }
        } elseif ($section -eq "Delimiters") {
            if (-not [string]::IsNullOrWhiteSpace($val)) { $delims += $val }
        }
    }

    $script:Config.FontFamily = if ($settings.ContainsKey("FontFamily") -and -not [string]::IsNullOrWhiteSpace($settings["FontFamily"])) {
        $settings["FontFamily"]
    } else { $defaults.FontFamily }

    try {
        $script:Config.FontSize = [Math]::Max($script:MinFontSize, [Math]::Min($script:MaxFontSize, [int]$settings["FontSize"]))
    } catch { $script:Config.FontSize = $defaults.FontSize }

    try {
        $script:Config.BottomPanelHeight = [Math]::Max(80, [int]$settings["BottomPanelHeight"])
    } catch { $script:Config.BottomPanelHeight = $defaults.BottomPanelHeight }

    $script:Config.FormatJson  = ($settings["FormatJson"]  -eq "True")
    $script:Config.SplitComma  = ($settings["SplitComma"]  -eq "True")
    $script:Config.SplitSpace  = ($settings["SplitSpace"]  -eq "True")
    $script:Config.SplitPeriod = ($settings["SplitPeriod"] -eq "True")

    try {
        $script:Config.UpdateSpeed = [Math]::Max($script:MinUpdateSpeed, [Math]::Min($script:MaxUpdateSpeed, [int]$settings["UpdateSpeed"]))
    } catch { $script:Config.UpdateSpeed = $defaults.UpdateSpeed }

    $script:Config.LastLogFile = if ($settings.ContainsKey("LastLogFile") -and -not [string]::IsNullOrWhiteSpace($settings["LastLogFile"])) {
        $settings["LastLogFile"]
    } else { "" }

    try {
        $script:Config.WindowWidth = [Math]::Max($script:MinWindowWidth, [Math]::Min($script:MaxWindowWidth, [int]$settings["WindowWidth"]))
    } catch { $script:Config.WindowWidth = $defaults.WindowWidth }

    try {
        $script:Config.WindowHeight = [Math]::Max($script:MinWindowHeight, [Math]::Min($script:MaxWindowHeight, [int]$settings["WindowHeight"]))
    } catch { $script:Config.WindowHeight = $defaults.WindowHeight }

    $script:Config.StatsSortColumn = if ($settings.ContainsKey("StatsSortColumn") -and $script:SortColumns -contains $settings["StatsSortColumn"]) {
        $settings["StatsSortColumn"]
    } else { $defaults.StatsSortColumn }

    $script:Config.StatsSortDirection = if ($settings.ContainsKey("StatsSortDirection") -and $script:SortDirections -contains $settings["StatsSortDirection"]) {
        $settings["StatsSortDirection"]
    } else { $defaults.StatsSortDirection }

    if ($kw.Count     -gt 0) { $script:Config.Keywords         = $kw }
    if ($delims.Count -gt 0) { $script:Config.CustomDelimiters = $delims }
}

function Export-Config {
    try {
        $safeFontFamily  = ($script:Config.FontFamily  -replace '[\r\n]', '')
        $safeLastLogFile = ($script:Config.LastLogFile -replace '[\r\n]', '')
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add("[Settings]")
        $lines.Add("FontFamily=$safeFontFamily")
        $lines.Add("FontSize=$($script:Config.FontSize)")
        $lines.Add("BottomPanelHeight=$($script:Config.BottomPanelHeight)")
        $lines.Add("FormatJson=$($script:Config.FormatJson)")
        $lines.Add("SplitComma=$($script:Config.SplitComma)")
        $lines.Add("SplitSpace=$($script:Config.SplitSpace)")
        $lines.Add("SplitPeriod=$($script:Config.SplitPeriod)")
        $lines.Add("UpdateSpeed=$($script:Config.UpdateSpeed)")
        $lines.Add("LastLogFile=$safeLastLogFile")
        $lines.Add("WindowWidth=$($script:Config.WindowWidth)")
        $lines.Add("WindowHeight=$($script:Config.WindowHeight)")
        $lines.Add("StatsSortColumn=$($script:Config.StatsSortColumn)")
        $lines.Add("StatsSortDirection=$($script:Config.StatsSortDirection)")
        $lines.Add("")
        $lines.Add("[Keywords]")
        foreach ($kv in $script:Config.Keywords.GetEnumerator()) {
            $safeKey = ($kv.Key   -replace '[\r\n]', '')
            $safeVal = ($kv.Value -replace '[\r\n]', '')
            $lines.Add("$safeKey=$safeVal")
        }
        $lines.Add("")
        $lines.Add("[Delimiters]")
        $i = 1
        foreach ($d in $script:Config.CustomDelimiters) {
            $safeDelim = ($d -replace '[\r\n]', '')
            $lines.Add("$i=$safeDelim")
            $i++
        }
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllLines($script:ConfigPath, $lines, $utf8NoBom)
    } catch {
        Report-Error "Export-Config" "Failed to save settings: $_" -ShowDialog -Icon ([System.Windows.MessageBoxImage]::Error)
    }
}

Import-Config

#endregion

#region --- Background Runspace Script ---

$bgScript = {
    param(
        [string]$FilePath,
        [System.Collections.Generic.List[System.Collections.Generic.KeyValuePair[string,string]]] $OrderedKeywords,
        [System.Collections.Concurrent.ConcurrentQueue[object]] $LogQueue,
        [System.Threading.CancellationToken] $CancellationToken,
        [SharedLogState] $SharedState,
        [int] $PollIntervalMs
    )

    $lastFileLength    = $SharedState.LastFileLength
    $pendingBuffer     = $SharedState.PendingBuffer
    $buffer            = New-Object System.Text.StringBuilder
    $consecutiveErrors = 0
    $maxBackoffMs      = 30000

    while (-not $CancellationToken.IsCancellationRequested) {
        $reader = $null
        $stream = $null
        try {
            $fileInfo = [System.IO.FileInfo]::new($FilePath)
            $fileInfo.Refresh()

            if (-not $fileInfo.Exists) {
                [void]$CancellationToken.WaitHandle.WaitOne($PollIntervalMs)
                continue
            }

            $currentLength = $fileInfo.Length

            if ($currentLength -lt $lastFileLength) {
                $lastFileLength = 0
                $pendingBuffer  = ""
                [void]$buffer.Clear()
            }

            if ($currentLength -gt $lastFileLength) {
                $stream = [System.IO.File]::Open(
                    $FilePath,
                    [System.IO.FileMode]::Open,
                    [System.IO.FileAccess]::Read,
                    [System.IO.FileShare]::ReadWrite)

                try {
                    $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $true)
                    $stream = $null
                } catch {
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
                        $entry = [LogParser]::ParseLine($buffer.ToString(), $OrderedKeywords)
                        if ($null -ne $entry) { $LogQueue.Enqueue($entry) }
                        [void]$buffer.Clear()
                        [void]$buffer.Append($line)
                    } elseif ($line.StartsWith('<![LOG[')) {
                        [void]$buffer.Clear()
                        [void]$buffer.Append($line)
                    } elseif ($buffer.Length -gt 0) {
                        [void]$buffer.AppendLine($line)
                    } else {
                        $entry = [LogParser]::ParseLine($line, $OrderedKeywords)
                        if ($null -ne $entry) { $LogQueue.Enqueue($entry) }
                    }
                }

                if ($buffer.Length -gt 0) {
                    $bufferStr = $buffer.ToString()
                    if ($bufferStr.StartsWith('<![LOG[') -and -not $bufferStr.Contains("]LOG]!>")) {
                        $pendingBuffer = $bufferStr
                    } else {
                        $entry = [LogParser]::ParseLine($bufferStr, $OrderedKeywords)
                        if ($null -ne $entry) { $LogQueue.Enqueue($entry) }
                        $pendingBuffer = ""
                    }
                }

                [System.Threading.Monitor]::Enter($SharedState.SyncRoot)
                try {
                    $SharedState.LastFileLength = $lastFileLength
                    $SharedState.PendingBuffer  = $pendingBuffer
                    if (-not $SharedState.InitialLoadComplete) {
                        $SharedState.InitialLoadComplete = $true
                    }
                } finally {
                    [System.Threading.Monitor]::Exit($SharedState.SyncRoot)
                }

                $consecutiveErrors = 0
            }
        } catch [System.IO.IOException] {
            $consecutiveErrors++
            $backoffMs = [Math]::Min($PollIntervalMs * [Math]::Pow(2, $consecutiveErrors), $maxBackoffMs)
            [System.Threading.Monitor]::Enter($SharedState.SyncRoot)
            try {
                $SharedState.LastError = "IO error ($consecutiveErrors) at $(Get-Date -Format 'HH:mm:ss') on '$FilePath': $_"
            } finally {
                [System.Threading.Monitor]::Exit($SharedState.SyncRoot)
            }
            [void]$CancellationToken.WaitHandle.WaitOne([int]$backoffMs)
            continue
        } catch {
            $consecutiveErrors++
            $backoffMs = [Math]::Min($PollIntervalMs * [Math]::Pow(2, $consecutiveErrors), $maxBackoffMs)
            [System.Threading.Monitor]::Enter($SharedState.SyncRoot)
            try {
                $SharedState.LastError = "Unexpected error ($consecutiveErrors) at $(Get-Date -Format 'HH:mm:ss'): $_"
            } finally {
                [System.Threading.Monitor]::Exit($SharedState.SyncRoot)
            }
            [void]$CancellationToken.WaitHandle.WaitOne([int]$backoffMs)
            continue
        } finally {
            if ($null -ne $reader) { $reader.Dispose(); $reader = $null }
            if ($null -ne $stream) { $stream.Dispose(); $stream = $null }
        }

        [void]$CancellationToken.WaitHandle.WaitOne($PollIntervalMs)
    }
}

#endregion

#region --- Main Window XAML ---

$script:MainXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:sys="clr-namespace:System;assembly=mscorlib"
        Title="Configuration Manager Trace Log Tool"
        Height="$($script:Config.WindowHeight)"
        Width="$($script:Config.WindowWidth)"
        WindowStartupLocation="CenterScreen">
    <Window.Resources>
        <Style TargetType="DataGridCell">
            <Setter Property="Background"       Value="Transparent"/>
            <Setter Property="BorderBrush"      Value="Transparent"/>
            <Setter Property="FocusVisualStyle"  Value="{x:Null}"/>
            <Setter Property="Foreground" Value="{Binding RelativeSource={RelativeSource AncestorType=DataGridRow}, Path=Foreground}"/>
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
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <Grid Grid.Column="0">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*" MinHeight="100"/>
                <RowDefinition Height="5"/>
                <RowDefinition x:Name="BottomRowDef" Height="$($script:Config.BottomPanelHeight)" MinHeight="80"/>
            </Grid.RowDefinitions>
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
            <Border Grid.Row="2" Background="#FFE8E8E8" BorderBrush="#FFD0D0D0" BorderThickness="0,1,0,1" Padding="4,3,4,3">
                <DockPanel>
                    <TextBlock Text="Filter:" FontWeight="Bold" VerticalAlignment="Center" Margin="2,0,6,0" DockPanel.Dock="Left"/>
                    <WrapPanel Name="FilterPanel" Orientation="Horizontal" VerticalAlignment="Center"/>
                </DockPanel>
            </Border>
            <Grid Grid.Row="3">
                <DataGrid Name="LogDataGrid"
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
                    <DataGrid.ContextMenu>
                        <ContextMenu>
                            <MenuItem Header="Copy to Clipboard" Name="ContextCopyMenu"/>
                        </ContextMenu>
                    </DataGrid.ContextMenu>
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
                <Grid Name="OpenLogOverlay" Background="White" Panel.ZIndex="10" Visibility="Visible">
                    <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center" Orientation="Vertical">
                        <TextBlock Text="Click here to open a log file"
                                   FontSize="18" FontWeight="SemiBold" Foreground="#FF555555"
                                   HorizontalAlignment="Center" Margin="0,0,0,16"/>
                        <Button Name="OpenLogOverlayBtn" Content="Open Log File" FontSize="14" HorizontalAlignment="Center">
                            <Button.Style>
                                <Style TargetType="Button">
                                    <Setter Property="Background"       Value="#FF1976D2"/>
                                    <Setter Property="Foreground"       Value="White"/>
                                    <Setter Property="BorderThickness"  Value="0"/>
                                    <Setter Property="Padding"          Value="24,10,24,10"/>
                                    <Setter Property="FontSize"         Value="14"/>
                                    <Setter Property="Cursor"           Value="Hand"/>
                                    <Setter Property="Template">
                                        <Setter.Value>
                                            <ControlTemplate TargetType="Button">
                                                <Border Name="Bd"
                                                        Background="{TemplateBinding Background}"
                                                        CornerRadius="4"
                                                        Padding="{TemplateBinding Padding}">
                                                    <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                                </Border>
                                                <ControlTemplate.Triggers>
                                                    <Trigger Property="IsMouseOver" Value="True">
                                                        <Setter TargetName="Bd" Property="Background" Value="#FF1565C0"/>
                                                    </Trigger>
                                                    <Trigger Property="IsPressed" Value="True">
                                                        <Setter TargetName="Bd" Property="Background" Value="#FF0D47A1"/>
                                                    </Trigger>
                                                </ControlTemplate.Triggers>
                                            </ControlTemplate>
                                        </Setter.Value>
                                    </Setter>
                                </Style>
                            </Button.Style>
                        </Button>
                    </StackPanel>
                </Grid>
            </Grid>
            <GridSplitter Grid.Row="4" Height="5" HorizontalAlignment="Stretch" Background="#FFD0D0D0" ResizeDirection="Rows" ResizeBehavior="PreviousAndNext"/>
            <Grid Grid.Row="5">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                </Grid.RowDefinitions>
                <Border Grid.Row="0" Background="#FFE8E8E8" BorderBrush="#FFD0D0D0" BorderThickness="1,0,1,1" Padding="5,3,5,3">
                    <DockPanel>
                        <Button Name="CopyDetailBtn" Content="Copy to Clipboard" DockPanel.Dock="Right" Padding="10,2,10,2"/>
                        <TextBlock Text="Details" FontWeight="Bold" VerticalAlignment="Center"/>
                    </DockPanel>
                </Border>
                <TextBox Grid.Row="1" Name="DetailTextBox"
                         IsReadOnly="True"
                         Background="#FFF8F8F8"
                         BorderThickness="1,0,1,1" BorderBrush="#FFD0D0D0"
                         VerticalScrollBarVisibility="Auto"
                         HorizontalScrollBarVisibility="Auto"
                         TextWrapping="Wrap"
                         Padding="5,5,5,5"/>
            </Grid>
        </Grid>
        <Border Grid.Column="1" Background="#FFF8F8F8" BorderBrush="#FFD0D0D0" BorderThickness="1,0,0,0" MinWidth="220" MaxWidth="280">
            <DockPanel Margin="0">
                <Border DockPanel.Dock="Top" Background="#FFE0E0E0" BorderBrush="#FFD0D0D0" BorderThickness="0,0,0,1" Padding="8,6,8,6">
                    <TextBlock Text="Log Statistics" FontWeight="Bold" FontSize="12"/>
                </Border>
                <Border DockPanel.Dock="Top" Background="#FFF0F0F0" BorderBrush="#FFD0D0D0" BorderThickness="0,0,0,1" Padding="0">
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="65"/>
                            <ColumnDefinition Width="55"/>
                        </Grid.ColumnDefinitions>
                        <Button Grid.Column="0" Name="SortTypeBtn"  Content="Type"  HorizontalContentAlignment="Left"  Background="Transparent" BorderThickness="0" Padding="8,6,4,6" Cursor="Hand"/>
                        <Button Grid.Column="1" Name="SortCountBtn" Content="Count" HorizontalContentAlignment="Right" Background="Transparent" BorderThickness="0" Padding="4,6,4,6" Cursor="Hand"/>
                        <Button Grid.Column="2" Name="SortPctBtn"   Content="%"     HorizontalContentAlignment="Right" Background="Transparent" BorderThickness="0" Padding="4,6,8,6" Cursor="Hand"/>
                    </Grid>
                </Border>
                <Border DockPanel.Dock="Bottom" Background="#FFE8E8E8" BorderBrush="#FFD0D0D0" BorderThickness="0,1,0,0" Padding="8,6,8,6">
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="65"/>
                            <ColumnDefinition Width="55"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Grid.Column="0" Text="Total" FontWeight="Bold"/>
                        <TextBlock Grid.Column="1" Name="TotalCountText" Text="0" FontWeight="Bold" TextAlignment="Right"/>
                        <TextBlock Grid.Column="2" Text="100%" FontWeight="Bold" TextAlignment="Right" Foreground="#FF888888"/>
                    </Grid>
                </Border>
                <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                    <StackPanel Name="StatsPanel" Margin="0"/>
                </ScrollViewer>
            </DockPanel>
        </Border>
    </Grid>
</Window>
"@

#endregion

#region --- Create Main Window and Resolve Named Controls ---

try {
    $script:MainWindow = New-XamlWindow -XamlText $script:MainXaml -Context "Main window"
    if ($null -eq $script:MainWindow) { return }

    $OpenMenu          = Get-RequiredNamedControl $script:MainWindow "OpenMenu"          "Main window"
    $ExitMenu          = Get-RequiredNamedControl $script:MainWindow "ExitMenu"          "Main window"
    $FindMenu          = Get-RequiredNamedControl $script:MainWindow "FindMenu"          "Main window"
    $SettingsMenu      = Get-RequiredNamedControl $script:MainWindow "SettingsMenu"      "Main window"
    $ErrorLogMenu      = Get-RequiredNamedControl $script:MainWindow "ErrorLogMenu"      "Main window"
    $LogDataGrid       = Get-RequiredNamedControl $script:MainWindow "LogDataGrid"       "Main window"
    $DetailTextBox     = Get-RequiredNamedControl $script:MainWindow "DetailTextBox"     "Main window"
    $CopyDetailBtn     = Get-RequiredNamedControl $script:MainWindow "CopyDetailBtn"     "Main window"
    $PauseBtn          = Get-RequiredNamedControl $script:MainWindow "PauseBtn"          "Main window"
    $ScrollBtn         = Get-RequiredNamedControl $script:MainWindow "ScrollBtn"         "Main window"
    $SearchBox         = Get-RequiredNamedControl $script:MainWindow "SearchBox"         "Main window"
    $SearchBtn         = Get-RequiredNamedControl $script:MainWindow "SearchBtn"         "Main window"
    $ClearSearchBtn    = Get-RequiredNamedControl $script:MainWindow "ClearSearchBtn"    "Main window"
    $FilterPanel       = Get-RequiredNamedControl $script:MainWindow "FilterPanel"       "Main window"
    $TotalCountText    = Get-RequiredNamedControl $script:MainWindow "TotalCountText"    "Main window"
    $StatsPanel        = Get-RequiredNamedControl $script:MainWindow "StatsPanel"        "Main window"
    $SortTypeBtn       = Get-RequiredNamedControl $script:MainWindow "SortTypeBtn"       "Main window"
    $SortCountBtn      = Get-RequiredNamedControl $script:MainWindow "SortCountBtn"      "Main window"
    $SortPctBtn        = Get-RequiredNamedControl $script:MainWindow "SortPctBtn"        "Main window"
    $ContextCopyMenu   = Get-RequiredNamedControl $script:MainWindow "ContextCopyMenu"   "Main window"
    $OpenLogOverlay    = Get-RequiredNamedControl $script:MainWindow "OpenLogOverlay"    "Main window"
    $OpenLogOverlayBtn = Get-RequiredNamedControl $script:MainWindow "OpenLogOverlayBtn" "Main window"

    $BottomRow = $script:MainWindow.FindName("BottomRowDef")
    if ($null -eq $BottomRow) {
        Report-Error "Init" "Could not resolve BottomRowDef - bottom panel height will not persist."
    }
} catch {
    Show-FatalError -Title "Unhandled Startup error" -Context "Startup failed." -Exception $_.Exception
    return
}

#endregion

#region --- Global Runtime State ---

$script:State = @{
    CurrentLogFile    = $null
    Cts               = $null
    RunspacePS        = $null
    RunspaceObj       = $null
    AsyncResult       = $null
    LogQueue          = $null
    SharedState       = $null
    MasterList        = New-Object System.Collections.Generic.List[LogEntry]($script:InitialCapacity)
    DisplayCollection = New-Object ObservableRangeCollection[LogEntry]
    FilterCheckboxes  = @{}
    ActiveLevelFilter = @{}
    StatsRowCache     = New-Object 'System.Collections.Generic.Dictionary[string,hashtable]'(
        [System.StringComparer]::OrdinalIgnoreCase)
    WasTailingBeforeSearch = $false
}

#endregion

#region --- Stats Panel ---

function Update-SortButtonLabels {
    $col   = $script:Config.StatsSortColumn
    $dir   = $script:Config.StatsSortDirection
    $arrow = if ($dir -eq "Ascending") { " ^" } else { " v" }
    $SortTypeBtn.Content  = if ($col -eq "Type")       { "Type$arrow" }  else { "Type" }
    $SortCountBtn.Content = if ($col -eq "Count")      { "Count$arrow" } else { "Count" }
    $SortPctBtn.Content   = if ($col -eq "Percentage") { "%$arrow" }     else { "%" }
}

function Get-SortedStats {
    param([System.Collections.Generic.List[LevelCount]]$Stats)
    if ($null -eq $Stats -or $Stats.Count -eq 0) { return $Stats }
    $col = $script:Config.StatsSortColumn
    $dir = $script:Config.StatsSortDirection
    if ($col -eq "Type") {
        if ($dir -eq "Ascending") { return $Stats | Sort-Object Level }
        else { return $Stats | Sort-Object Level -Descending }
    } elseif ($col -eq "Count") {
        if ($dir -eq "Ascending") { return $Stats | Sort-Object Count }
        else { return $Stats | Sort-Object Count -Descending }
    } elseif ($col -eq "Percentage") {
        if ($dir -eq "Ascending") { return $Stats | Sort-Object Percentage }
        else { return $Stats | Sort-Object Percentage -Descending }
    } else {
        return $Stats | Sort-Object Count
    }
}

function Set-StatsSort {
    param([string]$Column)
    if ($script:Config.StatsSortColumn -eq $Column) {
        if ($script:Config.StatsSortDirection -eq "Ascending") {
            $script:Config.StatsSortDirection = "Descending"
        } else {
            $script:Config.StatsSortDirection = "Ascending"
        }
    } else {
        $script:Config.StatsSortColumn    = $Column
        $script:Config.StatsSortDirection = "Ascending"
    }
    Update-SortButtonLabels
    Update-StatusBar
}

$SortTypeBtn.Add_Click({  Set-StatsSort -Column "Type" })
$SortCountBtn.Add_Click({ Set-StatsSort -Column "Count" })
$SortPctBtn.Add_Click({   Set-StatsSort -Column "Percentage" })

Update-SortButtonLabels

function Update-StatusBar {
    $masterList        = $script:State.MasterList
    $displayCollection = $script:State.DisplayCollection
    $cache             = $script:State.StatsRowCache

    $total = if ($null -ne $masterList) { $masterList.Count } else { 0 }
    if ($null -ne $TotalCountText) { $TotalCountText.Text = $total.ToString("N0") }
    if ($null -eq $StatsPanel) { return }

    $visible = if ($null -ne $displayCollection) { $displayCollection.Count } else { 0 }

    if ($visible -eq 0) {
        $StatsPanel.Children.Clear()
        $cache.Clear()
        return
    }

    $stats       = [LogParser]::GetLevelStatistics($displayCollection)
    $sortedStats = Get-SortedStats -Stats $stats

    $incomingLevels = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($s in $sortedStats) { [void]$incomingLevels.Add($s.Level) }

    $cacheKeys    = @($cache.Keys)
    $cacheChanged = $false
    foreach ($k in $cacheKeys) {
        if (-not $incomingLevels.Contains($k)) {
            $cache.Remove($k)
            $cacheChanged = $true
        }
    }
    foreach ($lvl in $incomingLevels) {
        if (-not $cache.ContainsKey($lvl)) { $cacheChanged = $true; break }
    }

    if ($cacheChanged) {
        $StatsPanel.Children.Clear()
        foreach ($stat in $sortedStats) {
            $lvl = $stat.Level
            if (-not $cache.ContainsKey($lvl)) {
                $colorName = $script:Config.Keywords[$lvl]
                $bgHex     = "#FFFFFFFF"
                $textHex   = "#FF424242"
                if ($colorName -and (Test-ColorMapKey $colorName)) {
                    $bgHex = $script:ColorMap[$colorName]
                    if (Test-TextColorMapKey $colorName) {
                        $textHex = $script:TextColorMap[$colorName]
                    }
                }
                $bgBrush   = Get-CachedBrush $bgHex
                $textBrush = Get-CachedBrush $textHex

                $rowBorder                 = New-Object System.Windows.Controls.Border
                $rowBorder.BorderBrush     = [System.Windows.Media.Brushes]::LightGray
                $rowBorder.BorderThickness = "0,0,0,1"
                $rowBorder.Padding         = "8,5,8,5"

                $rowGrid = New-Object System.Windows.Controls.Grid
                $c0 = New-Object System.Windows.Controls.ColumnDefinition
                $c0.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
                $c1 = New-Object System.Windows.Controls.ColumnDefinition
                $c1.Width = [System.Windows.GridLength]::new(65)
                $c2 = New-Object System.Windows.Controls.ColumnDefinition
                $c2.Width = [System.Windows.GridLength]::new(55)
                [void]$rowGrid.ColumnDefinitions.Add($c0)
                [void]$rowGrid.ColumnDefinitions.Add($c1)
                [void]$rowGrid.ColumnDefinitions.Add($c2)

                $typeBorder                     = New-Object System.Windows.Controls.Border
                $typeBorder.Background          = $bgBrush
                $typeBorder.CornerRadius        = "3"
                $typeBorder.Padding             = "6,2,6,2"
                $typeBorder.HorizontalAlignment = "Left"
                $typeBorder.VerticalAlignment   = "Center"

                $typeText            = New-Object System.Windows.Controls.TextBlock
                $typeText.Text       = $lvl
                $typeText.FontWeight = "SemiBold"
                $typeText.Foreground = $textBrush
                $typeText.FontSize   = 11

                $typeBorder.Child = $typeText
                [System.Windows.Controls.Grid]::SetColumn($typeBorder, 0)
                [void]$rowGrid.Children.Add($typeBorder)

                $countText                   = New-Object System.Windows.Controls.TextBlock
                $countText.TextAlignment     = "Right"
                $countText.VerticalAlignment = "Center"
                $countText.FontWeight        = "SemiBold"
                [System.Windows.Controls.Grid]::SetColumn($countText, 1)
                [void]$rowGrid.Children.Add($countText)

                $pctText                   = New-Object System.Windows.Controls.TextBlock
                $pctText.TextAlignment     = "Right"
                $pctText.VerticalAlignment = "Center"
                $pctText.Foreground        = [System.Windows.Media.Brushes]::Gray
                [System.Windows.Controls.Grid]::SetColumn($pctText, 2)
                [void]$rowGrid.Children.Add($pctText)

                $rowBorder.Child = $rowGrid
                $cache[$lvl] = @{ Border = $rowBorder; CountText = $countText; PctText = $pctText }
            }
            [void]$StatsPanel.Children.Add($cache[$lvl].Border)
        }
    } else {
        $idx = 0
        foreach ($stat in $sortedStats) {
            $border  = $cache[$stat.Level].Border
            $current = $StatsPanel.Children[$idx]
            if (-not [object]::ReferenceEquals($current, $border)) {
                [void]$StatsPanel.Children.Remove($border)
                $StatsPanel.Children.Insert($idx, $border)
            }
            $idx++
        }
    }

    foreach ($stat in $sortedStats) {
        $row = $cache[$stat.Level]
        $row.CountText.Text = $stat.Count.ToString("N0")
        $row.PctText.Text   = "$([Math]::Round($stat.Percentage, 1))%"
    }
}

#endregion

#region --- Filter Bar ---

$script:FilterDebounceTimer          = New-Object System.Windows.Threading.DispatcherTimer
$script:FilterDebounceTimer.Interval = [TimeSpan]::FromMilliseconds(300)
$script:FilterDebounceTimer.Add_Tick({
    $script:FilterDebounceTimer.Stop()
    Invoke-ApplyFilter
})

function Invoke-RebuildFilterBar {
    $FilterPanel.Children.Clear()
    $script:State.FilterCheckboxes  = @{}
    $script:State.ActiveLevelFilter = @{}

    $levels = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($k in $script:Config.Keywords.Keys) { [void]$levels.Add($k) }
    foreach ($l in @([LogLevels]::Error, [LogLevels]::Warning, [LogLevels]::Info, [LogLevels]::Verbose)) {
        [void]$levels.Add($l)
    }

    $allTag        = [FilterTags]::All
    $allCb         = New-Object System.Windows.Controls.CheckBox
    $allCb.Content = "All"
    $allCb.IsChecked  = $true
    $allCb.Margin     = "4,0,8,0"
    $allCb.FontWeight = "Bold"
    $allCb.Tag        = $allTag
    $allCb.Add_Click({
        param($s, $e)
        $checked   = ($s.IsChecked -eq $true)
        $filterTag = [FilterTags]::All
        foreach ($cb in $script:State.FilterCheckboxes.Values) {
            if ($cb.Tag -ne $filterTag) {
                $cb.IsChecked = $checked
                $script:State.ActiveLevelFilter[$cb.Tag] = $checked
            }
        }
        Request-FilterUpdate
    })
    [void]$FilterPanel.Children.Add($allCb)
    $script:State.FilterCheckboxes[$allTag] = $allCb

    foreach ($level in ($levels | Sort-Object)) {
        $cb           = New-Object System.Windows.Controls.CheckBox
        $cb.Content   = $level
        $cb.Tag       = $level
        $cb.IsChecked = $true
        $cb.Margin    = "4,0,4,0"

        $colorName = $script:Config.Keywords[$level]
        if ($colorName -and (Test-ColorMapKey $colorName)) {
            $hex = $script:ColorMap[$colorName]
            try {
                $cb.Background = Get-CachedBrush $hex
            } catch {
                Report-Error "Invoke-RebuildFilterBar" "Brush error for level '$level': $_"
            }
        }

        $script:State.ActiveLevelFilter[$level] = $true

        $cb.Add_Click({
            param($s, $e)
            $script:State.ActiveLevelFilter[$s.Tag] = ($s.IsChecked -eq $true)
            $filterTag    = [FilterTags]::All
            $anyUnchecked = $script:State.FilterCheckboxes.Values | Where-Object { $_.Tag -ne $filterTag -and $_.IsChecked -ne $true }
            $script:State.FilterCheckboxes[$filterTag].IsChecked = ($null -eq $anyUnchecked)
            Request-FilterUpdate
        })

        [void]$FilterPanel.Children.Add($cb)
        $script:State.FilterCheckboxes[$level] = $cb
    }
}

function Request-FilterUpdate {
    $script:FilterDebounceTimer.Stop()
    $script:FilterDebounceTimer.Start()
}

function Invoke-ApplyFilter {
    $filterDict = New-Object 'System.Collections.Generic.Dictionary[string,bool]'
    foreach ($kv in $script:State.ActiveLevelFilter.GetEnumerator()) {
        $filterDict[$kv.Key] = [bool]$kv.Value
    }
    $visible = [LogParser]::FilterEntries($script:State.MasterList, $filterDict)
    $script:State.DisplayCollection.ReplaceAll($visible)
    if ($ScrollBtn.IsChecked -and $script:State.DisplayCollection.Count -gt 0) {
        $LogDataGrid.ScrollIntoView($script:State.DisplayCollection[$script:State.DisplayCollection.Count - 1])
    }
    Update-StatusBar
}

function Add-VisibleEntries {
    param([System.Collections.Generic.List[LogEntry]]$Entries)
    $filterDict = New-Object 'System.Collections.Generic.Dictionary[string,bool]'
    foreach ($kv in $script:State.ActiveLevelFilter.GetEnumerator()) {
        $filterDict[$kv.Key] = [bool]$kv.Value
    }
    $toAdd = [LogParser]::FilterEntries($Entries, $filterDict)
    if ($toAdd.Count -gt 0) {
        try {
            $script:State.DisplayCollection.AddRange($toAdd)
        } catch {
            Report-Error "Add-VisibleEntries" "AddRange reentrancy error: $_"
        }
    }
    Update-StatusBar
}

#endregion

#region --- Runspace Management ---

function Stop-LogTailing {
    $st = $script:State
    if ($null -ne $st.Cts) { $st.Cts.Cancel() }

    if ($null -ne $st.RunspacePS) {
        try {
            if ($null -ne $st.AsyncResult -and -not $st.AsyncResult.IsCompleted) {
                [void]$st.AsyncResult.AsyncWaitHandle.WaitOne($script:RunspaceShutdownMs)
            }
            if ($null -ne $st.AsyncResult) {
                $st.RunspacePS.EndInvoke($st.AsyncResult)
            }
        } catch { Report-Error "Stop-LogTailing" "EndInvoke error: $_" }
        try { $st.RunspacePS.Stop() }    catch { Report-Error "Stop-LogTailing" "Stop error: $_" }
        try { $st.RunspacePS.Dispose() } catch { Report-Error "Stop-LogTailing" "Dispose error: $_" }
        $st.RunspacePS  = $null
        $st.AsyncResult = $null
    }

    if ($null -ne $st.RunspaceObj) {
        try { $st.RunspaceObj.Close() }   catch { Report-Error "Stop-LogTailing" "Runspace.Close error: $_" }
        try { $st.RunspaceObj.Dispose() } catch { Report-Error "Stop-LogTailing" "Runspace.Dispose error: $_" }
        $st.RunspaceObj = $null
    }

    if ($null -ne $st.Cts) {
        $st.Cts.Dispose()
        $st.Cts = $null
    }
}

function Start-LogTailing {
    param(
        [string]$FilePath,
        [bool]$ResetState = $false
    )
    Stop-LogTailing
    $st = $script:State

    if ($ResetState -or $null -eq $st.SharedState) {
        $st.SharedState = New-Object SharedLogState
        Set-TimerInterval ([TimeSpan]::FromMilliseconds($script:FastTimerIntervalMs))
    } else {
        [System.Threading.Monitor]::Enter($st.SharedState.SyncRoot)
        try {
            $st.SharedState.InitialLoadComplete    = $false
            $st.SharedState.IsFlushingInitialQueue = $true
            $st.SharedState.LastError              = $null
        } finally {
            [System.Threading.Monitor]::Exit($st.SharedState.SyncRoot)
        }
        Set-TimerInterval ([TimeSpan]::FromMilliseconds($script:FastTimerIntervalMs))
    }

    if ($null -ne $st.LogQueue) {
        $discarded = $null
        while ($st.LogQueue.TryDequeue([ref]$discarded)) {}
    }
    $st.LogQueue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()

    $orderedKeywords = Get-SortedKeywords
    try {
        $st.Cts         = New-Object System.Threading.CancellationTokenSource
        $st.RunspaceObj = [runspacefactory]::CreateRunspace()
        $st.RunspaceObj.Open()
        $st.RunspacePS          = [System.Management.Automation.PowerShell]::Create()
        $st.RunspacePS.Runspace = $st.RunspaceObj
        $null = $st.RunspacePS.AddScript($bgScript)
        $null = $st.RunspacePS.AddArgument($FilePath)
        $null = $st.RunspacePS.AddArgument($orderedKeywords)
        $null = $st.RunspacePS.AddArgument($st.LogQueue)
        $null = $st.RunspacePS.AddArgument($st.Cts.Token)
        $null = $st.RunspacePS.AddArgument($st.SharedState)
        $null = $st.RunspacePS.AddArgument($script:PollIntervalMs)
        $st.AsyncResult = $st.RunspacePS.BeginInvoke()
    } catch {
        Report-Error "Start-LogTailing" "Failed to start background runspace: $_"
        Stop-LogTailing
        try { Set-TimerInterval ([TimeSpan]::FromSeconds($script:Config.UpdateSpeed)) } catch {}
    }
    Update-StatusBar
}

#endregion

#region --- Row Styling ---

function Set-GuiFromConfig {
    try {
        $font = New-Object System.Windows.Media.FontFamily($script:Config.FontFamily)
        $LogDataGrid.FontFamily   = $font
        $DetailTextBox.FontFamily = $font
        $LogDataGrid.FontSize     = $script:Config.FontSize
        $DetailTextBox.FontSize   = $script:Config.FontSize

        if ($null -ne $BottomRow) {
            $BottomRow.Height = New-Object System.Windows.GridLength([double]$script:Config.BottomPanelHeight)
        } else {
            Report-Error "Set-GuiFromConfig" "BottomRow is null - panel height not applied."
        }

        $rowStyle = New-Object System.Windows.Style([System.Windows.Controls.DataGridRow])
        $rowStyle.Setters.Add((New-Object System.Windows.Setter(
            [System.Windows.Controls.DataGridRow]::BackgroundProperty,
            [System.Windows.Media.Brushes]::White)))
        $rowStyle.Setters.Add((New-Object System.Windows.Setter(
            [System.Windows.Controls.DataGridRow]::ForegroundProperty,
            [System.Windows.Media.Brushes]::Black)))

        foreach ($kw in $script:Config.Keywords.Keys) {
            $colorName = $script:Config.Keywords[$kw]
            $hex = if (Test-ColorMapKey $colorName) { $script:ColorMap[$colorName] } else { "#FFFFFFFF" }
            try {
                $brush           = Get-CachedBrush $hex
                $trigger         = New-Object System.Windows.DataTrigger
                $trigger.Binding = New-Object System.Windows.Data.Binding("Level")
                $trigger.Value   = $kw
                $trigger.Setters.Add((New-Object System.Windows.Setter(
                    [System.Windows.Controls.DataGridRow]::BackgroundProperty, $brush)))
                $rowStyle.Triggers.Add($trigger)
            } catch {
                Report-Error "Set-GuiFromConfig" "Brush error for keyword '$kw': $_"
            }
        }

        $selectedBrush = Get-CachedBrush "#FF3399FF"
        $selectedFg    = [System.Windows.Media.Brushes]::White

        $selectedTrigger          = New-Object System.Windows.Trigger
        $selectedTrigger.Property = [System.Windows.Controls.DataGridRow]::IsSelectedProperty
        $selectedTrigger.Value    = $true
        $selectedTrigger.Setters.Add((New-Object System.Windows.Setter(
            [System.Windows.Controls.DataGridRow]::BackgroundProperty, $selectedBrush)))
        $selectedTrigger.Setters.Add((New-Object System.Windows.Setter(
            [System.Windows.Controls.DataGridRow]::ForegroundProperty, $selectedFg)))
        $rowStyle.Triggers.Add($selectedTrigger)

        $LogDataGrid.ItemContainerStyle = $rowStyle
    } catch {
        Report-Error "Set-GuiFromConfig" "Failed to apply UI styles: $_" -ShowDialog
    }
}

#endregion

#region --- Detail Panel Formatter ---

function Format-LogDetails {
    param([string]$RawMsg)
    $msg = $RawMsg
    if ($script:Config.FormatJson) {
        $trimMsg = $msg.TrimStart()
        # Added safety length check to prevent UI freezing on massive JSON logs
        if ($trimMsg.Length -lt $script:MaxJsonFormatLength -and ($trimMsg.StartsWith("{") -or $trimMsg.StartsWith("["))) {
            try {
                $msg = ($msg | ConvertFrom-Json -ErrorAction Stop | ConvertTo-Json -Depth $script:JsonFormatDepth)
            } catch {
                Report-Error "Format-LogDetails" "JSON formatting skipped: $_"
            }
        }
    }
    if ($script:Config.SplitComma)  { $msg = $msg.Replace(',', ",`r`n") }
    if ($script:Config.SplitSpace)  { $msg = $msg.Replace(' ', " `r`n") }
    if ($script:Config.SplitPeriod) { $msg = $msg.Replace('.', ".`r`n") }
    foreach ($d in $script:Config.CustomDelimiters) {
        if (-not [string]::IsNullOrWhiteSpace($d)) {
            $msg = $msg.Replace($d, "$d`r`n")
        }
    }
    return $msg
}

#endregion

#region --- Master List Trim ---

function Invoke-TrimMasterList {
    $masterList = $script:State.MasterList
    if ($masterList.Count -gt $script:TrimThreshold) {
        $excess = $masterList.Count - $script:MaxRetainedEntries
        $masterList.RemoveRange(0, $excess)
        Invoke-ApplyFilter
        return $true
    }
    return $false
}

#endregion

#region --- Initial Setup ---

$LogDataGrid.ItemsSource = $script:State.DisplayCollection
Set-GuiFromConfig
Invoke-RebuildFilterBar

#endregion

#region --- Overlay Button ---

$OpenLogOverlayBtn.Add_Click({
    $OpenMenu.RaiseEvent(
        (New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.MenuItem]::ClickEvent)))
})

#endregion

#region --- Slow Scroll ---

Add-SlowScroll $LogDataGrid
Add-SlowScroll $DetailTextBox

#endregion

#region --- Toolbar Event Handlers ---

$PauseBtn.Add_Click({
    if ($PauseBtn.IsChecked) {
        $PauseBtn.Content = "Resume Auto-Refresh"
        Stop-LogTailing
    } else {
        $PauseBtn.Content = "Pause Auto-Refresh"
        if ($null -ne $script:State.CurrentLogFile) {
            Start-LogTailing -FilePath $script:State.CurrentLogFile -ResetState $false
        }
    }
    Update-StatusBar
})

$ScrollBtn.Add_Click({
    $ScrollBtn.Content = if ($ScrollBtn.IsChecked) { "Auto-Scroll: ON" } else { "Auto-Scroll: OFF" }
})

#endregion

#region --- DataGrid Selection ---

$LogDataGrid.Add_SelectionChanged({
    if ($null -ne $LogDataGrid.SelectedItem) {
        $DetailTextBox.Text = Format-LogDetails -RawMsg $LogDataGrid.SelectedItem.RawMsg
    }
})

#endregion

#region --- Context Menu ---

$ContextCopyMenu.Add_Click({
    $selectedItems = $LogDataGrid.SelectedItems
    if ($selectedItems.Count -gt 0) {
        $lines = New-Object System.Collections.Generic.List[string]
        foreach ($item in $selectedItems) {
            if ($null -ne $item) { $lines.Add($item.Message) }
        }
        Copy-ToClipboard -Text ([string]::Join("`r`n", $lines))
    }
})

$CopyDetailBtn.Add_Click({
    if (-not [string]::IsNullOrWhiteSpace($DetailTextBox.Text)) {
        Copy-ToClipboard -Text $DetailTextBox.Text
    }
})

#endregion

#region --- Keyboard Shortcuts ---

$script:MainWindow.Add_KeyDown({
    param($sender, $e)
    $mods = $e.KeyboardDevice.Modifiers
    $ctrl = [System.Windows.Input.ModifierKeys]::Control

    if ($mods -eq $ctrl) {
        if ($e.Key -eq [System.Windows.Input.Key]::O) {
            $e.Handled = $true
            $OpenMenu.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.MenuItem]::ClickEvent)))
        } elseif ($e.Key -eq [System.Windows.Input.Key]::F) {
            $e.Handled = $true
            $SearchBox.Focus()
        } elseif ($e.Key -eq [System.Windows.Input.Key]::C) {
            $e.Handled = $true
            $selectedItems = $LogDataGrid.SelectedItems
            if ($selectedItems.Count -gt 0) {
                $lines = New-Object System.Collections.Generic.List[string]
                foreach ($item in $selectedItems) {
                    if ($null -ne $item) { $lines.Add($item.Message) }
                }
                Copy-ToClipboard -Text ([string]::Join("`r`n", $lines))
            }
        }
    }
})

#endregion

#region --- File Menu ---

$OpenMenu.Add_Click({
    $dlg        = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = "Log files (*.log)|*.log|Text files (*.txt)|*.txt|All files (*.*)|*.*"
    if ($dlg.ShowDialog() -eq $true) {
        $script:State.CurrentLogFile    = $dlg.FileName
        $script:Config.LastLogFile      = $dlg.FileName
        $script:MainWindow.Title        = "Configuration Manager Trace Log Tool - $($dlg.FileName)"
        $script:State.MasterList.Clear()
        $script:State.DisplayCollection.ReplaceAll($null)
        $script:State.StatsRowCache.Clear()
        $DetailTextBox.Text             = ""
        $SearchBox.Text                 = ""
        $LogDataGrid.SelectedIndex      = -1
        Invoke-RebuildFilterBar
        Start-LogTailing -FilePath $script:State.CurrentLogFile -ResetState $true
        $OpenLogOverlay.Visibility      = [System.Windows.Visibility]::Collapsed
        Update-StatusBar
    }
})

$ExitMenu.Add_Click({ $script:MainWindow.Close() })

#endregion

#region --- Error Log Dialog ---

$ErrorLogMenu.Add_Click({
    if ($script:ErrorLog.Count -eq 0) {
        [System.Windows.MessageBox]::Show(
            "No operational errors have been recorded in this session.",
            "Error Log",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information) | Out-Null
        return
    }

    $errXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="Operational Error Log" Height="400" Width="700"
        WindowStartupLocation="CenterOwner" Background="#FFF4F4F4" ResizeMode="CanResize">
    <Grid Margin="5">
        <Grid.RowDefinitions>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBox Grid.Row="0" Name="ErrorText" IsReadOnly="True" Background="White"
                 FontFamily="Consolas" FontSize="11"
                 VerticalScrollBarVisibility="Auto"
                 HorizontalScrollBarVisibility="Auto"
                 TextWrapping="NoWrap" Padding="4"/>
        <StackPanel Grid.Row="1" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,5,0,0">
            <Button Name="ClearErrBtn" Content="Clear Log" Width="80" Margin="0,0,5,0"/>
            <Button Name="CloseErrBtn" Content="Close"     Width="70" IsCancel="True"/>
        </StackPanel>
    </Grid>
</Window>
"@
    $errWindow = New-XamlWindow -XamlText $errXaml -Context "Error Log window"
    if ($null -eq $errWindow) { return }
    try {
        $errWindow.Owner = $script:MainWindow
        $errText     = Get-RequiredNamedControl $errWindow "ErrorText"   "Error Log window"
        $clearErrBtn = Get-RequiredNamedControl $errWindow "ClearErrBtn" "Error Log window"
        $closeErrBtn = Get-RequiredNamedControl $errWindow "CloseErrBtn" "Error Log window"
    } catch {
        Report-Error "ErrorLogMenu" "Could not resolve controls: $_"
        return
    }

    $errText.Text = $script:ErrorLog -join "`r`n"
    $clearErrBtn.Add_Click({
        $script:ErrorLog.Clear()
        $errText.Text = ""
    })
    $closeErrBtn.Add_Click({ $errWindow.Close() })
    [void]$errWindow.ShowDialog()
})

#endregion

#region --- Search ---

function Find-NextMatch {
    $searchText = $SearchBox.Text
    if ([string]::IsNullOrWhiteSpace($searchText)) { return }

    if (-not $PauseBtn.IsChecked) {
        $script:State.WasTailingBeforeSearch = $true
        $PauseBtn.IsChecked = $true
        $PauseBtn.Content   = "Resume Auto-Refresh"
        Stop-LogTailing
        if (-not $script:MainWindow.Title.EndsWith($script:SearchPausedSuffix)) {
            $script:MainWindow.Title = $script:MainWindow.Title + $script:SearchPausedSuffix
        }
    }

    if ($ScrollBtn.IsChecked) {
        $ScrollBtn.IsChecked = $false
        $ScrollBtn.Content   = "Auto-Scroll: OFF"
    }

    $displayCollection = $script:State.DisplayCollection
    if ($null -eq $displayCollection -or $displayCollection.Count -eq 0) { return }

    $startIndex = $LogDataGrid.SelectedIndex + 1
    if ($startIndex -ge $displayCollection.Count -or $startIndex -lt 0) { $startIndex = 0 }

    $script:MainWindow.Cursor = [System.Windows.Input.Cursors]::Wait
    try {
        $idx = [LogParser]::FindNext($displayCollection, $searchText, $startIndex)
        if ($idx -ge 0) {
            $LogDataGrid.SelectedIndex = $idx
            $LogDataGrid.ScrollIntoView($displayCollection[$idx])
            $LogDataGrid.Focus()
        }
    } finally {
        $script:MainWindow.Cursor = $null
    }
}

$SearchBtn.Add_Click({ Find-NextMatch })

$SearchBox.Add_KeyDown({
    param($sender, $e)
    if ($e.Key -eq 'Return' -or $e.Key -eq 'Enter') {
        $e.Handled = $true
        Find-NextMatch
    }
})

$ClearSearchBtn.Add_Click({
    $SearchBox.Text            = ""
    $LogDataGrid.SelectedIndex = -1
    $DetailTextBox.Text        = ""
    $SearchBox.Focus()
    if ($script:MainWindow.Title.EndsWith($script:SearchPausedSuffix)) {
        $script:MainWindow.Title = $script:MainWindow.Title.Substring(
            0, $script:MainWindow.Title.Length - $script:SearchPausedSuffix.Length)
        
        if ($script:State.WasTailingBeforeSearch) {
            $PauseBtn.IsChecked = $false
            $PauseBtn.Content   = "Pause Auto-Refresh"
            if ($null -ne $script:State.CurrentLogFile) {
                Start-LogTailing -FilePath $script:State.CurrentLogFile -ResetState $false
            }
            $script:State.WasTailingBeforeSearch = $false
        }
    }
})

$FindMenu.Add_Click({ $SearchBox.Focus() })

#endregion

#region --- Window Closing ---

$script:MainWindow.Add_Closing({
    try {
        if ($null -ne $script:FilterDebounceTimer) { $script:FilterDebounceTimer.Stop() }
        if ($null -ne $script:RefreshTimer)        { $script:RefreshTimer.Stop() }
        Stop-LogTailing
        if ($null -ne $BottomRow) {
            $script:Config.BottomPanelHeight = [int]$BottomRow.Height.Value
        }
        $script:Config.WindowWidth  = [Math]::Max($script:MinWindowWidth,  [Math]::Min($script:MaxWindowWidth,  [int]$script:MainWindow.Width))
        $script:Config.WindowHeight = [Math]::Max($script:MinWindowHeight, [Math]::Min($script:MaxWindowHeight, [int]$script:MainWindow.Height))
        Export-Config
    } catch {
        Report-Error "Window.Closing" "$_"
    }
    if ($script:ErrorLog.Count -gt 0) {
        Write-Host "`n--- Operational Error Log ---" -ForegroundColor Yellow
        foreach ($entry in $script:ErrorLog) { Write-Host $entry -ForegroundColor Red }
    }
})

#endregion

#region --- Settings Dialog ---

$SettingsMenu.Add_Click({
    $settingsXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:sys="clr-namespace:System;assembly=mscorlib"
        Title="Settings" Height="680" Width="450" FontSize="11"
        WindowStartupLocation="CenterOwner" Background="#FFF4F4F4" ResizeMode="CanResize">
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
                    <TextBlock Text="Delimiter:"     VerticalAlignment="Center" Margin="2"/>
                    <TextBox   Name="NewDelim"       Width="60"  Margin="2"/>
                    <Button    Name="AddDelimBtn"    Content="Add"             Width="50"  Margin="2"/>
                    <Button    Name="RemoveDelimBtn" Content="Remove Selected" Width="100" Margin="2"/>
                </StackPanel>
                <ListBox Name="DelimList" Grid.Row="1" Margin="2" ScrollViewer.CanContentScroll="False"/>
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
                        <DataGridTextColumn Header="Keyword" Binding="{Binding Key}" Width="*" IsReadOnly="False"/>
                        <DataGridTemplateColumn Header="Color" Width="100">
                            <DataGridTemplateColumn.CellTemplate>
                                <DataTemplate>
                                    <ComboBox SelectedItem="{Binding Value, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}"
                                              ItemsSource="{StaticResource ColorList}" Margin="1"/>
                                </DataTemplate>
                            </DataGridTemplateColumn.CellTemplate>
                        </DataGridTemplateColumn>
                    </DataGrid.Columns>
                </DataGrid>
                <Button Name="RemoveBtn" Content="Remove Selected" Grid.Row="1" Width="100" HorizontalAlignment="Left" Margin="2"/>
            </Grid>
        </GroupBox>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Grid.Row="4" Margin="5,2,0,2">
            <Button Name="SaveBtn"   Content="Save and Apply" Width="90" Margin="0,0,5,0" IsDefault="True"/>
            <Button Name="CancelBtn" Content="Cancel"         Width="70" IsCancel="True"/>
        </StackPanel>
    </Grid>
</Window>
"@
    $sWindow = New-XamlWindow -XamlText $settingsXaml -Context "Settings window"
    if ($null -eq $sWindow) { return }

    try {
        $sWindow.Owner  = $script:MainWindow
        $FontCombo      = Get-RequiredNamedControl $sWindow "FontCombo"      "Settings window"
        $SizeCombo      = Get-RequiredNamedControl $sWindow "SizeCombo"      "Settings window"
        $SpeedCombo     = Get-RequiredNamedControl $sWindow "SpeedCombo"     "Settings window"
        $JsonCheck      = Get-RequiredNamedControl $sWindow "JsonCheck"      "Settings window"
        $CommaCheck     = Get-RequiredNamedControl $sWindow "CommaCheck"     "Settings window"
        $SpaceCheck     = Get-RequiredNamedControl $sWindow "SpaceCheck"     "Settings window"
        $PeriodCheck    = Get-RequiredNamedControl $sWindow "PeriodCheck"    "Settings window"
        $NewDelim       = Get-RequiredNamedControl $sWindow "NewDelim"       "Settings window"
        $AddDelimBtn    = Get-RequiredNamedControl $sWindow "AddDelimBtn"    "Settings window"
        $RemoveDelimBtn = Get-RequiredNamedControl $sWindow "RemoveDelimBtn" "Settings window"
        $DelimList      = Get-RequiredNamedControl $sWindow "DelimList"      "Settings window"
        $KeywordsGrid   = Get-RequiredNamedControl $sWindow "KeywordsGrid"   "Settings window"
        $RemoveBtn      = Get-RequiredNamedControl $sWindow "RemoveBtn"      "Settings window"
        $SaveBtn        = Get-RequiredNamedControl $sWindow "SaveBtn"        "Settings window"
        $CancelBtn      = Get-RequiredNamedControl $sWindow "CancelBtn"      "Settings window"
    } catch {
        Report-Error "SettingsMenu" "Control resolution failed: $_"
        return
    }

    Add-SlowScroll $KeywordsGrid
    Add-SlowScroll $DelimList

    $monoKeywords = @("Mono", "Consol", "Courier", "Fixed", "Code", "Cascadia", "Lucida")
    $allFonts     = [System.Windows.Media.Fonts]::SystemFontFamilies |
                        Select-Object -ExpandProperty Source | Sort-Object

    foreach ($f in $allFonts) {
        $isMonoLike = $false
        foreach ($kw in $monoKeywords) {
            if ($f -like "*$kw*") { $isMonoLike = $true; break }
        }
        if ($isMonoLike) { [void]$FontCombo.Items.Add($f) }
    }
    foreach ($f in $allFonts) {
        if (-not $FontCombo.Items.Contains($f)) { [void]$FontCombo.Items.Add($f) }
    }
    if (-not $FontCombo.Items.Contains($script:Config.FontFamily)) {
        $FontCombo.Items.Insert(0, $script:Config.FontFamily)
    }
    $FontCombo.SelectedItem = $script:Config.FontFamily

    8..24 | ForEach-Object { [void]$SizeCombo.Items.Add($_) }
    if (-not $SizeCombo.Items.Contains($script:Config.FontSize)) {
        $SizeCombo.Items.Insert(0, $script:Config.FontSize)
    }
    $SizeCombo.SelectedItem = $script:Config.FontSize

    1..10 | ForEach-Object { [void]$SpeedCombo.Items.Add($_) }
    if (-not $SpeedCombo.Items.Contains($script:Config.UpdateSpeed)) {
        $SpeedCombo.Items.Insert(0, $script:Config.UpdateSpeed)
    }
    $SpeedCombo.SelectedItem = $script:Config.UpdateSpeed

    $JsonCheck.IsChecked   = $script:Config.FormatJson
    $CommaCheck.IsChecked  = $script:Config.SplitComma
    $SpaceCheck.IsChecked  = $script:Config.SplitSpace
    $PeriodCheck.IsChecked = $script:Config.SplitPeriod

    foreach ($d in $script:Config.CustomDelimiters) { [void]$DelimList.Items.Add($d) }

    $kwList = New-Object System.Collections.ObjectModel.ObservableCollection[KeywordItem]
    foreach ($kv in $script:Config.Keywords.GetEnumerator()) {
        $kwList.Add((New-Object KeywordItem -Property @{ Key = $kv.Key; Value = $kv.Value }))
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
        if ($null -ne $KeywordsGrid.SelectedItem -and $KeywordsGrid.SelectedItem -is [KeywordItem]) {
            $kwList.Remove($KeywordsGrid.SelectedItem)
        }
    })

    $SaveBtn.Add_Click({
        $KeywordsGrid.CommitEdit([System.Windows.Controls.DataGridEditingUnit]::Row, $true)

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
                [System.Windows.MessageBoxImage]::Warning) | Out-Null
            return
        }

        $validKeywords = @($kwList | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Key) })
        if ($validKeywords.Count -gt $script:MaxKeywordCount) {
            [System.Windows.MessageBox]::Show(
                "You have defined $($validKeywords.Count) keywords. The maximum allowed is $($script:MaxKeywordCount).`r`nPlease remove some keywords before saving.",
                "Too Many Keywords",
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Warning) | Out-Null
            return
        }

        $invalidColors = @($validKeywords | Where-Object { -not (Test-ColorMapKey $_.Value) })
        if ($invalidColors.Count -gt 0) {
            $badNames = ($invalidColors | ForEach-Object { "'$($_.Key)' = '$($_.Value)'" }) -join ', '
            [System.Windows.MessageBox]::Show(
                "The following keywords have invalid colours: $badNames`r`n`r`nValid colours are: $($script:ColorMap.Keys -join ', ')`r`nPlease correct them before saving.",
                "Invalid Colours",
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Warning) | Out-Null
            return
        }

        $blankKeyRows = @($kwList | Where-Object { [string]::IsNullOrWhiteSpace($_.Key) })
        if ($blankKeyRows.Count -gt 0) {
            $result = [System.Windows.MessageBox]::Show(
                "$($blankKeyRows.Count) keyword row(s) have an empty key and will be discarded.`r`nContinue saving?",
                "Empty Keywords",
                [System.Windows.MessageBoxButton]::YesNo,
                [System.Windows.MessageBoxImage]::Warning)
            if ($result -ne [System.Windows.MessageBoxResult]::Yes) { return }
        }

        $defaults = Get-DefaultConfig

        $script:Config.FontFamily = if ($null -ne $FontCombo.SelectedItem) {
            $FontCombo.SelectedItem
        } else { $defaults.FontFamily }

        $script:Config.FontSize = if ($null -ne $SizeCombo.SelectedItem) {
            [Math]::Max($script:MinFontSize, [Math]::Min($script:MaxFontSize, [int]$SizeCombo.SelectedItem))
        } else { $defaults.FontSize }

        $script:Config.UpdateSpeed = if ($null -ne $SpeedCombo.SelectedItem) {
            [Math]::Max($script:MinUpdateSpeed, [Math]::Min($script:MaxUpdateSpeed, [int]$SpeedCombo.SelectedItem))
        } else { $defaults.UpdateSpeed }

        $script:Config.FormatJson  = ($JsonCheck.IsChecked  -eq $true)
        $script:Config.SplitComma  = ($CommaCheck.IsChecked -eq $true)
        $script:Config.SplitSpace  = ($SpaceCheck.IsChecked -eq $true)
        $script:Config.SplitPeriod = ($PeriodCheck.IsChecked -eq $true)

        $delims = New-Object System.Collections.Generic.List[string]
        foreach ($d in $DelimList.Items) { $delims.Add($d) }
        $script:Config.CustomDelimiters = $delims

        $newKw = @{}
        foreach ($item in $kwList) {
            if ($null -ne $item -and -not [string]::IsNullOrWhiteSpace($item.Key)) {
                $newKw[$item.Key] = $item.Value
            }
        }
        $script:Config.Keywords = $newKw

        Clear-BrushCache
        $script:State.StatsRowCache.Clear()

        Export-Config
        Set-GuiFromConfig

        $orderedKeywords = Get-SortedKeywords
        [LogParser]::ReEvaluateAll($script:State.MasterList, $orderedKeywords)
        Invoke-RebuildFilterBar
        [void](Invoke-TrimMasterList)
        Invoke-ApplyFilter

        if ($null -ne $script:State.CurrentLogFile -and -not $PauseBtn.IsChecked) {
            Start-LogTailing -FilePath $script:State.CurrentLogFile -ResetState $false
        }

        try {
            $isStillFlushing = $false
            if ($null -ne $script:State.SharedState) {
                [System.Threading.Monitor]::Enter($script:State.SharedState.SyncRoot)
                try { $isStillFlushing = $script:State.SharedState.IsFlushingInitialQueue }
                finally { [System.Threading.Monitor]::Exit($script:State.SharedState.SyncRoot) }
            }
            if (-not $isStillFlushing) {
                Set-TimerInterval ([TimeSpan]::FromSeconds($script:Config.UpdateSpeed))
            }
        } catch {
            Report-Error "Settings.SaveBtn" "Timer reconfigure error: $_"
        }

        $sWindow.Close()
    })

    $CancelBtn.Add_Click({ $sWindow.Close() })
    [void]$sWindow.ShowDialog()
})

#endregion

#region --- Dispatcher Timer ---

$script:RefreshTimer          = New-Object System.Windows.Threading.DispatcherTimer
$script:RefreshTimer.Interval = [TimeSpan]::FromMilliseconds($script:FastTimerIntervalMs)

$script:RefreshTimer.Add_Tick({
    try {
        $appState    = $script:State
        $sharedState = $appState.SharedState

        if ($null -ne $sharedState) {
            $lastError = $null
            [System.Threading.Monitor]::Enter($sharedState.SyncRoot)
            try {
                $lastError = $sharedState.LastError
                if ($null -ne $lastError) { $sharedState.LastError = $null }
            } finally {
                [System.Threading.Monitor]::Exit($sharedState.SyncRoot)
            }
            if ($null -ne $lastError) {
                Report-Error "BackgroundThread" $lastError
            }
        }

        if ($null -ne $sharedState) {
            $initialLoadComplete    = $false
            $isFlushingInitialQueue = $false

            [System.Threading.Monitor]::Enter($sharedState.SyncRoot)
            try {
                $initialLoadComplete    = $sharedState.InitialLoadComplete
                $isFlushingInitialQueue = $sharedState.IsFlushingInitialQueue
            } finally {
                [System.Threading.Monitor]::Exit($sharedState.SyncRoot)
            }

            if ($initialLoadComplete -and $isFlushingInitialQueue) {
                $queueEmpty = ($null -eq $appState.LogQueue -or $appState.LogQueue.IsEmpty)
                if ($queueEmpty) {
                    [System.Threading.Monitor]::Enter($sharedState.SyncRoot)
                    try {
                        if ($sharedState.IsFlushingInitialQueue) {
                            $sharedState.IsFlushingInitialQueue = $false
                        }
                    } finally {
                        [System.Threading.Monitor]::Exit($sharedState.SyncRoot)
                    }
                    Set-TimerInterval ([TimeSpan]::FromSeconds([int]$script:Config.UpdateSpeed))
                    if ($ScrollBtn.IsChecked -and $appState.DisplayCollection.Count -gt 0) {
                        $LogDataGrid.ScrollIntoView($appState.DisplayCollection[$appState.DisplayCollection.Count - 1])
                    }
                }
            }
        }

        $logQueue = $appState.LogQueue
        if ($null -ne $logQueue -and -not $logQueue.IsEmpty) {
            $queueCount = $logQueue.Count
            $allocSize  = [Math]::Min($queueCount + 1, $script:MaxDrainPerTick)
            $newEntries = New-Object System.Collections.Generic.List[LogEntry]($allocSize)
            $rawEntry   = $null
            $count      = 0

            while ($logQueue.TryDequeue([ref]$rawEntry) -and $count -lt $script:MaxDrainPerTick) {
                $typedEntry = $rawEntry -as [LogEntry]
                if ($null -ne $typedEntry) {
                    [void]$newEntries.Add($typedEntry)
                } else {
                    Report-Error "RefreshTimer.Tick" "Queue contained non-LogEntry type '$($rawEntry.GetType().FullName)'; discarded."
                }
                $count++
            }

            if ($newEntries.Count -gt 0) {
                $appState.MasterList.AddRange($newEntries)
                $trimmed = Invoke-TrimMasterList
                if (-not $trimmed) {
                    Add-VisibleEntries -Entries $newEntries
                }

                if ($ScrollBtn.IsChecked) {
                    $shouldScroll = $true
                    if ($null -ne $sharedState) {
                        $stillFlushing = $false
                        [System.Threading.Monitor]::Enter($sharedState.SyncRoot)
                        try { $stillFlushing = $sharedState.IsFlushingInitialQueue }
                        finally { [System.Threading.Monitor]::Exit($sharedState.SyncRoot) }
                        if ($stillFlushing -and -not $logQueue.IsEmpty) {
                            $shouldScroll = $false
                        }
                    }
                    if ($shouldScroll -and $appState.DisplayCollection.Count -gt 0) {
                        $LogDataGrid.ScrollIntoView($appState.DisplayCollection[$appState.DisplayCollection.Count - 1])
                    }
                }
            }
        }

        if ($null -ne $sharedState) {
            $stillFlushing2 = $false
            [System.Threading.Monitor]::Enter($sharedState.SyncRoot)
            try { $stillFlushing2 = $sharedState.IsFlushingInitialQueue }
            finally { [System.Threading.Monitor]::Exit($sharedState.SyncRoot) }
            if ($stillFlushing2) { Update-StatusBar }
        }

    } catch {
        Report-Error "RefreshTimer.Tick" "$_"
    }
})

#endregion

#region --- Auto-Open Last File ---

if (-not [string]::IsNullOrWhiteSpace($script:Config.LastLogFile) -and (Test-Path $script:Config.LastLogFile)) {
    $script:State.CurrentLogFile       = $script:Config.LastLogFile
    $script:MainWindow.Title           = "Configuration Manager Trace Log Tool - $($script:Config.LastLogFile)"
    $OpenLogOverlay.Visibility         = [System.Windows.Visibility]::Collapsed
    Invoke-RebuildFilterBar
    Start-LogTailing -FilePath $script:State.CurrentLogFile -ResetState $true
}

#endregion

#region --- Start ---

Update-StatusBar
$script:RefreshTimer.Start()

try {
    [void]$script:MainWindow.ShowDialog()
} catch {
    Show-FatalError -Title "Main window runtime error" -Context "ShowDialog failed." -Exception $_.Exception
}

#endregion
