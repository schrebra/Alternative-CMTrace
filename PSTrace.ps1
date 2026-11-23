# ===========================================================================
# PSTrace (Avalonia edition) - PowerShell bootstrap
#
# A rewrite of the WPF PSTrace.ps1 log viewer as a C# Avalonia application,
# following the Powershell-Bootstrap-CSharp pattern: this single script
# finds or installs a user-local .NET 8 SDK (no elevation), writes the
# embedded C# sources into a clean workspace, publishes a self-contained
# win-x64 executable, verifies it, and launches it.
#
# Usage:
#   .\PSTrace.ps1                          build and launch the viewer
#   .\PSTrace.ps1 -NoLaunch                build only
#   .\PSTrace.ps1 -FilePath C:\logs\a.log build, launch, and open a.log
#   .\PSTrace.ps1 C:\logs\a.log           same: a bare path is forwarded
#
# File arguments are forwarded to the published executable untouched, so
# a shortcut that runs this script with a log path (or %1) opens that log,
# exactly like dropping the file on the executable itself.
# PositionalBinding is disabled so a bare file path can never be mistaken
# for the project name parameter.
# ===========================================================================
[CmdletBinding(PositionalBinding=$false)]
param([string]$ProjectName='PSTrace',[ValidateSet('Auto','Console','Avalonia')][string]$ProjectType='Avalonia',[string]$BaseDir='',[switch]$NoLaunch,[int]$MaxRetries=3,[string]$FilePath='', [Parameter(ValueFromRemainingArguments=$true)][string[]]$FileArgs=@())
 $ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
 $Script:StageName='Initialization';$Script:InstallerPath='';$Script:DotnetDir=Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet';$Script:AppKind='Avalonia'
function Write-Info([string]$m){Write-Host $m -ForegroundColor Cyan}
function Write-Ok([string]$m){Write-Host $m -ForegroundColor Green}
function Write-Warn2([string]$m){Write-Host $m -ForegroundColor Yellow}
function Write-Err2([string]$m){Write-Host $m -ForegroundColor Red}
function Throw-Code([int]$c,[string]$m){throw "[$c] $m"}
function Write-Stage([string]$n,[string]$m){Write-Host '';Write-Host "[$n] $m" -ForegroundColor Cyan}
function Initialize-Tls{try{[Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12}catch{};try{[Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls13}catch{}}
function Get-SafeName([string]$n){
 $n=[regex]::Replace($n,'[^A-Za-z0-9_]','');if($n.Length -eq 0){return 'GeneratedApp'};if($n -match '^\d'){$n='App'+$n};$n=$n.Substring(0,1).ToUpperInvariant()+$n.Substring(1)
 $kw=@('abstract','as','async','await','base','bool','break','byte','case','catch','char','checked','class','const','continue','decimal','default','delegate','do','double','else','enum','event','explicit','extern','false','finally','fixed','float','for','foreach','goto','if','implicit','in','init','int','interface','internal','is','lock','long','namespace','new','null','object','operator','out','override','params','private','protected','public','readonly','record','ref','return','sbyte','sealed','short','sizeof','stackalloc','static','string','struct','switch','this','throw','true','try','typeof','uint','ulong','unchecked','unsafe','ushort','using','var','virtual','void','volatile','while');if($kw -contains $n.ToLowerInvariant()){$n=$n+'App'}
return $n}
function Remove-Folder([string]$Path){
 $p=$Path.TrimEnd('\');if(-not (Test-Path -LiteralPath $p)){return $true}
for($i=1;$i -le 3;$i++){try{Get-ChildItem -LiteralPath $p -Force -Recurse -ErrorAction SilentlyContinue | ForEach-Object {try{$_.Attributes=[IO.FileAttributes]::Normal}catch{}};Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop}catch{Start-Sleep -Seconds ([math]::Min(30,5*$i))};if(-not (Test-Path -LiteralPath $p)){return $true}}
try{& cmd.exe /c rd /s /q "$p" | Out-Null}catch{}
 $gone=-not (Test-Path -LiteralPath $p);if(-not $gone){Write-Warn2 "cmd rd /s /q exited with code $LASTEXITCODE but '$p' still exists."}
return $gone}
function Find-DotNetSdk{
 $cand=@();$local=Join-Path $Script:DotnetDir 'dotnet.exe';if(Test-Path -LiteralPath $local){$cand+=$local};$resolved=Get-Command dotnet.exe -ErrorAction SilentlyContinue;if($resolved -and ($cand -notcontains $resolved.Source)){$cand+=$resolved.Source}
foreach($d in $cand){$prev=$ErrorActionPreference;$ErrorActionPreference='Continue';try{$null=(& $d --version 2>$null);if($LASTEXITCODE -eq 0){$sdks=@(& $d --list-sdks 2>$null);if($LASTEXITCODE -eq 0 -and (@($sdks | Where-Object {$_ -match '^8\.'}).Count -gt 0)){return $d}}}catch{}finally{$ErrorActionPreference=$prev}}
return $null}
function Test-SdkWorks([string]$DotNetPath){
if([string]::IsNullOrWhiteSpace($DotNetPath) -or -not (Test-Path -LiteralPath $DotNetPath)){return $false}
 $prev=$ErrorActionPreference;$ErrorActionPreference='Continue';try{$null=(& $DotNetPath --version 2>$null);if($LASTEXITCODE -ne 0){return $false};$sdks=@(& $DotNetPath --list-sdks 2>$null);if($LASTEXITCODE -ne 0){return $false};return (@($sdks | Where-Object {$_ -match '^8\.'}).Count -gt 0)}catch{return $false}finally{$ErrorActionPreference=$prev}}
function Save-FileWithRetry([string]$Url,[string]$Dest){
for($i=1;$i -le $MaxRetries;$i++){if(Test-Path -LiteralPath $Dest){Remove-Item -LiteralPath $Dest -Force -ErrorAction SilentlyContinue}
try{if($env:HTTPS_PROXY){Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing -TimeoutSec 120 -Proxy $env:HTTPS_PROXY -ErrorAction Stop}else{Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop};if((Test-Path -LiteralPath $Dest) -and ((Get-Item -LiteralPath $Dest).Length -gt 1000)){$head=((Get-Content -LiteralPath $Dest -TotalCount 5 -ErrorAction SilentlyContinue) -join ' ');if($head -notmatch '(?i)<\s*html|<!doctype'){return $true}}}catch{}
Write-Warn2 "Download attempt $i failed for: $Url";if($i -lt $MaxRetries){Write-Warn2 "Retrying in $([math]::Min(30,5*$i)) seconds...";Start-Sleep -Seconds ([math]::Min(30,5*$i))}}
return $false}
function Install-DotNetSdk{
 $Script:InstallerPath=Join-Path $env:TEMP 'dotnet-install.ps1';$urls=@('https://dot.net/v1/dotnet-install.ps1','https://raw.githubusercontent.com/dotnet/install-scripts/main/src/dotnet-install.ps1');$got=$false
foreach($u in $urls){if(Save-FileWithRetry -Url $u -Dest $Script:InstallerPath){$got=$true;break}}
if(-not $got){Throw-Code 2 "Could not download dotnet-install.ps1 from any known mirror after repeated retries."}
try{Unblock-File -LiteralPath $Script:InstallerPath -ErrorAction SilentlyContinue}catch{}
Write-Info "Installing the .NET 8 SDK user-local (no elevation) under: $($Script:DotnetDir)"
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script:InstallerPath -Channel 8.0 -Architecture x64 -InstallDir $Script:DotnetDir
if($LASTEXITCODE -ne 0){Throw-Code 3 "dotnet-install.ps1 exited with code $LASTEXITCODE."}}
function Set-DotNetEnv([string]$Dir){
if(-not (Test-Path -LiteralPath $Dir)){Throw-Code 3 "Expected dotnet directory '$Dir' does not exist after installation."}
 $env:DOTNET_ROOT=$Dir;$env:DOTNET_MULTILEVEL_LOOKUP='0';$env:DOTNET_NOLOGO='1';$env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1';$env:DOTNET_CLI_TELEMETRY_OPTOUT='1';$env:MSBUILDDISABLENODEREUSE='1';$env:NUGET_INTERACTIVE='false';if(@($env:Path -split ';') -notcontains $Dir){$env:Path="$Dir;$env:Path"}}
function Invoke-DotNet{param([string]$ExePath,[int]$FailCode=5,[string[]]$CliArgs=@());& $ExePath @CliArgs;if($LASTEXITCODE -ne 0){Throw-Code $FailCode "dotnet $($CliArgs -join ' ') failed with exit code $LASTEXITCODE. Review the output above for the exact cause."}}
function Test-DiskSpace([string]$Path){
 $gb=$null;try{$di=New-Object IO.DriveInfo($Path.Substring(0,1));if($di.IsReady){$gb=[math]::Round($di.AvailableFreeSpace/1GB,2)}}catch{}
if($null -eq $gb){Write-Warn2 'Could not determine free disk space; continuing.';return}
 $L=$Path.Substring(0,1);if($gb -lt 0.5){Throw-Code 1 "Only $gb GB free on drive ${L}: - at least 0.5 GB is required."}elseif($gb -lt 2){Write-Warn2 "Low disk space: $gb GB free on drive ${L}:"}else{Write-Ok "Disk space OK: $gb GB free on drive ${L}:"}}
function Write-SourceFiles([string]$Dir,[string]$Name){
 $projCs=@'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>WinExe</OutputType>
    <TargetFramework>net8.0</TargetFramework>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <SelfContained>true</SelfContained>
    <RuntimeIdentifier>win-x64</RuntimeIdentifier>
    <PublishSingleFile>true</PublishSingleFile>
    <IncludeNativeLibrariesForSelfExtract>true</IncludeNativeLibrariesForSelfExtract>
    <EnableCompressionInSingleFile>true</EnableCompressionInSingleFile>
    <DebugType>embedded</DebugType>
    <RootNamespace>__APPNAME__</RootNamespace>
    <AssemblyName>__APPNAME__</AssemblyName>
    <ServerGarbageCollection>false</ServerGarbageCollection>
    <ConcurrentGarbageCollection>true</ConcurrentGarbageCollection>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="Avalonia" Version="11.0.10" />
    <PackageReference Include="Avalonia.Win32" Version="11.0.10" />
    <PackageReference Include="Avalonia.Skia" Version="11.0.10" />
    <PackageReference Include="Avalonia.Themes.Fluent" Version="11.0.10" />
    <PackageReference Include="Avalonia.Controls.DataGrid" Version="11.0.10" />
  </ItemGroup>
</Project>
'@
 $progCs=@'
using System;
using System.IO;
using System.Runtime.InteropServices;
using Avalonia;

namespace __APPNAME__
{
    internal class Program
    {
        [DllImport("user32.dll", CharSet = CharSet.Auto)]
        private static extern int MessageBox(IntPtr hWnd, string text, string caption, uint type);

        [DllImport("user32.dll")]
        private static extern bool SetProcessDpiAwarenessContext(IntPtr dpiContext);

        [DllImport("shcore.dll")]
        private static extern int SetProcessDpiAwareness(int awareness);

        [DllImport("user32.dll")]
        private static extern bool SetProcessDPIAware();

        // Per-monitor DPI awareness (V2), declared in code before
        // any window exists so the app renders crisply and scales
        // correctly on mixed-DPI multi-monitor setups instead of
        // being bitmap-stretched by Windows. The calls fail quietly
        // when the host already fixed an awareness level (the .NET
        // host or a manifest can win the race); any of the three
        // levels is better than the system-aware default.
        private static void TrySetPerMonitorDpiAwareness()
        {
            try
            {
                // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = -4
                if (SetProcessDpiAwarenessContext(new IntPtr(-4))) return;
            }
            catch { }
            try
            {
                // PROCESS_PER_MONITOR_DPI_AWARE = 2
                if (SetProcessDpiAwareness(2) == 0) return;
            }
            catch { }
            try { SetProcessDPIAware(); } catch { }
        }

        // Entry point. Any command-line argument that names an existing file is
        // treated as a log file to open on startup. That single mechanism is
        // what powers both the Explorer "Open with PSTrace" context menu and
        // dropping a file onto the PSTrace shortcut or executable icon:
        // Windows passes the dropped or associated path as an argument.
        // The arguments flow untouched into the Avalonia desktop lifetime and
        // App.OnFrameworkInitializationCompleted picks the file out of them.
        [STAThread]
        public static void Main(string[] args)
        {
            TrySetPerMonitorDpiAwareness();
            try
            {
                BuildAvaloniaApp().StartWithClassicDesktopLifetime(args);
            }
            catch (Exception ex)
            {
                try { File.WriteAllText("crash.log", ex.ToString()); } catch { }
                MessageBox(IntPtr.Zero, ex.ToString(), "Application Error", 0x10);
            }
        }

        public static AppBuilder BuildAvaloniaApp() => AppBuilder.Configure<App>().UseWin32().UseSkia().LogToTrace();
    }
}
'@
 $appAxaml=@'
<Application xmlns="https://github.com/avaloniaui"
             xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
             x:Class="__APPNAME__.App"
             RequestedThemeVariant="Dark">
  <!-- Chrome brushes, dark only, taken from the Atrium client's
       theme (src/Client/wwwroot/css/app.css in the Atrium source):
       center-bg #18222E is the main surface, sidebar-bg
       #1B2A3A the chrome/panel colour, the right-hand-side panel
       #1E2938 the secondary band, the login card #21303F the raised
       panel, the line colour rgba(255,255,255,0.08) the border
       (composited over the surface), body text
       rgba(255,255,255,0.92), the text-dim colour
       rgba(255,255,255,0.56) the muted text (both composited), and
       the accent #1C58D9. The window layout carries a lot of explicit
       band, surface, border and text colours that the Fluent theme
       does not reach (menu strip, filter band, details pane,
       statistics panel), so they are defined here once and
       referenced with DynamicResource everywhere else. Severity
       colours are NOT here: they live in AppConfig's palette,
       because code paints rows, chips and swatches. -->
  <Application.Resources>
    <ResourceDictionary>
      <SolidColorBrush x:Key="PSTraceChromeBg" Color="#FF1B2A3A"/>
      <SolidColorBrush x:Key="PSTraceBandBg" Color="#FF1E2938"/>
      <SolidColorBrush x:Key="PSTracePanelBg" Color="#FF21303F"/>
      <SolidColorBrush x:Key="PSTraceSurfaceBg" Color="#FF18222E"/>
      <SolidColorBrush x:Key="PSTraceBorder" Color="#FF2A3644"/>
      <SolidColorBrush x:Key="PSTraceText" Color="#FFD9DCE1"/>
      <SolidColorBrush x:Key="PSTraceMutedText" Color="#FF9BA3AC"/>
      <SolidColorBrush x:Key="PSTraceHeaderBg" Color="#FF21303F"/>
      <SolidColorBrush x:Key="PSTraceHeaderText" Color="#FFECEDEF"/>
      <SolidColorBrush x:Key="PSTraceGridLine" Color="#FF232F3C"/>
      <SolidColorBrush x:Key="PSTraceAccent" Color="#FF1C58D9"/>
      <SolidColorBrush x:Key="PSTraceAccentText" Color="#FF7CC4FF"/>
      <SolidColorBrush x:Key="PSTraceErrorText" Color="#FFFF8A80"/>
    </ResourceDictionary>
  </Application.Resources>
  <Application.Styles>
    <FluentTheme />
    <!-- Required: referencing the Avalonia.Controls.DataGrid package does
         not merge its theme by itself. Without this include the DataGrid
         has no control template, so it renders nothing at all (no header,
         no rows) even though its ItemsSource is fully populated. Do not
         remove: this was the cause of the empty-grid bug. -->
    <StyleInclude Source="avares://Avalonia.Controls.DataGrid/Themes/Fluent.xaml"/>

    <!-- Selection: the Fluent DataGrid theme paints the selected row
         with a translucent accent rectangle (0078D7 at 0.6 opacity)
         over the row background, which left severity-coloured text
         unreadable on top of it. CMTrace uses a solid dark highlight
         with white text instead. The selection is therefore painted
         at every layer with the same solid dark blue: the row's own
         Background and Foreground via the :selected style here (the
         row template's border paints the row Background, so this is
         the layer the template actually consumes), the theme's
         selection rectangle via the /template/ styles below, and in
         code (MainWindow.StyleRow), which sets the dark background
         and white foreground as local values on the selected row so
         the previously realised severity background cannot show
         through. The severity signal survives selection as a
         saturated stripe in the row's left border, set in code. -->
    <Style Selector="DataGridRow:selected">
      <Setter Property="Background" Value="#FF1C58D9"/>
      <Setter Property="Foreground" Value="#FFFFFFFF"/>
    </Style>
    <Style Selector="DataGridRow:selected /template/ Rectangle#BackgroundRectangle">
      <Setter Property="Fill" Value="#FF1C58D9"/>
      <Setter Property="Opacity" Value="1"/>
    </Style>
    <Style Selector="DataGridRow:selected:pointerover /template/ Rectangle#BackgroundRectangle">
      <Setter Property="Fill" Value="#FF1C58D9"/>
      <Setter Property="Opacity" Value="1"/>
    </Style>

    <!-- Scrollbars never auto-hide: the Fluent theme fades them out
         when the pointer is elsewhere, which reads as no scrollbar
         at all. AllowAutoHide off keeps every bar (grid, details,
         statistics, chip strip, dialogs) on screen whenever its
         ScrollViewer shows one. -->
    <Style Selector="ScrollBar">
      <Setter Property="AllowAutoHide" Value="False"/>
    </Style>

    <!-- Cell text alignment: the TextBlock the DataGrid generates for
         a text column carries its own 12 px horizontal margin, on top
         of the cell padding, so cell text started 22 px into the cell
         while the column headers start at their 10 px padding, and
         short values in narrow columns read as centred. Zeroing the
         generated margin leaves the cell padding as the single inset,
         so every cell's text is left-aligned at the same offset as
         its header, CMTrace style. -->
    <Style Selector="DataGridCell TextBlock">
      <Setter Property="Margin" Value="0"/>
    </Style>

    <!-- Filter chips: the Fluent theme overrides a checked
         ToggleButton's template presenter background with the accent
         colour, whatever the control's own Background says, which
         painted every included chip the same blue and hid the
         per-level colours the code sets. This style hands the
         presenter back the chip's own Background (set in code: the
         level palette pair when included, the muted surface pair
         when excluded), so a filled chip reads as included and a
         muted outlined chip as excluded. -->
    <Style Selector="ToggleButton.chip:checked /template/ ContentPresenter#PART_ContentPresenter">
      <Setter Property="Background" Value="{TemplateBinding Background}"/>
    </Style>
    <!-- The same override hits the presenter Foreground: Fluent
         forces it to white in both states, whatever the chip's own
         Foreground is. On the dark palette's deep fills white reads
         fine, but on the light palette's tints it is the invisible
         chip label defect (white text on a pale fill). These styles
         hand the presenter back the chip's own Foreground at the
         same selector specificity, in both states. -->
    <Style Selector="ToggleButton.chip:checked /template/ ContentPresenter#PART_ContentPresenter">
      <Setter Property="Foreground" Value="{TemplateBinding Foreground}"/>
    </Style>
    <Style Selector="ToggleButton.chip:not(:checked) /template/ ContentPresenter#PART_ContentPresenter">
      <Setter Property="Foreground" Value="{TemplateBinding Foreground}"/>
    </Style>

    <!-- Column headers stay in the UI font even though the grid body
         uses the configured log font: a style setter beats the
         inherited value the grid passes down. -->
    <Style Selector="DataGridColumnHeader">
      <Setter Property="FontFamily" Value="Segoe UI, Inter, DejaVu Sans, sans-serif"/>
      <Setter Property="FontSize" Value="11.5"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="{DynamicResource PSTraceMutedText}"/>
      <Setter Property="Background" Value="{DynamicResource PSTraceHeaderBg}"/>
      <Setter Property="Padding" Value="12,0,12,0"/>
    </Style>
    <Style Selector="DataGridCell">
      <Setter Property="Padding" Value="12,0,12,0"/>
    </Style>

    <Style Selector="Button.pill">
      <Setter Property="CornerRadius" Value="16"/>
      <Setter Property="Padding" Value="16,6"/>
    </Style>
    <Style Selector="Border.card">
      <Setter Property="CornerRadius" Value="8"/>
      <Setter Property="Padding" Value="16"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Margin" Value="0,0,0,12"/>
      <Setter Property="Background" Value="{DynamicResource SystemControlBackgroundChromeMediumLowBrush}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource SystemControlForegroundBaseLowBrush}"/>
    </Style>
    <Style Selector="ToggleButton.chip">
      <Setter Property="CornerRadius" Value="999"/>
      <Setter Property="Padding" Value="11,4"/>
      <Setter Property="Margin" Value="0,0,6,0"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="HorizontalContentAlignment" Value="Center"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>

    <!-- Command-bar controls (2026 redesign): quiet ghost buttons
         and transport toggles on the panel surface. A checked
         transport toggle reads as active through a tinted fill and
         an accent edge, not a solid accent block. -->
    <Style Selector="Button.ghost">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="CornerRadius" Value="6"/>
      <Setter Property="HorizontalContentAlignment" Value="Center"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <Style Selector="ToggleButton.transport">
      <Setter Property="CornerRadius" Value="6"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="BorderBrush" Value="Transparent"/>
      <Setter Property="HorizontalContentAlignment" Value="Center"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <Style Selector="ToggleButton.transport:checked">
      <Setter Property="Background" Value="#FF24344A"/>
      <Setter Property="BorderBrush" Value="{DynamicResource PSTraceAccent}"/>
    </Style>
    <Style Selector="ToggleButton.transport:checked /template/ ContentPresenter#PART_ContentPresenter">
      <Setter Property="Background" Value="#FF24344A"/>
    </Style>

    <!-- Inset well: the search cluster sits in a well darker than
         the surface around it, with a hairline edge and 6 px
         corners. -->
    <Style Selector="Border.inset">
      <Setter Property="Background" Value="#FF141D28"/>
      <Setter Property="BorderBrush" Value="{DynamicResource PSTraceBorder}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="6"/>
    </Style>

    <!-- Details message body well: painted with the panel brush,
         NOT the near-black inset (Brandon, Nov 22: the details body
         read as a black box against the themed surface). -->
    <Style Selector="Border.detail-well">
      <Setter Property="Background" Value="{DynamicResource PSTracePanelBg}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource PSTraceBorder}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="6"/>
    </Style>

    <!-- Menu: the bar and its dropdowns wear the same palette as
         the rest of the chrome (Brandon, Nov 22: the menu was not
         themed like the rest of the UI). The Fluent popup panel is
         a MenuFlyoutPresenter; painting it with the panel brush and
         the hairline border brings the dropdowns onto the theme,
         and the selected item gets the transport-toggle fill. -->
    <Style Selector="Menu">
      <Setter Property="Foreground" Value="{DynamicResource PSTraceText}"/>
    </Style>
    <Style Selector="MenuItem">
      <Setter Property="Foreground" Value="{DynamicResource PSTraceText}"/>
    </Style>
    <Style Selector="MenuFlyoutPresenter">
      <Setter Property="Background" Value="{DynamicResource PSTracePanelBg}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource PSTraceBorder}"/>
      <Setter Property="Foreground" Value="{DynamicResource PSTraceText}"/>
    </Style>
    <Style Selector="MenuItem:selected /template/ ContentPresenter#PART_ContentPresenter">
      <Setter Property="Background" Value="#FF24344A"/>
    </Style>

    <!-- Menu-strip action buttons (Next, Clear): their labels must
         sit centred on both axes. The
         Fluent button template honours the content alignment
         properties, but they have to be set; the strip sets them per
         button as well, and this style keeps any future strip button
         honest. -->
    <Style Selector="Button.strip-action">
      <Setter Property="HorizontalContentAlignment" Value="Center"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>

    <!-- Shared text styles for window chrome and dialogs. -->
    <Style Selector="TextBlock.section-header">
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="{DynamicResource PSTraceText}"/>
    </Style>
    <Style Selector="TextBlock.field-label">
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="{DynamicResource PSTraceMutedText}"/>
    </Style>
    <Style Selector="TextBlock.field-value">
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Foreground" Value="{DynamicResource PSTraceText}"/>
    </Style>
  </Application.Styles>
</Application>
'@
 $appCs=@'
using System;
using System.IO;
using System.Linq;
using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml;
using Avalonia.Styling;

namespace __APPNAME__
{
    public partial class App : Application
    {
        public override void Initialize() => AvaloniaXamlLoader.Load(this);

        public override void OnFrameworkInitializationCompleted()
        {
            // Dark only: the variant is pinned before any window
            // exists so the first frame is already dark. There is no
            // light theme and no toggle; a Theme key left in an old
            // INI is ignored by AppConfig.
            RequestedThemeVariant = ThemeVariant.Dark;

            if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
            {
                var window = new MainWindow();
                desktop.MainWindow = window;

                // Feature A/C: a file path handed to the process on the
                // command line (Explorer context menu, file association, or
                // a file dropped onto the PSTrace icon or shortcut) is
                // opened as soon as the window exists. The first argument
                // that names an existing file wins, mirroring the drop
                // policy inside the window.
                string? initialFile = FindFileArgument(desktop.Args);
                if (initialFile != null)
                {
                    window.Opened += (_, _) => window.OpenLogFile(initialFile);
                }
            }
            base.OnFrameworkInitializationCompleted();
        }

        internal static string? FindFileArgument(string[]? args)
        {
            if (args == null) return null;
            foreach (string arg in args)
            {
                if (string.IsNullOrWhiteSpace(arg)) continue;
                if (arg.StartsWith("-", StringComparison.Ordinal)) continue;
                // A UNC argument (a network file opened from Explorer)
                // is accepted without an existence probe: probing a
                // dead host would stall startup for the SMB timeout.
                // The tailer reports reachability once the window is up.
                if (RemoteLogPath.IsUnc(arg)) return arg;
                try
                {
                    if (File.Exists(arg)) return Path.GetFullPath(arg);
                }
                catch
                {
                    // A malformed path argument is ignored, never fatal.
                }
            }
            return null;
        }
    }
}
'@
 $parserCs=@'
using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Collections.Specialized;
using System.ComponentModel;

namespace __APPNAME__
{
    // Ported from the C# types embedded in the original PSTrace.ps1. The
    // parsing and severity rules are unchanged: a line is a CMTrace entry
    // only when it starts with "<![LOG[" and contains "]LOG]!>" plus
    // type="..." and time="..." attributes after the message; the displayed
    // timestamp is the first 12 characters of the time value
    // (HH:mm:ss.fff); severity is decided by the keyword list first
    // (longest keyword match wins) and only then by the numeric type
    // (3 = Error, 2 = Warn, 1 = Info).

    public static class LogLevels
    {
        public const string Error = "Error";
        public const string Warning = "Warn";
        public const string Info = "Info";
        public const string Verbose = "Verbose";
    }

    public static class FilterTags
    {
        public const string All = "__ALL__";
    }

    public class KeywordItem : INotifyPropertyChanged
    {
        private string _key = "";
        private string _value = "";

        public string Key
        {
            get => _key;
            set { if (_key != value) { _key = value; OnPropertyChanged(nameof(Key)); } }
        }

        public string Value
        {
            get => _value;
            set { if (_value != value) { _value = value; OnPropertyChanged(nameof(Value)); } }
        }

        public event PropertyChangedEventHandler? PropertyChanged;
        protected void OnPropertyChanged(string name) =>
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }

    public class LogEntry : INotifyPropertyChanged
    {
        private string _message = "";
        private string _rawMsg = "";
        private string _displayText = "";
        private string _level = "";
        private string _typeVal = "";
        private string _time = "";
        private string _date = "";
        private string _component = "";
        private string _context = "";
        private string _thread = "";

        public string Message
        {
            get => _message;
            set { if (_message != value) { _message = value; OnPropertyChanged(nameof(Message)); } }
        }

        public string RawMsg
        {
            get => _rawMsg;
            set { if (_rawMsg != value) { _rawMsg = value; OnPropertyChanged(nameof(RawMsg)); } }
        }

        // The text the grid's Log Text column shows. For CMTrace entries
        // and plain lines this is the same as RawMsg. For bracket-format
        // lines ("[date time] [Level] message") it is only the message
        // part, because the timestamp and level already have their own
        // columns; RawMsg and Message keep the full original line, so
        // the details pane, copy, and find see the line exactly as
        // before.
        public string DisplayText
        {
            get => _displayText;
            set { if (_displayText != value) { _displayText = value; OnPropertyChanged(nameof(DisplayText)); } }
        }

        public string Level
        {
            get => _level;
            set { if (_level != value) { _level = value; OnPropertyChanged(nameof(Level)); } }
        }

        public string TypeVal
        {
            get => _typeVal;
            set { if (_typeVal != value) { _typeVal = value; OnPropertyChanged(nameof(TypeVal)); } }
        }

        // Structured CMTrace attributes, parsed from the attribute block
        // after the message. The grid binds these as separate columns and
        // the details pane shows them as fields; Message keeps its
        // original "[time] text" shape for copy and compatibility.
        // Time is the first 12 characters of the time value with no
        // brackets. Bracket-format lines fill Date and Time from their
        // leading "[date time]" token; other plain lines leave all of
        // these empty.
        public string Time
        {
            get => _time;
            set { if (_time != value) { _time = value; OnPropertyChanged(nameof(Time)); } }
        }

        public string Date
        {
            get => _date;
            set { if (_date != value) { _date = value; OnPropertyChanged(nameof(Date)); } }
        }

        public string Component
        {
            get => _component;
            set { if (_component != value) { _component = value; OnPropertyChanged(nameof(Component)); } }
        }

        public string Context
        {
            get => _context;
            set { if (_context != value) { _context = value; OnPropertyChanged(nameof(Context)); } }
        }

        public string Thread
        {
            get => _thread;
            set { if (_thread != value) { _thread = value; OnPropertyChanged(nameof(Thread)); } }
        }

        public event PropertyChangedEventHandler? PropertyChanged;
        protected void OnPropertyChanged(string name) =>
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }

    public class LevelCount
    {
        public string Level { get; set; } = "";
        public int Count { get; set; }
        public double Percentage { get; set; }
    }

    // Bulk-add collection that raises a single Reset notification per batch,
    // exactly like the original: without it, adding hundreds of thousands of
    // rows one notification at a time thrashes the items control layout.
    public class ObservableRangeCollection<T> : ObservableCollection<T>
    {
        private bool _suppressNotification;

        public void AddRange(IEnumerable<T> collection)
        {
            if (collection == null) return;
            var list = new List<T>(collection);
            if (list.Count == 0) return;

            _suppressNotification = true;
            try
            {
                foreach (var item in list) Items.Add(item);
            }
            finally
            {
                _suppressNotification = false;
            }

            OnPropertyChanged(new PropertyChangedEventArgs("Count"));
            OnPropertyChanged(new PropertyChangedEventArgs("Item[]"));
            OnCollectionChanged(new NotifyCollectionChangedEventArgs(
                NotifyCollectionChangedAction.Reset));
        }

        public void ReplaceAll(IEnumerable<T> collection)
        {
            _suppressNotification = true;
            try
            {
                Items.Clear();
                if (collection != null)
                {
                    foreach (var item in collection) Items.Add(item);
                }
            }
            finally
            {
                _suppressNotification = false;
            }

            OnPropertyChanged(new PropertyChangedEventArgs("Count"));
            OnPropertyChanged(new PropertyChangedEventArgs("Item[]"));
            OnCollectionChanged(new NotifyCollectionChangedEventArgs(
                NotifyCollectionChangedAction.Reset));
        }

        protected override void OnCollectionChanged(NotifyCollectionChangedEventArgs e)
        {
            if (!_suppressNotification) base.OnCollectionChanged(e);
        }
    }

    public static class LogParser
    {
        private const int MaxLineLength = 1048576;

        private static string DetermineLevel(
            string rawMsg,
            string typeVal,
            List<KeyValuePair<string, string>> orderedKeywords)
        {
            foreach (var kw in orderedKeywords)
            {
                if (rawMsg.IndexOf(kw.Key, StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    return kw.Key;
                }
            }
            if (typeVal == "3") return LogLevels.Error;
            if (typeVal == "2") return LogLevels.Warning;
            if (typeVal == "1") return LogLevels.Info;
            return LogLevels.Info;
        }

        // Keywords are checked longest first, so a longer keyword always
        // wins over a shorter one that is also present in the message.
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
            for (int i = 0; i < entries.Count; i++)
            {
                entries[i].Level = DetermineLevel(
                    entries[i].RawMsg, entries[i].TypeVal, orderedKeywords);
            }
        }

        public static List<LogEntry> FilterEntries(
            List<LogEntry> entries,
            Dictionary<string, bool> activeFilter)
        {
            var result = new List<LogEntry>(entries.Count);
            foreach (var e in entries)
            {
                bool visible;
                if (!activeFilter.TryGetValue(e.Level, out visible)) visible = true;
                if (visible) result.Add(e);
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
            for (int i = startIndex; i < count; i++)
            {
                if (items[i] != null &&
                    items[i].Message.IndexOf(searchText, StringComparison.OrdinalIgnoreCase) >= 0)
                    return i;
            }
            for (int i = 0; i < startIndex && i < count; i++)
            {
                if (items[i] != null &&
                    items[i].Message.IndexOf(searchText, StringComparison.OrdinalIgnoreCase) >= 0)
                    return i;
            }
            return -1;
        }

        public static List<LevelCount> GetLevelStatistics(IList<LogEntry> items)
        {
            var result = new List<LevelCount>();
            if (items == null || items.Count == 0) return result;
            var counts = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
            foreach (var e in items)
            {
                if (e == null || string.IsNullOrEmpty(e.Level)) continue;
                int c;
                if (!counts.TryGetValue(e.Level, out c)) c = 0;
                counts[e.Level] = c + 1;
            }
            int total = items.Count;
            var keys = new List<string>(counts.Keys);
            keys.Sort(StringComparer.OrdinalIgnoreCase);
            foreach (var k in keys)
            {
                int cnt = counts[k];
                double pct = (total > 0) ? (cnt * 100.0 / total) : 0.0;
                result.Add(new LevelCount { Level = k, Count = cnt, Percentage = pct });
            }
            return result;
        }

        // Reads one name="value" attribute from the attribute block at
        // or after startIndex. Returns "" when the attribute is absent
        // or malformed: unlike type and time, the structured fields are
        // optional, so a missing one never drops the entry.
        private static string ExtractAttribute(string line, int startIndex, string name)
        {
            string key = name + "=\"";
            int s = line.IndexOf(key, startIndex, StringComparison.Ordinal);
            if (s < 0) return "";
            s += key.Length;
            int e = line.IndexOf("\"", s, StringComparison.Ordinal);
            if (e < 0) return "";
            return line.Substring(s, e - s);
        }

        public static LogEntry? ParseLine(
            string line,
            List<KeyValuePair<string, string>> orderedKeywords)
        {
            if (line == null || line.Length > MaxLineLength) return null;

            if (line.StartsWith("<![LOG[", StringComparison.Ordinal) &&
                line.Contains("]LOG]!>"))
            {
                int msgStart = 7;
                int msgEnd = line.IndexOf("]LOG]!>", msgStart, StringComparison.Ordinal);
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

                string timestamp = timeStr.Length >= 12 ? "[" + timeStr.Substring(0, 12) + "]" : "[??:??:??.???]";

                string level = DetermineLevel(rawMsg, typeVal, orderedKeywords);

                return new LogEntry
                {
                    Message = timestamp + " " + rawMsg,
                    RawMsg = rawMsg,
                    DisplayText = rawMsg,
                    Level = level,
                    TypeVal = typeVal,
                    Time = timeStr.Length >= 12 ? timeStr.Substring(0, 12) : "??:??:??.???",
                    Date = ExtractAttribute(line, msgEnd, "date"),
                    Component = ExtractAttribute(line, msgEnd, "component"),
                    Context = ExtractAttribute(line, msgEnd, "context"),
                    Thread = ExtractAttribute(line, msgEnd, "thread")
                };
            }
            else
            {
                // Severity is decided on the whole line, exactly as
                // before, so a bracket line's level still comes from
                // its "[Level]" token and message keywords combined.
                string level = DetermineLevel(line, "0", orderedKeywords);
                var entry = new LogEntry
                {
                    Message = line,
                    RawMsg = line,
                    DisplayText = line,
                    Level = level,
                    TypeVal = "0"
                };
                if (TryParseBracketPrefix(line, out string date, out string time, out string message))
                {
                    entry.Date = date;
                    entry.Time = time;
                    entry.DisplayText = message;
                }
                return entry;
            }
        }

        // Bracket-format lines, written by tools that prefix each line
        // with a timestamp and a level in square brackets:
        // "[2025-10-05 19:53:37] [Info] message text". When the leading
        // token is a real date and time, the entry gains Date and Time
        // fields (kept in the source's own shape: yyyy-MM-dd and
        // HH:mm:ss with optional fractional seconds) and the display
        // text becomes the message after the level token. A leading
        // bracket that is not a valid timestamp leaves the line a
        // plain entry, untouched.
        private static bool TryParseBracketPrefix(
            string line,
            out string date,
            out string time,
            out string message)
        {
            date = "";
            time = "";
            message = "";
            if (line.Length < 3 || line[0] != '[') return false;
            int close = line.IndexOf(']');
            if (close < 0) return false;
            string token = line.Substring(1, close - 1);
            int space = token.IndexOf(' ');
            if (space <= 0) return false;
            string datePart = token.Substring(0, space);
            string timePart = token.Substring(space + 1);
            if (!DateTime.TryParseExact(
                    token,
                    new[] { "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm:ss.FFFFFFF" },
                    System.Globalization.CultureInfo.InvariantCulture,
                    System.Globalization.DateTimeStyles.None,
                    out _))
            {
                return false;
            }

            int pos = close + 1;
            while (pos < line.Length && line[pos] == ' ') pos++;
            // Optional "[Level]" token: the display text is what
            // follows it. Without one, the display text is what
            // follows the timestamp token.
            if (pos < line.Length && line[pos] == '[')
            {
                int levelClose = line.IndexOf(']', pos);
                if (levelClose > pos + 1)
                {
                    int after = levelClose + 1;
                    while (after < line.Length && line[after] == ' ') after++;
                    message = after < line.Length ? line.Substring(after) : "";
                    date = datePart;
                    time = timePart;
                    return true;
                }
            }
            message = pos < line.Length ? line.Substring(pos) : "";
            date = datePart;
            time = timePart;
            return true;
        }
    }
}
'@
 $tailerCs=@'
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Threading;

namespace __APPNAME__
{
    // Background file tailer. This mirrors the runspace script in the
    // original PSTrace.ps1: poll the file length, read only the new bytes
    // with FileShare.ReadWrite so a log being written by another process is
    // never locked, assemble multi-line CMTrace entries (an entry starts at
    // a "<![LOG[" line and continuation lines are appended), hold a trailing
    // incomplete CMTrace entry back as pending until its "]LOG]!>"
    // terminator arrives, reset cleanly when the file shrinks (rotation or
    // truncation), and back off exponentially on IO errors.
    public sealed class LogTailer : IDisposable
    {
        private readonly string _filePath;
        private readonly List<KeyValuePair<string, string>> _orderedKeywords;
        private readonly int _pollIntervalMs;
        private readonly ConcurrentQueue<LogEntry> _queue = new ConcurrentQueue<LogEntry>();
        private readonly CancellationTokenSource _cts = new CancellationTokenSource();
        private Thread? _thread;

        private long _lastFileLength;
        private string _pendingBuffer = "";
        private bool _fileSeen;
        private DateTime _runStartedUtc;

        public LogTailer(string filePath, List<KeyValuePair<string, string>> orderedKeywords, int pollIntervalMs = 500)
        {
            _filePath = filePath;
            _orderedKeywords = orderedKeywords;
            _pollIntervalMs = pollIntervalMs;
        }

        public ConcurrentQueue<LogEntry> Queue => _queue;
        public bool InitialLoadComplete { get; private set; }
        public string? LastError { get; private set; }
        public string FilePath => _filePath;

        public void Start()
        {
            _thread = new Thread(Run) { IsBackground = true, Name = "PSTrace.LogTailer" };
            _thread.Start();
        }

        public void Dispose()
        {
            try { _cts.Cancel(); } catch { }
            try { _thread?.Join(2000); } catch { }
            _cts.Dispose();
        }

        private void Run()
        {
            var token = _cts.Token;
            var buffer = new StringBuilder();
            int consecutiveErrors = 0;
            const int maxBackoffMs = 30000;
            _runStartedUtc = DateTime.UtcNow;

            while (!token.IsCancellationRequested)
            {
                try
                {
                    var fileInfo = new FileInfo(_filePath);
                    fileInfo.Refresh();

                    if (!fileInfo.Exists)
                    {
                        // The file has never been seen and a few seconds
                        // have passed: say so, once, instead of waiting
                        // silently forever. This is the failure shape of
                        // a remote open (\\computer\share\file.log) whose
                        // host is off, whose share name is wrong, or
                        // whose permissions deny access: over SMB all of
                        // them look like "not there" from here. Note the
                        // probe itself can block for the Windows SMB
                        // timeout on a dead host before this is set; the
                        // wait happens on this background thread, never
                        // on the UI thread.
                        if (!_fileSeen && LastError == null &&
                            (DateTime.UtcNow - _runStartedUtc).TotalSeconds > 3)
                        {
                            LastError = $"Cannot reach '{_filePath}': file not found. " +
                                "For a remote path, check the computer name, the share, and your permissions.";
                        }
                        token.WaitHandle.WaitOne(_pollIntervalMs);
                        continue;
                    }

                    if (!_fileSeen)
                    {
                        // First sight of the file: any "cannot reach"
                        // message from the wait above is now stale.
                        _fileSeen = true;
                        LastError = null;
                    }

                    long currentLength = fileInfo.Length;

                    if (currentLength < _lastFileLength)
                    {
                        // File was truncated or rotated: start over.
                        _lastFileLength = 0;
                        _pendingBuffer = "";
                        buffer.Clear();
                    }

                    if (currentLength > _lastFileLength)
                    {
                        using (var stream = new FileStream(
                            _filePath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                        using (var reader = new StreamReader(stream, Encoding.UTF8, true, 65536))
                        {
                            stream.Seek(_lastFileLength, SeekOrigin.Begin);
                            _lastFileLength = currentLength;

                            buffer.Clear();
                            if (_pendingBuffer.Length > 0)
                            {
                                buffer.Append(_pendingBuffer);
                                _pendingBuffer = "";
                            }

                            string? line;
                            while ((line = reader.ReadLine()) != null)
                            {
                                if (line.StartsWith("<![LOG[", StringComparison.Ordinal) && buffer.Length > 0)
                                {
                                    var entry = LogParser.ParseLine(buffer.ToString(), _orderedKeywords);
                                    if (entry != null) _queue.Enqueue(entry);
                                    buffer.Clear();
                                    buffer.Append(line);
                                }
                                else if (line.StartsWith("<![LOG[", StringComparison.Ordinal))
                                {
                                    buffer.Clear();
                                    buffer.Append(line);
                                }
                                else if (buffer.Length > 0)
                                {
                                    buffer.AppendLine(line);
                                }
                                else
                                {
                                    var entry = LogParser.ParseLine(line, _orderedKeywords);
                                    if (entry != null) _queue.Enqueue(entry);
                                }
                            }

                            if (buffer.Length > 0)
                            {
                                string bufferStr = buffer.ToString();
                                if (bufferStr.StartsWith("<![LOG[", StringComparison.Ordinal) &&
                                    !bufferStr.Contains("]LOG]!>"))
                                {
                                    // Trailing partial CMTrace entry: hold it
                                    // until the rest of it is written.
                                    _pendingBuffer = bufferStr;
                                }
                                else
                                {
                                    var entry = LogParser.ParseLine(bufferStr, _orderedKeywords);
                                    if (entry != null) _queue.Enqueue(entry);
                                    _pendingBuffer = "";
                                }
                            }
                        }

                        if (!InitialLoadComplete) InitialLoadComplete = true;
                        consecutiveErrors = 0;
                        // A successful read clears any earlier error so
                        // the status bar stops showing a stale problem.
                        LastError = null;
                    }
                }
                catch (IOException ex)
                {
                    consecutiveErrors++;
                    LastError = $"IO error ({consecutiveErrors}) at {DateTime.Now:HH:mm:ss} on '{_filePath}': {ex.Message}";
                    int backoffMs = (int)Math.Min(_pollIntervalMs * Math.Pow(2, consecutiveErrors), maxBackoffMs);
                    if (token.WaitHandle.WaitOne(backoffMs)) break;
                    continue;
                }
                catch (Exception ex)
                {
                    consecutiveErrors++;
                    LastError = $"Unexpected error ({consecutiveErrors}) at {DateTime.Now:HH:mm:ss}: {ex.Message}";
                    int backoffMs = (int)Math.Min(_pollIntervalMs * Math.Pow(2, consecutiveErrors), maxBackoffMs);
                    if (token.WaitHandle.WaitOne(backoffMs)) break;
                    continue;
                }

                if (token.WaitHandle.WaitOne(_pollIntervalMs)) break;
            }
        }
    }
}
'@
 $configCs=@'
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text.Json;

namespace __APPNAME__
{
    // Settings persisted to an INI file in AppData, the same file name and
    // the same keys the original PSTrace.ps1 used (%APPDATA%\
    // PS_CMTraceViewer.ini), so existing preferences carry over to this
    // build. Sections: [Settings] for scalars, [Keywords] for the
    // keyword-to-colour-name map.
    public sealed class AppConfig
    {
        public string FontFamily { get; set; } = "Consolas";
        public double FontSize { get; set; } = 12;
        public double BottomPanelHeight { get; set; } = 150;
        public bool FormatJson { get; set; } = true;
        public bool SplitComma { get; set; } = true;
        public bool SplitSpace { get; set; } = false;
        public bool SplitPeriod { get; set; } = false;
        public List<string> CustomDelimiters { get; set; } = new List<string>();
        public int UpdateSpeed { get; set; } = 3;
        // Whole-interface scale factor (Settings slider, 75% to
        // 150%), applied as a layout transform on every window so
        // the app stays usable on high-DPI and low-vision setups.
        public double UiScale { get; set; } = 1.0;
        // The neutral log text colour (Settings picker). It paints
        // the rows whose keyword colour is White (the Info bulk of
        // every log) and the details body. Severity rows keep their
        // per-level tints: the Type column and stripe carry those.
        public string TextColorName { get; set; } = "Dim White";

        public static readonly Dictionary<string, string> TextColorPresets =
            new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
            {
                ["White"] = "#FFE8E8E8",
                ["Dim White"] = "#FFCCD0D6",
                ["Grey"] = "#FFAEB4BC",
                ["Blue Grey"] = "#FFA9B7C6",
                ["Sky Blue"] = "#FF9FC3E8",
                ["Pale Cyan"] = "#FFA8D8D0",
                ["Soft Green"] = "#FFACC7B0",
                ["Mint"] = "#FFBFE3C6",
                ["Sand"] = "#FFD8C39A",
                ["Peach"] = "#FFE8BFA8",
                ["Lavender"] = "#FFC3B2E0",
                ["Pink"] = "#FFE3A8BC",
            };

        // The keyword colour names as a static array, so XAML can
        // bind a ComboBox ItemsSource with x:Static: the list is
        // populated before any row binding evaluates, which keeps
        // the Settings grid's colour cells from realising blank.
        public static string[] ColorNameList =>
            new System.Collections.Generic.List<string>(DarkColorMap.Keys).ToArray();

        // A stored colour name that is not in the dark palette
        // (written by an older build) falls back to White rather
        // than leaving a colour cell blank.
        public static string NormalizeColorName(string? name)
        {
            if (name != null)
            {
                foreach (string key in DarkColorMap.Keys)
                {
                    if (key.Equals(name, StringComparison.OrdinalIgnoreCase)) return key;
                }
            }
            return "White";
        }

        public string TextColorHex() =>
            TextColorPresets.TryGetValue(TextColorName, out var hex) ? hex : TextColorPresets["Dim White"];
        public string LastLogFile { get; set; } = "";
        public double WindowWidth { get; set; } = 1200;
        public double WindowHeight { get; set; } = 700;
        public string StatsSortColumn { get; set; } = "Count";
        public string StatsSortDirection { get; set; } = "Ascending";
        // The app is dark only (Brandon's direction, round 2): there
        // is no theme setting any more. A Theme key left in an older
        // INI by the toggle build is ignored on load and dropped on
        // the next save.
        public Dictionary<string, string> Keywords { get; set; } = DefaultKeywords();

        public static string ConfigPath => Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "PS_CMTraceViewer.ini");

        // Brandon's keyword set and colours, identical to the defaults in
        // the original viewer. Severity checks run longest keyword first;
        // the colour named here is looked up in the dark palette maps.
        public static Dictionary<string, string> DefaultKeywords()
        {
            return new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
            {
                ["Critical"] = "Red",
                ["Error"] = "Red",
                ["Exception"] = "Red",
                ["Failed"] = "Red",
                ["Warn"] = "Orange",
                ["Success"] = "Green",
                ["Verbose"] = "Blue",
                ["Info"] = "White",
            };
        }

        // Severity palette, dark only. The original's pastels washed
        // out (pale fills with mid-tone text, roughly 2:1 contrast,
        // and one chip label effectively invisible), so the palette
        // is built to a rule: every foreground / background pair
        // measures at least 4.5:1 contrast, verified by the view
        // tests against the Atrium-themed surfaces. The colour
        // associations are unchanged (red family for the failure
        // levels, orange and yellow for Warn, green for Success,
        // blue for Verbose, neutral for Info).
        //
        // 2026 redesign: full saturated row fills are gone. A row
        // background is now a quiet tint of the level hue over the
        // surface (Info is the bare surface), the row text is a pale
        // tint of the same hue, and the saturated signal lives in
        // the left stripe and the Type column. Severity is never
        // carried by hue alone: the Type column names the level in
        // text on every row.
        public static readonly Dictionary<string, string> DarkColorMap =
            new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
            {
                ["Red"] = "#FF3A2429",
                ["Orange"] = "#FF3A2E20",
                ["Yellow"] = "#FF37331F",
                ["Green"] = "#FF223128",
                ["Blue"] = "#FF22303F",
                ["Purple"] = "#FF2E2638",
                ["White"] = "#FF18222E",
            };

        public static readonly Dictionary<string, string> DarkTextColorMap =
            new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
            {
                ["Red"] = "#FFFFB4B0",
                ["Orange"] = "#FFFFCF99",
                ["Yellow"] = "#FFF7E29A",
                ["Green"] = "#FFA9DDB2",
                ["Blue"] = "#FFA9CCEF",
                ["Purple"] = "#FFDDBEF2",
                ["White"] = "#FFCCD0D6",
            };

        // Selection stripes: the saturated colour that survives in a
        // selected row's left border. Bright tones, chosen to stay
        // visible against the dark selection highlight.
        public static readonly Dictionary<string, string> DarkStripeColorMap =
            new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
            {
                ["Red"] = "#FFEF5350",
                ["Orange"] = "#FFFFA726",
                ["Yellow"] = "#FFF9A825",
                ["Green"] = "#FF66BB6A",
                ["Blue"] = "#FF42A5F5",
                ["Purple"] = "#FFCE93D8",
                ["White"] = "#FF90A4AE",
            };

        public static Dictionary<string, string> RowBackgrounds() => DarkColorMap;

        public static Dictionary<string, string> RowForegrounds() => DarkTextColorMap;

        public static Dictionary<string, string> Stripes() => DarkStripeColorMap;

        public List<KeyValuePair<string, string>> BuildOrderedKeywords() =>
            LogParser.BuildSortedKeywords(new Dictionary<string, string>(Keywords));

        public static AppConfig Load()
        {
            var cfg = new AppConfig();
            string path = ConfigPath;
            if (!File.Exists(path)) return cfg;

            string section = "";
            try
            {
                foreach (string rawLine in File.ReadAllLines(path))
                {
                    string line = rawLine.Trim();
                    if (line.Length == 0 || line.StartsWith(";") || line.StartsWith("#")) continue;
                    if (line.StartsWith("[") && line.EndsWith("]"))
                    {
                        section = line.Substring(1, line.Length - 2).Trim();
                        continue;
                    }
                    int eq = line.IndexOf('=');
                    if (eq <= 0) continue;
                    string key = line.Substring(0, eq).Trim();
                    string value = line.Substring(eq + 1).Trim();

                    if (section.Equals("Keywords", StringComparison.OrdinalIgnoreCase))
                    {
                        if (DarkColorMap.ContainsKey(value)) cfg.Keywords[key] = value;
                        continue;
                    }

                    switch (key)
                    {
                        case "FontFamily": if (value.Length > 0) cfg.FontFamily = value; break;
                        case "FontSize": if (double.TryParse(value, NumberStyles.Any, CultureInfo.InvariantCulture, out var fs) && fs > 0) cfg.FontSize = fs; break;
                        case "BottomPanelHeight": if (double.TryParse(value, NumberStyles.Any, CultureInfo.InvariantCulture, out var bh) && bh >= 0) cfg.BottomPanelHeight = bh; break;
                        case "FormatJson": cfg.FormatJson = ParseBool(value, cfg.FormatJson); break;
                        case "SplitComma": cfg.SplitComma = ParseBool(value, cfg.SplitComma); break;
                        case "SplitSpace": cfg.SplitSpace = ParseBool(value, cfg.SplitSpace); break;
                        case "SplitPeriod": cfg.SplitPeriod = ParseBool(value, cfg.SplitPeriod); break;
                        case "CustomDelimiters":
                            cfg.CustomDelimiters = new List<string>(
                                value.Split(new[] { ';' }, StringSplitOptions.RemoveEmptyEntries));
                            break;
                        case "UpdateSpeed": if (int.TryParse(value, out var us)) cfg.UpdateSpeed = Math.Clamp(us, 1, 5); break;
                        case "UiScale": if (double.TryParse(value, NumberStyles.Any, CultureInfo.InvariantCulture, out var sc)) cfg.UiScale = Math.Clamp(sc, 0.75, 1.5); break;
                        case "TextColor": if (TextColorPresets.ContainsKey(value)) cfg.TextColorName = value; break;
                        case "LastLogFile": cfg.LastLogFile = value; break;
                        case "WindowWidth": if (double.TryParse(value, NumberStyles.Any, CultureInfo.InvariantCulture, out var ww) && ww >= 400) cfg.WindowWidth = ww; break;
                        case "WindowHeight": if (double.TryParse(value, NumberStyles.Any, CultureInfo.InvariantCulture, out var wh) && wh >= 300) cfg.WindowHeight = wh; break;
                        case "StatsSortColumn": if (value == "Type" || value == "Count" || value == "Percentage") cfg.StatsSortColumn = value; break;
                        case "StatsSortDirection": if (value == "Ascending" || value == "Descending") cfg.StatsSortDirection = value; break;
                        // A Theme key from the toggle build falls
                        // through unhandled on purpose: dark only.
                    }
                }
            }
            catch
            {
                // A damaged config file must never stop the viewer starting:
                // fall back to whatever parsed cleanly, like the original.
            }
            return cfg;
        }

        public void Save()
        {
            try
            {
                var lines = new List<string>
                {
                    "[Settings]",
                    $"FontFamily={FontFamily}",
                    $"FontSize={FontSize.ToString(CultureInfo.InvariantCulture)}",
                    $"BottomPanelHeight={BottomPanelHeight.ToString(CultureInfo.InvariantCulture)}",
                    $"FormatJson={FormatJson}",
                    $"SplitComma={SplitComma}",
                    $"SplitSpace={SplitSpace}",
                    $"SplitPeriod={SplitPeriod}",
                    $"CustomDelimiters={string.Join(";", CustomDelimiters)}",
                    $"UpdateSpeed={UpdateSpeed}",
                    $"UiScale={UiScale.ToString(CultureInfo.InvariantCulture)}",
                    $"TextColor={TextColorName}",
                    $"LastLogFile={LastLogFile}",
                    $"WindowWidth={WindowWidth.ToString(CultureInfo.InvariantCulture)}",
                    $"WindowHeight={WindowHeight.ToString(CultureInfo.InvariantCulture)}",
                    $"StatsSortColumn={StatsSortColumn}",
                    $"StatsSortDirection={StatsSortDirection}",
                    "",
                    "[Keywords]",
                };
                foreach (var kv in Keywords) lines.Add($"{kv.Key}={kv.Value}");
                File.WriteAllLines(ConfigPath, lines);
            }
            catch (Exception ex)
            {
                ErrorLog.Report("Export-Config", $"Could not save settings: {ex.Message}");
            }
        }

        private static bool ParseBool(string value, bool fallback)
        {
            if (bool.TryParse(value, out bool b)) return b;
            if (value == "1") return true;
            if (value == "0") return false;
            return fallback;
        }
    }

    // Operational error log, mirroring the original viewer's in-memory list
    // (capped at 500 entries) shown by Tools, View Error Log.
    public static class ErrorLog
    {
        private const int MaxEntries = 500;
        private static readonly List<string> EntriesList = new List<string>();
        private static readonly object Gate = new object();

        public static event Action? Changed;

        public static void Report(string context, string message)
        {
            string entry = $"[{DateTime.Now:HH:mm:ss}] {context} : {message}";
            lock (Gate)
            {
                EntriesList.Add(entry);
                int excess = EntriesList.Count - MaxEntries;
                if (excess > 0) EntriesList.RemoveRange(0, excess);
            }
            Changed?.Invoke();
        }

        public static List<string> Snapshot()
        {
            lock (Gate) return new List<string>(EntriesList);
        }
    }

    // The bottom detail panel formatter from the original viewer: pretty
    // print JSON when the message looks like JSON, then split the text at
    // the configured delimiters so long structured messages read as lines.
    public static class DetailFormatter
    {
        private const int MaxJsonFormatLength = 100000;
        private const int JsonFormatDepth = 50;

        public static string Format(string rawMsg, AppConfig config)
        {
            string msg = rawMsg ?? "";
            if (config.FormatJson)
            {
                string trimMsg = msg.TrimStart();
                if (trimMsg.Length < MaxJsonFormatLength &&
                    (trimMsg.StartsWith("{") || trimMsg.StartsWith("[")))
                {
                    try
                    {
                        using var doc = JsonDocument.Parse(msg);
                        var options = new JsonSerializerOptions
                        {
                            WriteIndented = true,
                            MaxDepth = JsonFormatDepth,
                        };
                        msg = JsonSerializer.Serialize(doc.RootElement, options);
                    }
                    catch
                    {
                        ErrorLog.Report("Format-LogDetails", "JSON formatting skipped: message is not valid JSON.");
                    }
                }
            }
            if (config.SplitComma) msg = msg.Replace(",", ",\r\n");
            if (config.SplitSpace) msg = msg.Replace(" ", " \r\n");
            if (config.SplitPeriod) msg = msg.Replace(".", ".\r\n");
            foreach (string d in config.CustomDelimiters)
            {
                if (!string.IsNullOrWhiteSpace(d))
                {
                    msg = msg.Replace(d, d + "\r\n");
                }
            }
            return msg;
        }
    }
}
'@
 $mwAxaml=@'
<Window xmlns="https://github.com/avaloniaui"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:local="using:__APPNAME__"
        x:Class="__APPNAME__.MainWindow"
        Title="Configuration Manager Trace Log Tool"
        Width="1200" Height="700" MinWidth="720" MinHeight="300"
        FontFamily="Segoe UI, Inter, DejaVu Sans, sans-serif"
        RequestedThemeVariant="Dark"
        WindowStartupLocation="CenterScreen">
  <!-- The whole window content sits in a LayoutTransformControl so
       the Settings UI scale (AppConfig.UiScale) scales the entire
       interface layout, not just a render zoom. The code-behind sets
       its LayoutTransform from the configured scale. -->
  <LayoutTransformControl Name="RootScale">
  <Grid Name="RootGrid" ColumnDefinitions="*,Auto">
    <Grid Name="LeftGrid" Grid.Column="0" RowDefinitions="Auto,Auto,*,Auto,150,Auto">

      <!-- Menu strip: the File / Edit / Tools menu, the transport icon
           buttons and the search controls share one horizontal strip
           (folded into a single row to save vertical space). Menus on
           the left, search on the right. -->
      <Border Grid.Row="0" Background="{DynamicResource PSTracePanelBg}">
        <!-- Command bar (2026 redesign): menu, an accent Open
             button, the transport toggles, then the search cluster
             on the right. The filter row below shares this surface,
             so the two rows read as one command surface with a
             single hairline under the filters. The search box is an
             inset well: magnifier glyph, borderless box with the
             Search watermark, and the live match count inside the
             well's right edge. Prev / Next / Clear are quiet ghost
             buttons beside it. -->
        <Grid ColumnDefinitions="Auto,Auto,Auto,*" Margin="8,6,10,6">
          <Menu Grid.Column="0" VerticalAlignment="Center" Background="Transparent">
            <MenuItem Header="_File">
              <MenuItem Header="_Open..." Name="OpenMenu" InputGesture="Ctrl+O"/>
              <MenuItem Header="Open _Remote..." Name="OpenRemoteMenu"/>
              <Separator/>
              <MenuItem Header="_Exit" Name="ExitMenu"/>
            </MenuItem>
            <MenuItem Header="_Tools">
              <MenuItem Header="_Settings..." Name="SettingsMenu"/>
            </MenuItem>
          </Menu>
          <Button Grid.Column="1" Name="OpenStripBtn" Classes="accent" Content="Open"
                  Height="30" Padding="14,0,14,0" CornerRadius="6" VerticalAlignment="Center" Margin="8,0,0,0"
                  HorizontalContentAlignment="Center" VerticalContentAlignment="Center"
                  ToolTip.Tip="Open a log file (Ctrl+O)"/>
          <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center" Margin="10,0,0,0" Spacing="6">
            <Border Width="1" Background="{DynamicResource PSTraceBorder}" Margin="2,5,2,5"/>
            <!-- Icon-only transport buttons. The state lives in the icon
                 (pause bars vs play triangle; scroll glyph dimmed when
                 off, button highlighted when on) and in the hover
                 tooltip, which names the action and the state. The
                 code-behind keeps both in sync. -->
            <ToggleButton Name="PauseBtn" Classes="transport" Width="30" Height="30" Padding="0"
                          HorizontalContentAlignment="Center" VerticalContentAlignment="Center"
                          ToolTip.Tip="Pause auto-refresh">
              <!-- Both glyphs are drawn on the same 16x16 field with
                   their geometry centred on (8,8): the pause bars
                   span x 3..13 (3 wide each, 3 gap, 3 margins), the
                   play triangle spans x 5..13.5 with its centroid at
                   x 7.8, the optical centre of a triangle. Each Path
                   is explicitly centred in the button so nothing in
                   the template can drift it off centre. -->
              <Grid Width="16" Height="16" HorizontalAlignment="Center" VerticalAlignment="Center">
                <Path Name="PauseIcon" Width="16" Height="16" Stretch="Uniform"
                      HorizontalAlignment="Center" VerticalAlignment="Center"
                      Fill="{DynamicResource PSTraceText}"
                      Data="M3,2.5 L6,2.5 L6,13.5 L3,13.5 Z M10,2.5 L13,2.5 L13,13.5 L10,13.5 Z"/>
                <Path Name="PlayIcon" Width="16" Height="16" Stretch="Uniform"
                      HorizontalAlignment="Center" VerticalAlignment="Center"
                      Fill="{DynamicResource PSTraceText}" IsVisible="False"
                      Data="M5,2.5 L13.5,8 L5,13.5 Z"/>
              </Grid>
            </ToggleButton>
            <ToggleButton Name="ScrollBtn" Classes="transport" Width="30" Height="30" Padding="0"
                          HorizontalContentAlignment="Center" VerticalContentAlignment="Center"
                          IsChecked="True" ToolTip.Tip="Auto-scroll: on">
              <!-- CMTrace-style auto-scroll glyph: log lines on the
                   left, a bold arrow descending to the baseline on
                   the right. One path, same flat weight as the pause
                   glyph. -->
              <Path Name="ScrollIcon" Width="16" Height="16" Stretch="Uniform"
                    HorizontalAlignment="Center" VerticalAlignment="Center"
                    Fill="{DynamicResource PSTraceText}"
                    Data="M1.5,2.2 L8,2.2 L8,3.8 L1.5,3.8 Z M1.5,5.9 L8,5.9 L8,7.5 L1.5,7.5 Z M1.5,9.6 L5.6,9.6 L5.6,11.2 L1.5,11.2 Z M10.9,1.4 L13.1,1.4 L13.1,8.2 L15.2,8.2 L12,13 L8.8,8.2 L10.9,8.2 Z M1.5,14 L14.5,14 L14.5,15.4 L1.5,15.4 Z"/>
            </ToggleButton>
            <!-- Copy every loaded log line to the clipboard
                 (Brandon, Nov 22). Two overlapping sheets: the back
                 sheet as an outline, the front sheet filled, on the
                 same 16x16 field as the transport glyphs. -->
            <Button Name="CopyAllBtn" Classes="ghost" Width="30" Height="30" Padding="0"
                    HorizontalContentAlignment="Center" VerticalContentAlignment="Center"
                    ToolTip.Tip="Copy all log lines to the clipboard">
              <Path Width="16" Height="16" Stretch="Uniform"
                    HorizontalAlignment="Center" VerticalAlignment="Center"
                    Fill="{DynamicResource PSTraceText}"
                    Data="M5.5,1.5 L14.5,1.5 L14.5,10.5 L12.5,10.5 L12.5,3.5 L5.5,3.5 Z M3.5,5.5 L11.5,5.5 L11.5,14.5 L3.5,14.5 Z"/>
            </Button>
          </StackPanel>
          <!-- Prev / Next / Clear live INSIDE the search well
               (Brandon, Nov 22): one combined search control, the
               buttons quiet ghosts at the well's right edge after
               the match count. -->
          <Border Grid.Column="3" Classes="inset" VerticalAlignment="Center" Margin="14,0,0,0"
                  MinWidth="170" MaxWidth="560" HorizontalAlignment="Stretch">
            <Grid ColumnDefinitions="Auto,*,Auto,Auto,Auto,Auto">
              <Path Grid.Column="0" Width="14" Height="14" Margin="9,0,0,0"
                    HorizontalAlignment="Center" VerticalAlignment="Center"
                    Stroke="{DynamicResource PSTraceMutedText}" StrokeThickness="1.6"
                    Data="M10.2,10.2 L14.5,14.5 M6.8,1.8 A5,5 0 1 0 6.8,11.8 A5,5 0 1 0 6.8,1.8"/>
              <TextBox Grid.Column="1" Name="SearchBox" Watermark="Search"
                       Background="Transparent" BorderThickness="0"
                       VerticalAlignment="Center" Margin="6,0,0,0"/>
              <TextBlock Grid.Column="2" Name="SearchCountText" VerticalAlignment="Center"
                         FontSize="11.5" Foreground="{DynamicResource PSTraceMutedText}" Margin="6,0,4,0"/>
              <Button Grid.Column="3" Name="PrevBtn" Classes="ghost" Content="Prev"
                      ToolTip.Tip="Jump to the previous match"
                      Padding="8,0,8,0" Height="24" VerticalAlignment="Center" Margin="2,0,0,0"
                      HorizontalContentAlignment="Center" VerticalContentAlignment="Center"/>
              <Button Grid.Column="4" Name="SearchBtn" Classes="ghost" Content="Next"
                      ToolTip.Tip="Jump to the next match"
                      Padding="8,0,8,0" Height="24" VerticalAlignment="Center" Margin="1,0,0,0"
                      HorizontalContentAlignment="Center" VerticalContentAlignment="Center"/>
              <Button Grid.Column="5" Name="ClearSearchBtn" Classes="ghost" Content="Clear"
                      ToolTip.Tip="Clear the search text"
                      Padding="8,0,8,0" Height="24" VerticalAlignment="Center" Margin="1,0,4,0"
                      HorizontalContentAlignment="Center" VerticalContentAlignment="Center"/>
            </Grid>
          </Border>
        </Grid>
      </Border>

      <!-- Filter chips: a wrapping strip with NO horizontal
           scrollbar (Brandon, Nov 22). The ScrollViewer stays only
           as a width constraint: with horizontal scrolling disabled
           the WrapPanel is sized to the strip and wraps chips onto
           a second line when the window is narrow. -->
      <Border Grid.Row="1" Background="{DynamicResource PSTracePanelBg}" BorderBrush="{DynamicResource PSTraceBorder}" BorderThickness="0,0,0,1" Padding="10,0,10,7">
        <DockPanel>
          <TextBlock Text="FILTER" FontWeight="SemiBold" FontSize="10.5" Foreground="{DynamicResource PSTraceMutedText}" VerticalAlignment="Center" Margin="0,0,10,0" DockPanel.Dock="Left"/>
          <ScrollViewer Name="FilterScrollViewer" HorizontalScrollBarVisibility="Disabled" VerticalScrollBarVisibility="Disabled">
            <WrapPanel Name="FilterPanel" VerticalAlignment="Center"/>
          </ScrollViewer>
        </DockPanel>
      </Border>

      <Grid Grid.Row="2">
        <DataGrid Name="LogDataGrid"
                  Background="{DynamicResource PSTraceSurfaceBg}" Foreground="{DynamicResource PSTraceText}"
                  GridLinesVisibility="Horizontal"
                  HorizontalGridLinesBrush="{DynamicResource PSTraceGridLine}"
                  HeadersVisibility="Column"
                  AutoGenerateColumns="False"
                  IsReadOnly="True"
                  SelectionMode="Extended"
                  CanUserResizeColumns="False"
                  CanUserReorderColumns="True"
                  CanUserSortColumns="False"
                  RowHeight="25"
                  ColumnHeaderHeight="32"
                  BorderThickness="0">
          <DataGrid.ContextMenu>
            <ContextMenu>
              <MenuItem Header="Copy to Clipboard" Name="ContextCopyMenu"/>
            </ContextMenu>
          </DataGrid.ContextMenu>
          <DataGrid.Columns>
            <!-- Default order is Time, Type, Log Text (Brandon,
                 Nov 22); headers can still be dragged to rearrange. -->
            <DataGridTextColumn Header="Time" Binding="{Binding Time}" Width="122"/>
            <DataGridTextColumn Header="Type" Binding="{Binding Level}" Width="96"/>
            <DataGridTextColumn Header="Log Text" Binding="{Binding DisplayText}" Width="*"/>
            <DataGridTextColumn Header="Component" Binding="{Binding Component}" Width="164"/>
            <DataGridTextColumn Header="Thread" Binding="{Binding Thread}" Width="112"/>
          </DataGrid.Columns>
        </DataGrid>
        <Grid Name="OpenLogOverlay" Background="{DynamicResource PSTraceSurfaceBg}" ZIndex="10" IsVisible="True">
          <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center" Orientation="Vertical">
            <TextBlock Text="Click here to open a log file"
                       FontSize="18" FontWeight="SemiBold" Foreground="{DynamicResource PSTraceText}"
                       HorizontalAlignment="Center" Margin="0,0,0,16"/>
            <Button Name="OpenLogOverlayBtn" Content="Open Log File" Classes="accent" FontSize="14" HorizontalAlignment="Center"
                    Padding="24,10,24,10" Cursor="Hand"
                    HorizontalContentAlignment="Center" VerticalContentAlignment="Center"/>
            <TextBlock Text="or drag and drop a log file onto this window"
                       FontSize="12" Foreground="{DynamicResource PSTraceMutedText}"
                       HorizontalAlignment="Center" Margin="0,10,0,0"/>
          </StackPanel>
        </Grid>
      </Grid>

      <GridSplitter Grid.Row="3" Height="5" HorizontalAlignment="Stretch" Background="{DynamicResource PSTraceBorder}" ResizeDirection="Rows" ResizeBehavior="PreviousAndNext"/>

      <!-- Details pane: a header band, a structured field strip for the
           selected entry (the CMTrace info pane fields), and the
           formatted message body below. -->
      <Grid Grid.Row="4" RowDefinitions="Auto,Auto,*" Background="{DynamicResource PSTraceSurfaceBg}">
        <Border Grid.Row="0" Padding="12,7,12,0">
          <DockPanel>
            <Button Name="CopyDetailBtn" Classes="ghost" Content="Copy" DockPanel.Dock="Right" Padding="10,4,10,4" FontSize="12"
                    HorizontalContentAlignment="Center" VerticalContentAlignment="Center"/>
            <TextBlock Text="Details" Classes="section-header" FontSize="12" VerticalAlignment="Center"/>
          </DockPanel>
        </Border>
        <Border Grid.Row="1" Padding="12,6,12,0">
          <WrapPanel>
            <StackPanel Orientation="Horizontal" Margin="0,0,26,0">
              <TextBlock Text="TIME" Classes="field-label" VerticalAlignment="Center" Margin="0,0,7,0"/>
              <TextBlock Name="DetailTimeText" Classes="field-value" VerticalAlignment="Center"/>
            </StackPanel>
            <StackPanel Orientation="Horizontal" Margin="0,0,26,0">
              <TextBlock Text="DATE" Classes="field-label" VerticalAlignment="Center" Margin="0,0,7,0"/>
              <TextBlock Name="DetailDateText" Classes="field-value" VerticalAlignment="Center"/>
            </StackPanel>
            <StackPanel Orientation="Horizontal" Margin="0,0,26,0">
              <TextBlock Text="TYPE" Classes="field-label" VerticalAlignment="Center" Margin="0,0,7,0"/>
              <TextBlock Name="DetailTypeText" Classes="field-value" VerticalAlignment="Center"/>
            </StackPanel>
            <StackPanel Orientation="Horizontal" Margin="0,0,26,0">
              <TextBlock Text="COMPONENT" Classes="field-label" VerticalAlignment="Center" Margin="0,0,7,0"/>
              <TextBlock Name="DetailComponentText" Classes="field-value" VerticalAlignment="Center"/>
            </StackPanel>
            <StackPanel Orientation="Horizontal" Margin="0,0,26,0">
              <TextBlock Text="THREAD" Classes="field-label" VerticalAlignment="Center" Margin="0,0,7,0"/>
              <TextBlock Name="DetailThreadText" Classes="field-value" VerticalAlignment="Center"/>
            </StackPanel>
          </WrapPanel>
        </Border>
        <Border Grid.Row="2" Classes="detail-well" Margin="12,8,12,10">
          <TextBox Name="DetailTextBox"
                   IsReadOnly="True"
                   Background="Transparent"
                   Foreground="{DynamicResource PSTraceText}"
                   BorderThickness="0"
                   ScrollViewer.VerticalScrollBarVisibility="Visible"
                   ScrollViewer.HorizontalScrollBarVisibility="Visible"
                   TextWrapping="Wrap"
                   Padding="10,8,10,8"
                   FontFamily="Consolas"/>
        </Border>
      </Grid>

      <Border Grid.Row="5" Background="{DynamicResource PSTraceBandBg}" BorderBrush="{DynamicResource PSTraceBorder}" BorderThickness="0,1,0,0" Padding="10,4,10,4">
        <TextBlock Name="StatusText" Text="No log file open." FontSize="12" Foreground="{DynamicResource PSTraceText}" VerticalAlignment="Center"/>
      </Border>
    </Grid>

    <!-- Statistics panel: header band aligned with the menu strip, a
         sortable column header row, one row per level with a colour
         swatch, and a totals footer. -->
    <Border Grid.Column="1" Background="{DynamicResource PSTraceSurfaceBg}" BorderBrush="{DynamicResource PSTraceBorder}" BorderThickness="1,0,0,0" Width="200">
      <DockPanel>
        <Border DockPanel.Dock="Top" Background="{DynamicResource PSTracePanelBg}" BorderBrush="{DynamicResource PSTraceBorder}" BorderThickness="0,0,0,1">
          <TextBlock Text="Statistics" Classes="section-header" FontSize="12" VerticalAlignment="Center" Margin="12,10,12,10"/>
        </Border>
        <Border DockPanel.Dock="Top" Background="{DynamicResource PSTraceSurfaceBg}" BorderBrush="{DynamicResource PSTraceBorder}" BorderThickness="0,0,0,1">
          <Grid ColumnDefinitions="*,56,54" Margin="0,2,14,2">
            <Button Grid.Column="0" Name="SortTypeBtn" Content="Type" HorizontalContentAlignment="Left" Background="Transparent" BorderThickness="0" Padding="10,4,4,4" Cursor="Hand" FontSize="11" FontWeight="SemiBold" Foreground="{DynamicResource PSTraceMutedText}"/>
            <Button Grid.Column="1" Name="SortCountBtn" Content="Count" HorizontalContentAlignment="Right" Background="Transparent" BorderThickness="0" Padding="4,4,4,4" Cursor="Hand" FontSize="11" FontWeight="SemiBold" Foreground="{DynamicResource PSTraceMutedText}"/>
            <Button Grid.Column="2" Name="SortPctBtn" Content="%" HorizontalContentAlignment="Right" Background="Transparent" BorderThickness="0" Padding="4,4,10,4" Cursor="Hand" FontSize="11" FontWeight="SemiBold" Foreground="{DynamicResource PSTraceMutedText}"/>
          </Grid>
        </Border>
        <Border DockPanel.Dock="Bottom" Background="{DynamicResource PSTracePanelBg}" BorderBrush="{DynamicResource PSTraceBorder}" BorderThickness="0,1,0,0" Padding="10,6,10,6">
          <Grid ColumnDefinitions="*,56,54" Margin="0,0,14,0">
            <TextBlock Grid.Column="0" Text="Total" FontWeight="SemiBold" FontSize="12"/>
            <TextBlock Grid.Column="1" Name="TotalCountText" Text="0" FontWeight="SemiBold" FontSize="12" TextAlignment="Right"/>
            <TextBlock Grid.Column="2" Text="100%" FontWeight="SemiBold" FontSize="12" TextAlignment="Right" Foreground="{DynamicResource PSTraceMutedText}"/>
          </Grid>
        </Border>
        <!-- Clicking a type row above filters the grid to that type
             only; this button restores every type. It lives on the
             right, under the statistics, next to the totals. -->
        <Button DockPanel.Dock="Bottom" Name="ClearFilterBtn" Content="Clear filter"
                HorizontalAlignment="Stretch" HorizontalContentAlignment="Center"
                VerticalContentAlignment="Center" Margin="10,6,10,6" Padding="10,4,10,4"
                ToolTip.Tip="Show every log type again"/>
        <ScrollViewer Name="StatsScrollViewer" VerticalScrollBarVisibility="Visible" HorizontalScrollBarVisibility="Disabled">
          <!-- The right margin reserves the scroll bar's own lane
               (Brandon, Nov 22): rows never slide under the bar, so
               the % column stays readable at any UI scale. -->
          <StackPanel Name="StatsPanel" Margin="0,0,14,0"/>
        </ScrollViewer>
      </DockPanel>
    </Border>
  </Grid>
  </LayoutTransformControl>
</Window>
'@
 $mwCs=@'
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Documents;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using Avalonia.Styling;
using Avalonia.Threading;
using Avalonia.VisualTree;

namespace __APPNAME__
{
    public partial class MainWindow : Window
    {
        // Named constants carried over from the original viewer.
        private const int MaxDrainPerTick = 10000;
        private const int PollIntervalMs = 500;
        private const int MaxRetainedEntries = 10000000;
        private const int TrimThreshold = 11000000;

        private readonly AppConfig _config;
        private readonly ObservableRangeCollection<LogEntry> _master = new ObservableRangeCollection<LogEntry>();
        private readonly ObservableRangeCollection<LogEntry> _display = new ObservableRangeCollection<LogEntry>();
        private readonly Dictionary<string, bool> _activeFilter = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
        private readonly Dictionary<string, ToggleButton> _chips = new Dictionary<string, ToggleButton>(StringComparer.OrdinalIgnoreCase);
        private readonly Dictionary<string, IBrush> _brushCache = new Dictionary<string, IBrush>(StringComparer.OrdinalIgnoreCase);

        private DataGrid _logGrid = null!;
        private Grid _overlay = null!;
        private TextBox _searchBox = null!;
        private TextBox _detailText = null!;
        private TextBlock _statusText = null!;
        private TextBlock _totalCountText = null!;
        private StackPanel _statsPanel = null!;
        private WrapPanel _filterPanel = null!;
        private LayoutTransformControl _rootScale = null!;
        private TextBlock _detailTimeText = null!;
        private TextBlock _detailDateText = null!;
        private TextBlock _detailTypeText = null!;
        private TextBlock _detailComponentText = null!;
        private TextBlock _detailThreadText = null!;
        private ToggleButton _pauseBtn = null!;
        private ToggleButton _scrollBtn = null!;
        private TextBlock _searchCountText = null!;
        private Button _clearFilterBtn = null!;
        private Avalonia.Controls.Shapes.Path _pauseIcon = null!;
        private Avalonia.Controls.Shapes.Path _playIcon = null!;
        private Avalonia.Controls.Shapes.Path _scrollIcon = null!;
        private Button _sortTypeBtn = null!;
        private Button _sortCountBtn = null!;
        private Button _sortPctBtn = null!;
        private Grid _leftGrid = null!;

        private LogTailer? _tailer;
        private DispatcherTimer? _drainTimer;
        private DispatcherTimer? _statsTimer;
        private DispatcherTimer? _searchTimer;
        private string? _exclusiveLevel;
        private bool _syncingFilter;
        private string? _currentFile;
        private bool _paused;
        private bool _initialFlushing;
        private bool _statsDirty = true;
        private string? _lastShownTailError;
        private string _lastSearchText = "";
        // The text colour currently painted: the config value, or
        // the Settings dialog's live preview while it is open.
        private string _effectiveTextColorHex = AppConfig.TextColorPresets["Dim White"];
        private bool _anyComponent;
        private bool _anyThread;

        public MainWindow()
        {
            _config = AppConfig.Load();
            InitializeComponent();

            _leftGrid = this.FindControl<Grid>("LeftGrid")!;
            _logGrid = this.FindControl<DataGrid>("LogDataGrid")!;
            _overlay = this.FindControl<Grid>("OpenLogOverlay")!;
            _searchBox = this.FindControl<TextBox>("SearchBox")!;
            _detailText = this.FindControl<TextBox>("DetailTextBox")!;
            _statusText = this.FindControl<TextBlock>("StatusText")!;
            _totalCountText = this.FindControl<TextBlock>("TotalCountText")!;
            _statsPanel = this.FindControl<StackPanel>("StatsPanel")!;
            _filterPanel = this.FindControl<WrapPanel>("FilterPanel")!;
            _rootScale = this.FindControl<LayoutTransformControl>("RootScale")!;
            _detailTimeText = this.FindControl<TextBlock>("DetailTimeText")!;
            _detailDateText = this.FindControl<TextBlock>("DetailDateText")!;
            _detailTypeText = this.FindControl<TextBlock>("DetailTypeText")!;
            _detailComponentText = this.FindControl<TextBlock>("DetailComponentText")!;
            _detailThreadText = this.FindControl<TextBlock>("DetailThreadText")!;
            _pauseBtn = this.FindControl<ToggleButton>("PauseBtn")!;
            _scrollBtn = this.FindControl<ToggleButton>("ScrollBtn")!;
            _searchCountText = this.FindControl<TextBlock>("SearchCountText")!;
            _clearFilterBtn = this.FindControl<Button>("ClearFilterBtn")!;
            _pauseIcon = this.FindControl<Avalonia.Controls.Shapes.Path>("PauseIcon")!;
            _playIcon = this.FindControl<Avalonia.Controls.Shapes.Path>("PlayIcon")!;
            _scrollIcon = this.FindControl<Avalonia.Controls.Shapes.Path>("ScrollIcon")!;
            _sortTypeBtn = this.FindControl<Button>("SortTypeBtn")!;
            _sortCountBtn = this.FindControl<Button>("SortCountBtn")!;
            _sortPctBtn = this.FindControl<Button>("SortPctBtn")!;

            Width = Math.Max(400, _config.WindowWidth);
            Height = Math.Max(300, _config.WindowHeight);
            SetDetailRowHeight(_config.BottomPanelHeight);

            // Dark only: App pinned the dark variant at startup and
            // the chrome brushes in App.axaml carry the Atrium
            // palette, so there is nothing theme-related to apply
            // here.

            _logGrid.ItemsSource = _master;
            _logGrid.LoadingRow += OnGridLoadingRow;
            _logGrid.SelectionChanged += OnGridSelectionChanged;

            ApplyFontSettings();
            ApplyUiScale();
            UpdateDetailPane(null);
            UpdatePauseVisual();
            UpdateScrollVisual();
            RebuildFilterBar();
            UpdateSortButtonLabels();
            RefreshStats();

            WireEvents();
            SetupDragAndDrop();

            _searchTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(200) };
            _searchTimer.Tick += (_, _) =>
            {
                _searchTimer.Stop();
                ApplyLiveSearch();
            };

            _drainTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(50) };
            _drainTimer.Tick += OnDrainTick;
            _statsTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
            _statsTimer.Tick += (_, _) =>
            {
                if (_statsDirty) { RefreshStats(); _statsDirty = false; }
                ShowTailErrorIfNew();
            };
            _statsTimer.Start();

            Closed += OnWindowClosed;
        }

        // ------------------------------------------------------------------
        // Wiring
        // ------------------------------------------------------------------

        private void WireEvents()
        {
            this.FindControl<MenuItem>("OpenMenu")!.Click += async (_, _) => await PickAndOpenFileAsync();
            this.FindControl<MenuItem>("OpenRemoteMenu")!.Click += async (_, _) => await ShowRemoteOpenAsync();
            this.FindControl<MenuItem>("ExitMenu")!.Click += (_, _) => Close();
            this.FindControl<Button>("OpenStripBtn")!.Click += async (_, _) => await PickAndOpenFileAsync();
            this.FindControl<Button>("PrevBtn")!.Click += (_, _) => DoFindPrevious();
            this.FindControl<MenuItem>("SettingsMenu")!.Click += async (_, _) => await ShowSettingsAsync();
            this.FindControl<MenuItem>("ContextCopyMenu")!.Click += async (_, _) => await CopySelectedRowsAsync();
            this.FindControl<Button>("CopyAllBtn")!.Click += async (_, _) => await CopyAllLogsAsync();
            this.FindControl<Button>("OpenLogOverlayBtn")!.Click += async (_, _) => await PickAndOpenFileAsync();
            _overlay.PointerPressed += async (_, _) => await PickAndOpenFileAsync();

            this.FindControl<Button>("SearchBtn")!.Click += (_, _) => DoFind();
            this.FindControl<Button>("ClearSearchBtn")!.Click += (_, _) =>
            {
                _searchBox.Text = "";
                _logGrid.Focus();
            };
            _searchBox.KeyDown += (_, e) =>
            {
                // Enter cycles through the matches, one match per
                // press, wrapping at the ends; Shift+Enter walks
                // backwards. Both key values are accepted: Avalonia
                // reports the main Enter key as Return and the
                // keypad key as Enter, and checking only Enter left
                // the main key dead (Brandon, Nov 22).
                if (e.Key == Key.Return || e.Key == Key.Enter)
                {
                    if (e.KeyModifiers.HasFlag(KeyModifiers.Shift)) DoFindPrevious();
                    else DoFind();
                    e.Handled = true;
                }
            };
            // Live search: every text change restarts the debounce
            // timer; when it fires, matches are located and counted
            // without the user pressing anything.
            _searchBox.PropertyChanged += (_, e) =>
            {
                if (e.Property == TextBox.TextProperty && _searchTimer != null)
                {
                    _searchTimer.Stop();
                    _searchTimer.Start();
                }
            };
            _clearFilterBtn.Click += (_, _) => ClearExclusiveFilter();

            _pauseBtn.IsCheckedChanged += (_, _) =>
            {
                _paused = _pauseBtn.IsChecked == true;
                UpdatePauseVisual();
                UpdateStatus();
            };
            _scrollBtn.IsCheckedChanged += (_, _) =>
            {
                UpdateScrollVisual();
                // Turning auto-scroll on snaps the view to the newest
                // entry right away, like CMTrace.
                if (_scrollBtn.IsChecked == true) RequestAutoScroll();
            };
            this.FindControl<Button>("CopyDetailBtn")!.Click += async (_, _) => await CopyTextAsync(_detailText.Text ?? "");

            _sortTypeBtn.Click += (_, _) => SetStatsSort("Type");
            _sortCountBtn.Click += (_, _) => SetStatsSort("Count");
            _sortPctBtn.Click += (_, _) => SetStatsSort("Percentage");

            KeyDown += (_, e) =>
            {
                if (e.KeyModifiers.HasFlag(KeyModifiers.Control) && e.Key == Key.O)
                {
                    _ = PickAndOpenFileAsync();
                    e.Handled = true;
                }
                else if (e.KeyModifiers.HasFlag(KeyModifiers.Control) && e.Key == Key.F)
                {
                    FocusSearch();
                    e.Handled = true;
                }
            };
        }

        // ------------------------------------------------------------------
        // Theme: dark only, themed after the Atrium client. The
        // variant is pinned in App, the chrome colours live in the
        // App.axaml resources (DynamicResource), and the severity
        // colours painted in code come from AppConfig's single dark
        // palette. There is no toggle and nothing to restyle.
        // ------------------------------------------------------------------

        // ------------------------------------------------------------------
        // Icon-only transport buttons: the icon and the tooltip carry the
        // state, there is no text on either button. Pause swaps between
        // pause bars (running, click to pause) and a play triangle
        // (paused, click to resume). Auto-scroll keeps one glyph and
        // shows its state by highlight and opacity.
        // ------------------------------------------------------------------

        private void UpdatePauseVisual()
        {
            bool paused = _pauseBtn.IsChecked == true;
            _pauseIcon.IsVisible = !paused;
            _playIcon.IsVisible = paused;
            ToolTip.SetTip(_pauseBtn, paused ? "Resume auto-refresh" : "Pause auto-refresh");
        }

        private void UpdateScrollVisual()
        {
            bool on = _scrollBtn.IsChecked == true;
            _scrollIcon.Opacity = on ? 1.0 : 0.4;
            // The "on" wash is the Atrium accent (the selection
            // colour); the "off" wash is a neutral step up from the
            // strip's chrome colour.
            _scrollBtn.Background = on
                ? GetBrush("#FF1C58D9")
                : GetBrush("#FF2B3948");
            ToolTip.SetTip(_scrollBtn, on ? "Auto-scroll: on" : "Auto-scroll: off");
        }

        // ------------------------------------------------------------------
        // Feature B: drag and drop files onto the running window.
        // The window accepts file drops at any time, not only on the
        // empty-state overlay. The first dropped file is opened; any
        // additional files are reported in the status bar, not opened.
        // ------------------------------------------------------------------

        private void SetupDragAndDrop()
        {
            DragDrop.SetAllowDrop(this, true);
            AddHandler(DragDrop.DragOverEvent, OnDragOver);
            AddHandler(DragDrop.DragEnterEvent, OnDragOver);
            AddHandler(DragDrop.DropEvent, OnDrop);
        }

        private void OnDragOver(object? sender, DragEventArgs e)
        {
            e.DragEffects = e.Data.Contains(DataFormats.Files)
                ? DragDropEffects.Copy
                : DragDropEffects.None;
            e.Handled = true;
        }

        private void OnDrop(object? sender, DragEventArgs e)
        {
            e.Handled = true;
            var paths = ExtractDroppedPaths(e);
            if (paths.Count == 0) return;
            OpenLogFile(paths[0]);
            if (paths.Count > 1)
            {
                _statusText.Text = $"Opened {paths[0]} ({paths.Count - 1} other dropped file(s) not opened).";
            }
        }

        private static List<string> ExtractDroppedPaths(DragEventArgs e)
        {
            var result = new List<string>();
            try
            {
                var files = e.Data.GetFiles();
                if (files != null)
                {
                    foreach (var item in files.OfType<IStorageFile>())
                    {
                        string path = item.Path.LocalPath;
                        if (string.IsNullOrEmpty(path)) continue;
                        // A dropped network file arrives as a UNC path.
                        // Do not probe it with File.Exists on the UI
                        // thread: a dead host would stall the window for
                        // the whole SMB timeout. The tailer reports
                        // reachability instead.
                        if (RemoteLogPath.IsUnc(path) || File.Exists(path)) result.Add(path);
                    }
                }
            }
            catch (Exception ex)
            {
                ErrorLog.Report("DragDrop", $"Could not read dropped files: {ex.Message}");
            }
            return result;
        }

        // ------------------------------------------------------------------
        // Opening files (picker, command line via App, drag and drop)
        // ------------------------------------------------------------------

        public void OpenLogFile(string path)
        {
            try
            {
                StopTailing();
                _master.Clear();
                _display.Clear();
                _anyComponent = false;
                _anyThread = false;
                UpdateDetailPane(null);
                _currentFile = path;
                _config.LastLogFile = path;
                Title = $"Configuration Manager Trace Log Tool - {Path.GetFileName(path)}";
                _overlay.IsVisible = false;
                _initialFlushing = true;
                _lastShownTailError = null;

                _tailer = new LogTailer(path, _config.BuildOrderedKeywords(), PollIntervalMs);
                _tailer.Start();
                if (_drainTimer != null)
                {
                    _drainTimer.Interval = TimeSpan.FromMilliseconds(50);
                    _drainTimer.Start();
                }
                _statsDirty = true;
                UpdateStatus();
            }
            catch (Exception ex)
            {
                ErrorLog.Report("OpenLogFile", $"Could not open '{path}': {ex.Message}");
                _statusText.Text = $"Could not open {path}: {ex.Message}";
            }
        }

        private async Task PickAndOpenFileAsync()
        {
            try
            {
                var options = new FilePickerOpenOptions
                {
                    Title = "Open log file",
                    AllowMultiple = false,
                    FileTypeFilter = new[]
                    {
                        new FilePickerFileType("Log files") { Patterns = new[] { "*.log", "*.txt" } },
                        new FilePickerFileType("All files") { Patterns = new[] { "*" } },
                    },
                };
                var files = await StorageProvider.OpenFilePickerAsync(options);
                if (files.Count > 0)
                {
                    string path = files[0].Path.LocalPath;
                    if (!string.IsNullOrEmpty(path)) OpenLogFile(path);
                }
            }
            catch (Exception ex)
            {
                ErrorLog.Report("OpenFilePicker", ex.Message);
            }
        }

        // ------------------------------------------------------------------
        // Remote open: File, Open Remote asks for a computer name and a
        // path on that computer and builds a UNC path (\\computer\path).
        // The result goes through the same OpenLogFile path as a local
        // file, so the FileShare.ReadWrite tailer, filters, and stats
        // behave identically over SMB. Typing a full UNC path into the
        // dialog works too: RemoteLogPath.Build passes it through.
        // ------------------------------------------------------------------

        private async Task ShowRemoteOpenAsync()
        {
            try
            {
                var dialog = new RemoteOpenWindow();
                string? unc = await dialog.ShowDialog<string?>(this);
                if (!string.IsNullOrEmpty(unc)) OpenLogFile(unc);
            }
            catch (Exception ex)
            {
                ErrorLog.Report("OpenRemote", ex.Message);
                _statusText.Text = $"Could not open remote log: {ex.Message}";
            }
        }

        private void StopTailing()
        {
            _drainTimer?.Stop();
            _tailer?.Dispose();
            _tailer = null;
        }

        // ------------------------------------------------------------------
        // Tailing drain: move parsed entries from the tailer queue into
        // the master list in bounded batches, mirroring the original
        // viewer's MaxDrainPerTick behaviour.
        // ------------------------------------------------------------------

        private void OnDrainTick(object? sender, EventArgs e)
        {
            if (_tailer == null) return;

            if (!_paused && _tailer.Queue.Count > 0)
            {
                var batch = new List<LogEntry>(Math.Min(_tailer.Queue.Count, MaxDrainPerTick));
                while (batch.Count < MaxDrainPerTick && _tailer.Queue.TryDequeue(out var entry))
                {
                    batch.Add(entry);
                }

                if (batch.Count > 0)
                {
                    _master.AddRange(batch);
                    if (!FilterIsBypass)
                    {
                        _display.AddRange(LogParser.FilterEntries(batch, _activeFilter));
                    }
                    TrimMasterIfNeeded();
                    _statsDirty = true;
                    TrackColumnUsage(batch);
                    UpdateColumnVisibility();

                    // New lines can change the live search results:
                    // refresh the count (debounced, like typing)
                    // without moving the selection.
                    if (!string.IsNullOrEmpty(_searchBox.Text) && _searchTimer != null)
                    {
                        _searchTimer.Stop();
                        _searchTimer.Start();
                    }

                    RequestAutoScroll();
                    UpdateStatus();
                }
            }

            if (_initialFlushing && _tailer.InitialLoadComplete && _tailer.Queue.Count == 0)
            {
                _initialFlushing = false;
                _drainTimer!.Interval = TimeSpan.FromMilliseconds(SpeedToIntervalMs(_config.UpdateSpeed));
                // One final pin to the bottom once the initial load has
                // fully drained, so a freshly opened log opens at its
                // newest entry when auto-scroll is on.
                RequestAutoScroll();
                // With auto-scroll on, the view sits on the newest
                // entry: select it too, so the details pane opens
                // populated on that entry instead of showing its
                // empty placeholder state over a full pane.
                SelectLastEntryIfAutoScroll();
                UpdateStatus();
            }
        }

        private void TrackColumnUsage(List<LogEntry> batch)
        {
            foreach (var entry in batch)
            {
                if (entry.Component.Length > 0) _anyComponent = true;
                if (entry.Thread.Length > 0) _anyThread = true;
                if (_anyComponent && _anyThread) break;
            }
        }

        // The Component and Thread columns earn their width only when
        // the loaded file actually carries those values (CMTrace logs
        // do; plain and bracket-format logs do not, and there the two
        // empty columns cost roughly 270 px of log text). Visibility
        // follows the entries seen so far and is re-evaluated as each
        // batch lands, so a column appears the moment a value for it
        // shows up.
        private void UpdateColumnVisibility()
        {
            foreach (var column in _logGrid.Columns)
            {
                if (column.Header as string == "Component") column.IsVisible = _anyComponent;
                else if (column.Header as string == "Thread") column.IsVisible = _anyThread;
            }
        }

        private void SelectLastEntryIfAutoScroll()
        {
            if (_scrollBtn.IsChecked != true) return;
            var items = CurrentItems();
            if (items == null || items.Count == 0) return;
            _logGrid.SelectedItem = items[items.Count - 1];
        }

        // ------------------------------------------------------------------
        // Auto-scroll: when the toggle is on, appended entries pin the
        // view to the last row. The scroll itself is posted to the
        // dispatcher at Loaded priority so it runs after the grid has
        // laid out the new rows; calling ScrollIntoView synchronously
        // from the drain raced layout and virtualisation and left the
        // viewport parked on older rows while the file kept growing.
        // Requests coalesce: at most one posted scroll is outstanding.
        // With the toggle on, new data always returns the view to the
        // bottom even if the user scrolled up meanwhile (CMTrace
        // behaviour); with it off, appends never move the viewport.
        // Scrolling does not change the selection, so it never fights
        // the details pane.
        // ------------------------------------------------------------------

        private bool _autoScrollPending;

        private void RequestAutoScroll()
        {
            if (_scrollBtn.IsChecked != true || _autoScrollPending) return;
            _autoScrollPending = true;
            Dispatcher.UIThread.Post(() =>
            {
                if (_scrollBtn.IsChecked == true) ScrollToEnd();
                // Second pass once the first scroll has laid out the
                // tail rows, so the pin lands exactly on the bottom
                // even when the first pass worked from estimated
                // positions.
                Dispatcher.UIThread.Post(() =>
                {
                    _autoScrollPending = false;
                    if (_scrollBtn.IsChecked == true) ScrollToEnd();
                }, DispatcherPriority.Loaded);
            }, DispatcherPriority.Loaded);
        }

        private void ScrollToEnd()
        {
            var items = CurrentItems();
            if (items == null || items.Count == 0) return;
            // Realise the last row first (the grid virtualises, so it
            // may not exist yet), then drive the grid's own vertical
            // scroll bar to its maximum: ScrollIntoView alone can stop
            // short when it runs before the final layout pass. The
            // DataGrid template has no ScrollViewer; its scroll bar is
            // the scroll state.
            _logGrid.ScrollIntoView(items[items.Count - 1], null);
            var bar = _logGrid.GetVisualDescendants().OfType<ScrollBar>()
                .FirstOrDefault(sb => sb.Name == "PART_VerticalScrollbar");
            if (bar != null && bar.Maximum > 0 && bar.Value < bar.Maximum)
            {
                bar.Value = bar.Maximum;
            }
        }

        private static int SpeedToIntervalMs(int speed)
        {
            switch (Math.Clamp(speed, 1, 5))
            {
                case 1: return 500;
                case 2: return 250;
                case 3: return 100;
                case 4: return 50;
                default: return 25;
            }
        }

        private void TrimMasterIfNeeded()
        {
            if (_master.Count <= TrimThreshold) return;
            int excess = _master.Count - MaxRetainedEntries;
            var remaining = _master.Skip(excess).ToList();
            _master.ReplaceAll(remaining);
            ApplyFilter();
            ErrorLog.Report("TrimMasterList", $"Trimmed {excess} oldest entries at the {MaxRetainedEntries} retention cap.");
        }

        // ------------------------------------------------------------------
        // Filtering
        // ------------------------------------------------------------------

        private bool FilterIsBypass => _activeFilter.Values.All(v => v);

        private void RebuildFilterBar()
        {
            _filterPanel.Children.Clear();
            _chips.Clear();

            var allBtn = new Button { Content = "All", Margin = new Thickness(0, 0, 6, 0), Padding = new Thickness(10, 3, 10, 3), CornerRadius = new CornerRadius(6), FontSize = 12, HorizontalContentAlignment = Avalonia.Layout.HorizontalAlignment.Center, VerticalContentAlignment = Avalonia.Layout.VerticalAlignment.Center };
            allBtn.Click += (_, _) => ClearExclusiveFilter();
            _filterPanel.Children.Add(allBtn);

            var levels = new List<string>();
            foreach (var kv in _config.BuildOrderedKeywords())
            {
                if (!levels.Contains(kv.Key, StringComparer.OrdinalIgnoreCase)) levels.Add(kv.Key);
            }
            foreach (string extra in new[] { LogLevels.Error, LogLevels.Warning, LogLevels.Info, LogLevels.Verbose })
            {
                if (!levels.Contains(extra, StringComparer.OrdinalIgnoreCase)) levels.Add(extra);
            }
            foreach (var entry in _master)
            {
                if (!levels.Contains(entry.Level, StringComparer.OrdinalIgnoreCase)) levels.Add(entry.Level);
            }

            foreach (string level in levels)
            {
                if (!_activeFilter.ContainsKey(level)) _activeFilter[level] = true;
                var chip = new ToggleButton
                {
                    Content = level,
                    Tag = level,
                    IsChecked = _activeFilter[level],
                };
                chip.Classes.Add("chip");
                StyleChip(chip, level);
                chip.IsCheckedChanged += (_, _) =>
                {
                    _activeFilter[level] = chip.IsChecked == true;
                    StyleChip(chip, level);
                    // While the statistics panel or the Clear filter
                    // button is driving the chips, the batch applies
                    // the filter once at the end, not per chip.
                    if (!_syncingFilter) ApplyFilter();
                };
                _chips[level] = chip;
                _filterPanel.Children.Add(chip);
            }
        }

        // Chip state must read at a glance: an included level is a
        // filled chip in the level's own palette pair (deep fill,
        // pale text) with a saturated border; an excluded level is
        // an unfilled chip a step up from the band colour with
        // muted but still legible text and a grey outline. (The
        // App.axaml chip style hands the checked chip's template
        // presenter back this Background: the Fluent theme would
        // otherwise paint every checked chip the same accent blue
        // and hide the state colours entirely.)
        private void StyleChip(ToggleButton chip, string level)
        {
            if (chip.IsChecked == true)
            {
                chip.Background = GetBrush(BackgroundHexFor(level));
                chip.Foreground = GetBrush(TextHexFor(level));
                chip.BorderBrush = GetBrush(StripeHexFor(level));
            }
            else
            {
                chip.Background = GetBrush("#FF1E2938");
                chip.Foreground = GetBrush("#FF8B95A1");
                chip.BorderBrush = GetBrush("#FF3A4656");
            }
            chip.BorderThickness = new Thickness(1);
        }

        private void ApplyFilter()
        {
            if (FilterIsBypass)
            {
                if (!ReferenceEquals(_logGrid.ItemsSource, _master)) _logGrid.ItemsSource = _master;
            }
            else
            {
                var filtered = LogParser.FilterEntries(_master.ToList(), _activeFilter);
                _display.ReplaceAll(filtered);
                if (!ReferenceEquals(_logGrid.ItemsSource, _display)) _logGrid.ItemsSource = _display;
            }
            SyncExclusiveState();
            RequestAutoScroll();
            UpdateStatus();
        }

        // ------------------------------------------------------------------
        // Exclusive filter from the statistics panel: clicking a type
        // row shows ONLY that type. The chips are driven to the same
        // state (under the sync guard, so the batch applies once),
        // and the statistics panel highlights the active row. The
        // Clear filter button under the statistics (and the chips'
        // All button) restores every type through ClearExclusiveFilter.
        // SyncExclusiveState keeps the highlight honest when the
        // chips are used directly: any filter state with exactly one
        // active level reads as that level's exclusive filter.
        // ------------------------------------------------------------------

        private void ApplyExclusiveLevelFilter(string level)
        {
            _syncingFilter = true;
            try
            {
                foreach (var key in _activeFilter.Keys.ToList())
                {
                    _activeFilter[key] = key.Equals(level, StringComparison.OrdinalIgnoreCase);
                }
                foreach (var kv in _chips)
                {
                    kv.Value.IsChecked = _activeFilter.TryGetValue(kv.Key, out var on) && on;
                }
            }
            finally
            {
                _syncingFilter = false;
            }
            ApplyFilter();
        }

        private void ClearExclusiveFilter()
        {
            _syncingFilter = true;
            try
            {
                foreach (var key in _activeFilter.Keys.ToList()) _activeFilter[key] = true;
                foreach (var chip in _chips.Values) chip.IsChecked = true;
            }
            finally
            {
                _syncingFilter = false;
            }
            ApplyFilter();
        }

        private void SyncExclusiveState()
        {
            var active = _activeFilter.Where(kv => kv.Value).Select(kv => kv.Key).ToList();
            string? exclusive = active.Count == 1 ? active[0] : null;
            if (!string.Equals(exclusive, _exclusiveLevel, StringComparison.OrdinalIgnoreCase))
            {
                _exclusiveLevel = exclusive;
                RefreshStats();
            }
        }

        // ------------------------------------------------------------------
        // Row styling: the active theme's palette background and
        // foreground per level, applied as rows are realised so recycled rows always
        // repaint. A selected row switches to the solid dark selection
        // background with white text, set here as local values: the
        // row template's border paints the row's Background, so this
        // is the layer that actually renders, and setting it in code
        // also stops a severity background realised earlier from
        // showing through (App.axaml carries the same colours in its
        // :selected styles for rows this pass has not reached). The
        // severity signal survives selection as a saturated stripe in
        // the row's left border, so a selected Error or Warn row is
        // still identifiable at a glance and stays readable, unlike
        // the old translucent accent wash over severity-coloured text.
        // ------------------------------------------------------------------

        private const string SelectionBackgroundHex = "#FF1C58D9";

        private void OnGridLoadingRow(object? sender, DataGridRowEventArgs e)
        {
            StyleRow(e.Row);
        }

        private void StyleRow(DataGridRow row)
        {
            if (row.DataContext is not LogEntry entry) return;
            bool selected = _logGrid.SelectedItems.Contains(entry);
            row.BorderBrush = GetBrush(StripeHexFor(entry.Level));
            row.BorderThickness = new Thickness(3, 0, 0, 0);
            if (selected)
            {
                row.Background = GetBrush(SelectionBackgroundHex);
                row.Foreground = GetBrush("#FFFFFFFF");
            }
            else
            {
                row.Background = GetBrush(BackgroundHexFor(entry.Level));
                row.Foreground = GetBrush(TextHexFor(entry.Level));
            }
        }

        private void RestyleRealisedRows()
        {
            foreach (var row in _logGrid.GetVisualDescendants().OfType<DataGridRow>())
            {
                StyleRow(row);
            }
        }

        // All three lookups go through the single dark palette: the
        // colour NAME comes from the keyword map as before, the hex
        // from the dark map in AppConfig.
        private string StripeHexFor(string level)
        {
            var map = AppConfig.Stripes();
            if (_config.Keywords.TryGetValue(level, out var colorName) &&
                map.TryGetValue(colorName, out var hex))
            {
                return hex;
            }
            return map["White"];
        }

        private string BackgroundHexFor(string level)
        {
            var map = AppConfig.RowBackgrounds();
            if (_config.Keywords.TryGetValue(level, out var colorName) &&
                map.TryGetValue(colorName, out var hex))
            {
                return hex;
            }
            return map["White"];
        }

        // The statistics swatch for the neutral level (Info, whose
        // colour name is "White") gets a filled neutral grey: its
        // row fill is a near-surface dark grey, which reads as an
        // empty checkbox next to the filled swatches, and a mid
        // grey reads clearer. The row colours themselves are
        // unchanged.
        private string SwatchHexFor(string level)
        {
            // 2026 redesign: the statistics dot is the saturated
            // stripe colour, the same signal the grid rows carry in
            // their left border, so the two views agree at a glance.
            return StripeHexFor(level);
        }

        private string TextHexFor(string level)
        {
            // The neutral level (keyword colour White: the Info
            // bulk of the log) paints in the user's configured text
            // colour; severity levels keep their palette tints.
            if (_config.Keywords.TryGetValue(level, out var colorName) &&
                colorName.Equals("White", StringComparison.OrdinalIgnoreCase))
            {
                return _effectiveTextColorHex;
            }
            var map = AppConfig.RowForegrounds();
            if (colorName != null && map.TryGetValue(colorName, out var hex))
            {
                return hex;
            }
            return map["White"];
        }

        private IBrush GetBrush(string hex)
        {
            if (!_brushCache.TryGetValue(hex, out var brush))
            {
                brush = new SolidColorBrush(Color.Parse(hex));
                _brushCache[hex] = brush;
            }
            return brush;
        }

        private void RefreshRowStyling()
        {
            var source = _logGrid.ItemsSource;
            _logGrid.ItemsSource = null;
            _logGrid.ItemsSource = source;
        }

        // ------------------------------------------------------------------
        // Selection, detail panel, search, copy
        // ------------------------------------------------------------------

        private void OnGridSelectionChanged(object? sender, SelectionChangedEventArgs e)
        {
            UpdateDetailPane(_logGrid.SelectedItem as LogEntry);
            // Selection is part of row styling (white text and the
            // severity stripe while selected): repaint the realised
            // rows so the row that lost selection gets its severity
            // colours back and the new one switches.
            RestyleRealisedRows();
        }

        // The details pane: structured fields for the selected entry
        // (time, date, type, component, thread, in the CMTrace info
        // pane style) above the formatted message body. Copy to
        // Clipboard still copies the body text, as before.
        private void UpdateDetailPane(LogEntry? entry)
        {
            if (entry == null)
            {
                _detailTimeText.Text = "-";
                _detailDateText.Text = "-";
                _detailTypeText.Text = "-";
                _detailComponentText.Text = "-";
                _detailThreadText.Text = "-";
                _detailText.Text = "";
                return;
            }
            _detailTimeText.Text = OrDash(entry.Time);
            _detailDateText.Text = OrDash(entry.Date);
            _detailTypeText.Text = entry.TypeVal is "1" or "2" or "3"
                ? $"{entry.Level} (type {entry.TypeVal})"
                : entry.Level;
            _detailComponentText.Text = OrDash(entry.Component);
            _detailThreadText.Text = OrDash(entry.Thread);
            _detailText.Text = DetailFormatter.Format(entry.RawMsg, _config);
        }

        private static string OrDash(string value) => string.IsNullOrEmpty(value) ? "-" : value;

        private IList<LogEntry>? CurrentItems() => _logGrid.ItemsSource as IList<LogEntry>;

        private void FocusSearch()
        {
            _searchBox.Focus();
            _searchBox.SelectAll();
        }

        // Search covers the WHOLE list and every shown field (log
        // text, message, component, thread, type, time), never just
        // the region below the current row (Brandon, Nov 22). A new
        // search text always starts from the top of the file; Next
        // and Previous walk the matches and wrap around the ends:
        // Next past the last match scrolls back to the top and
        // continues to the first match, Previous before the first
        // match wraps to the last.
        private List<int> CurrentMatchIndices()
        {
            var result = new List<int>();
            var items = CurrentItems();
            string text = _searchBox.Text ?? "";
            if (items == null || text.Length == 0) return result;
            for (int i = 0; i < items.Count; i++)
            {
                var e = items[i];
                if (e.DisplayText.Contains(text, StringComparison.OrdinalIgnoreCase) ||
                    e.RawMsg.Contains(text, StringComparison.OrdinalIgnoreCase) ||
                    e.Message.Contains(text, StringComparison.OrdinalIgnoreCase) ||
                    e.Component.Contains(text, StringComparison.OrdinalIgnoreCase) ||
                    e.Thread.Contains(text, StringComparison.OrdinalIgnoreCase) ||
                    e.Level.Contains(text, StringComparison.OrdinalIgnoreCase) ||
                    e.Time.Contains(text, StringComparison.OrdinalIgnoreCase))
                {
                    result.Add(i);
                }
            }
            return result;
        }

        private void UpdateSearchCount(int matches, bool hasText)
        {
            _searchCountText.Text = !hasText ? ""
                : matches == 0 ? "No matches"
                : matches == 1 ? "1 match"
                : $"{matches} matches";
        }

        private void ApplyLiveSearch()
        {
            string text = _searchBox.Text ?? "";
            if (text.Length == 0)
            {
                _lastSearchText = "";
                UpdateSearchCount(0, false);
                return;
            }
            var matches = CurrentMatchIndices();
            UpdateSearchCount(matches.Count, true);
            if (matches.Count == 0) { _lastSearchText = text; return; }
            var items = CurrentItems()!;
            // A changed text restarts from the top of the file, so
            // the first match overall is selected; an unchanged text
            // (a re-run of the debounce tick) keeps the match at or
            // after the current row.
            int target = text != _lastSearchText
                ? matches[0]
                : matches.FirstOrDefault(m => m >= _logGrid.SelectedIndex, matches[0]);
            _lastSearchText = text;
            _logGrid.SelectedIndex = target;
            _logGrid.ScrollIntoView(items[target], null);
        }

        private void DoFind()
        {
            var items = CurrentItems();
            if (items == null || items.Count == 0) return;
            string text = _searchBox.Text ?? "";
            if (text.Length == 0) return;
            var matches = CurrentMatchIndices();
            UpdateSearchCount(matches.Count, true);
            if (matches.Count == 0)
            {
                _statusText.Text = $"Not found: {text}";
                return;
            }
            // New text: start at the first match in the file. Same
            // text: the next match after the current row, wrapping
            // past the end back to the top of the file.
            int target = text != _lastSearchText
                ? matches[0]
                : matches.FirstOrDefault(m => m > _logGrid.SelectedIndex, matches[0]);
            _lastSearchText = text;
            _logGrid.SelectedIndex = target;
            _logGrid.ScrollIntoView(items[target], null);
        }

        private void DoFindPrevious()
        {
            var items = CurrentItems();
            if (items == null || items.Count == 0) return;
            string text = _searchBox.Text ?? "";
            if (text.Length == 0) return;
            var matches = CurrentMatchIndices();
            UpdateSearchCount(matches.Count, true);
            if (matches.Count == 0)
            {
                _statusText.Text = $"Not found: {text}";
                return;
            }
            // New text: start at the last match in the file. Same
            // text: the previous match before the current row,
            // wrapping past the top back to the last match.
            int target = text != _lastSearchText
                ? matches[matches.Count - 1]
                : matches.LastOrDefault(m => m < _logGrid.SelectedIndex, matches[matches.Count - 1]);
            _lastSearchText = text;
            _logGrid.SelectedIndex = target;
            _logGrid.ScrollIntoView(items[target], null);
        }

        private async Task CopySelectedRowsAsync()
        {
            var selected = _logGrid.SelectedItems.OfType<LogEntry>().ToList();
            if (selected.Count == 0 && _logGrid.SelectedItem is LogEntry single) selected.Add(single);
            if (selected.Count == 0) return;
            var sb = new StringBuilder();
            foreach (var entry in selected) sb.AppendLine(entry.Message);
            await CopyTextAsync(sb.ToString());
        }

        // Every loaded log line, filter or no filter: the text the
        // Copy All toolbar button puts on the clipboard.
        private string AllLogText()
        {
            var sb = new StringBuilder();
            foreach (var entry in _master) sb.AppendLine(entry.Message);
            return sb.ToString();
        }

        private async Task CopyAllLogsAsync()
        {
            if (_master.Count == 0) return;
            await CopyTextAsync(AllLogText());
            _statusText.Text = $"Copied {_master.Count} log lines to the clipboard.";
        }

        private async Task CopyTextAsync(string text)
        {
            try
            {
                var topLevel = TopLevel.GetTopLevel(this);
                if (topLevel?.Clipboard != null) await topLevel.Clipboard.SetTextAsync(text);
            }
            catch (Exception ex)
            {
                ErrorLog.Report("Copy-ToClipboard", ex.Message);
            }
        }

        // ------------------------------------------------------------------
        // Statistics panel
        // ------------------------------------------------------------------

        private void SetStatsSort(string column)
        {
            if (_config.StatsSortColumn == column)
            {
                _config.StatsSortDirection = _config.StatsSortDirection == "Ascending" ? "Descending" : "Ascending";
            }
            else
            {
                _config.StatsSortColumn = column;
                _config.StatsSortDirection = "Ascending";
            }
            UpdateSortButtonLabels();
            RefreshStats();
        }

        private void UpdateSortButtonLabels()
        {
            // ASCII only: the previous build used unicode triangle glyphs
            // here, which rendered as garbled characters on Windows.
            string Arrow(string col) => _config.StatsSortColumn == col
                ? (_config.StatsSortDirection == "Ascending" ? " ^" : " v")
                : "";
            _sortTypeBtn.Content = "Type" + Arrow("Type");
            _sortCountBtn.Content = "Count" + Arrow("Count");
            _sortPctBtn.Content = "%" + Arrow("Percentage");
        }

        private void RefreshStats()
        {
            var stats = LogParser.GetLevelStatistics(_master);
            bool desc = _config.StatsSortDirection == "Descending";
            switch (_config.StatsSortColumn)
            {
                case "Count":
                    stats.Sort((a, b) => desc ? b.Count.CompareTo(a.Count) : a.Count.CompareTo(b.Count));
                    break;
                case "Percentage":
                    stats.Sort((a, b) => desc ? b.Percentage.CompareTo(a.Percentage) : a.Percentage.CompareTo(b.Percentage));
                    break;
                default:
                    stats.Sort((a, b) => desc
                        ? string.Compare(b.Level, a.Level, StringComparison.OrdinalIgnoreCase)
                        : string.Compare(a.Level, b.Level, StringComparison.OrdinalIgnoreCase));
                    break;
            }

            _statsPanel.Children.Clear();
            foreach (var row in stats)
            {
                var grid = new Grid
                {
                    ColumnDefinitions = new ColumnDefinitions("*,56,54"),
                    Margin = new Thickness(12, 4, 12, 4),
                    // Transparent, not null: a null background is not
                    // hit-testable, which made only the row's text and
                    // swatch clickable instead of the whole row.
                    Background = Brushes.Transparent,
                };
                var namePanel = new StackPanel { Orientation = Avalonia.Layout.Orientation.Horizontal, Spacing = 8 };
                namePanel.Children.Add(new Border
                {
                    Width = 8,
                    Height = 8,
                    CornerRadius = new CornerRadius(4),
                    VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center,
                    Background = GetBrush(SwatchHexFor(row.Level)),
                });
                namePanel.Children.Add(new TextBlock { Text = row.Level, FontSize = 12, VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center });
                grid.Children.Add(namePanel);

                var countText = new TextBlock { Text = row.Count.ToString("N0"), FontSize = 12, TextAlignment = TextAlignment.Right, VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center };
                Grid.SetColumn(countText, 1);
                grid.Children.Add(countText);

                var pctText = new TextBlock { Text = row.Percentage.ToString("0.0") + "%", FontSize = 12, TextAlignment = TextAlignment.Right, Foreground = GetBrush("#FF9BA3AC"), VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center };
                Grid.SetColumn(pctText, 2);
                grid.Children.Add(pctText);

                // The whole row is a click target: clicking a type
                // filters the grid to only that type (see
                // ApplyExclusiveLevelFilter), so it carries the hand
                // cursor and a tooltip, and while its filter is the
                // active one the row is highlighted with the accent
                // edge and a raised panel fill.
                bool isExclusive = _exclusiveLevel != null &&
                    _exclusiveLevel.Equals(row.Level, StringComparison.OrdinalIgnoreCase);
                var rowBorder = new Border
                {
                    BorderBrush = isExclusive ? GetBrush("#FF1C58D9") : GetBrush("#FF2A3644"),
                    BorderThickness = isExclusive ? new Thickness(3, 0, 0, 1) : new Thickness(0, 0, 0, 1),
                    // The whole row is the click target (Brandon,
                    // Nov 22): the border must carry a background or
                    // the empty parts of the row never see the press.
                    Background = isExclusive ? GetBrush("#FF24344A") : Brushes.Transparent,
                    Cursor = new Cursor(StandardCursorType.Hand),
                    Tag = row.Level,
                    Child = grid,
                };
                ToolTip.SetTip(rowBorder, $"Show only {row.Level}");
                string level = row.Level;
                rowBorder.PointerPressed += (_, e) =>
                {
                    if (e.GetCurrentPoint(rowBorder).Properties.IsLeftButtonPressed)
                    {
                        ApplyExclusiveLevelFilter(level);
                    }
                };
                _statsPanel.Children.Add(rowBorder);
            }
            _totalCountText.Text = _master.Count.ToString("N0");
        }

        // ------------------------------------------------------------------
        // Settings
        // ------------------------------------------------------------------

        private async Task ShowSettingsAsync()
        {
            string keywordsBefore = SerializeKeywords(_config.Keywords);
            var settings = new SettingsWindow(_config);
            settings.PreviewChanged += ApplySettingsPreview;
            await settings.ShowDialog(this);
            if (!settings.Accepted)
            {
                // Revert any live preview to the saved config.
                ApplyFontSettings();
                ApplyUiScale();
                RestyleRealisedRows();
                UpdateDetailPane(_logGrid.SelectedItem as LogEntry);
                return;
            }

            _config.Save();
            ApplyFontSettings();
            ApplyUiScale();
            RestyleRealisedRows();

            bool keywordsChanged = SerializeKeywords(_config.Keywords) != keywordsBefore;
            if (keywordsChanged)
            {
                RebuildFilterBar();
                if (_currentFile != null)
                {
                    // Re-parse from scratch so existing rows and the tailer
                    // both use the new keyword set, like the original's
                    // re-evaluation plus tail restart.
                    string file = _currentFile;
                    OpenLogFile(file);
                }
                else
                {
                    LogParser.ReEvaluateAll(_master.ToList(), _config.BuildOrderedKeywords());
                    ApplyFilter();
                    RefreshRowStyling();
                }
            }
            else if (_drainTimer != null && !_initialFlushing)
            {
                _drainTimer.Interval = TimeSpan.FromMilliseconds(SpeedToIntervalMs(_config.UpdateSpeed));
            }
            UpdateDetailPane(_logGrid.SelectedItem as LogEntry);
            _statsDirty = true;
        }

        private static string SerializeKeywords(Dictionary<string, string> keywords) =>
            string.Join("|", keywords.OrderBy(kv => kv.Key, StringComparer.OrdinalIgnoreCase)
                                      .Select(kv => kv.Key + "=" + kv.Value));

        private void ApplyFontSettings()
        {
            _effectiveTextColorHex = _config.TextColorHex();
            var family = new FontFamily(_config.FontFamily);
            TextElement.SetFontFamily(_logGrid, family);
            TextElement.SetFontSize(_logGrid, _config.FontSize);
            _detailText.FontFamily = family;
            _detailText.FontSize = _config.FontSize;
            _detailText.Foreground = GetBrush(_effectiveTextColorHex);
        }

        // Live preview from the Settings dialog: the visual
        // settings are applied to this window as the user adjusts
        // them, without touching the saved config. Accepting the
        // dialog saves and reapplies from the config; cancelling
        // reapplies from the config, which reverts the preview.
        private void ApplySettingsPreview(SettingsPreview preview)
        {
            _rootScale.LayoutTransform = new ScaleTransform(preview.UiScale, preview.UiScale);
            _effectiveTextColorHex = preview.TextColorHex;
            var family = new FontFamily(preview.FontFamily);
            TextElement.SetFontFamily(_logGrid, family);
            TextElement.SetFontSize(_logGrid, preview.FontSize);
            _detailText.FontFamily = family;
            _detailText.FontSize = preview.FontSize;
            _detailText.Foreground = GetBrush(preview.TextColorHex);
            RestyleRealisedRows();
        }

        // The Settings UI scale, applied as a layout transform on
        // the window's root so every control, font and spacing
        // scales together (a layout transform, not a render zoom,
        // so nothing clips at the window edges).
        private void ApplyUiScale()
        {
            _rootScale.LayoutTransform = new ScaleTransform(_config.UiScale, _config.UiScale);
        }

        // ------------------------------------------------------------------
        // Status, layout persistence, shutdown
        // ------------------------------------------------------------------

        private void UpdateStatus()
        {
            if (_currentFile == null)
            {
                _statusText.Text = "No log file open.";
                return;
            }
            var items = CurrentItems();
            int shown = items?.Count ?? 0;
            string state = _tailer == null ? "Stopped" : (_paused ? "Paused" : (_initialFlushing ? "Loading" : "Tailing"));
            string text = $"{_currentFile} | {_master.Count:N0} lines | {shown:N0} shown | {state}";
            // Surface tailer trouble (unreachable remote host, access
            // denied, IO errors) in the status bar itself, not only in
            // the error log window: a remote open that cannot reach its
            // file must never look like a silent empty log.
            string? tailError = _tailer?.LastError;
            if (!string.IsNullOrEmpty(tailError)) text += $" | {tailError}";
            _statusText.Text = text;
        }

        private void ShowTailErrorIfNew()
        {
            string? err = _tailer?.LastError;
            if (err != null && err != _lastShownTailError)
            {
                _lastShownTailError = err;
                ErrorLog.Report("LogTailer", err);
                UpdateStatus();
            }
        }

        private void SetDetailRowHeight(double height)
        {
            // Row 4 of the left grid is the details pane (menu strip,
            // filter band, log grid, splitter, details, status bar).
            _leftGrid.RowDefinitions[4].Height = new GridLength(Math.Max(80, height));
        }

        private double GetDetailRowHeight()
        {
            return _leftGrid.RowDefinitions[4].ActualHeight;
        }

        private void OnWindowClosed(object? sender, EventArgs e)
        {
            StopTailing();
            _statsTimer?.Stop();
            _config.WindowWidth = Width;
            _config.WindowHeight = Height;
            double detail = GetDetailRowHeight();
            if (detail >= 80) _config.BottomPanelHeight = detail;
            _config.Save();
        }
    }
}
'@
 $settingsAxaml=@'
<Window xmlns="https://github.com/avaloniaui"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:local="using:__APPNAME__"
        x:Class="__APPNAME__.SettingsWindow"
        Title="PSTrace Settings"
        Width="680" Height="720" MinWidth="560" MinHeight="600"
        FontSize="12"
        FontFamily="Segoe UI, Inter, DejaVu Sans, sans-serif"
        RequestedThemeVariant="Dark"
        Background="{DynamicResource PSTraceSurfaceBg}"
        Foreground="{DynamicResource PSTraceText}"
        WindowStartupLocation="CenterOwner">
  <!-- The dialog follows the app theme (dark variant pinned here
       as on the main window, chrome painted with the shared
       PSTrace brushes) and the configured UI scale, like every
       other window. -->
  <LayoutTransformControl Name="SettingsScale">
  <!-- Every row is Auto and the keyword grid carries a fixed
       height: nothing in this dialog stretches with the window, so
       the content's desired size is constant and resizing the
       dialog can never feed back into a bigger desired size. -->
  <Grid RowDefinitions="Auto,Auto,Auto,Auto,Auto" Margin="16">
    <TextBlock Grid.Row="0" Text="Highlighting keywords" Classes="section-header" Margin="0,0,0,8"/>
    <Grid Grid.Row="1" RowDefinitions="Auto,Auto">
      <DataGrid Name="KeywordGrid" Grid.Row="0" Height="232"
                AutoGenerateColumns="False"
                CanUserResizeColumns="False"
                HeadersVisibility="Column"
                GridLinesVisibility="Horizontal"
                Background="{DynamicResource PSTracePanelBg}"
                Foreground="{DynamicResource PSTraceText}"
                HorizontalGridLinesBrush="{DynamicResource PSTraceGridLine}"
                BorderThickness="1" BorderBrush="{DynamicResource PSTraceBorder}">
        <DataGrid.Columns>
          <DataGridTextColumn Header="Keyword" Binding="{Binding Key}" Width="*"/>
          <DataGridTemplateColumn Header="Colour" Width="160">
            <DataGridTemplateColumn.CellTemplate>
              <DataTemplate DataType="local:KeywordItem">
                <ComboBox ItemsSource="{x:Static local:AppConfig.ColorNameList}"
                          SelectedItem="{Binding Value, Mode=TwoWay}"
                          Foreground="{DynamicResource PSTraceText}"
                          Background="{DynamicResource PSTracePanelBg}"
                          BorderBrush="{DynamicResource PSTraceBorder}"
                          HorizontalAlignment="Stretch" Margin="2"/>
              </DataTemplate>
            </DataGridTemplateColumn.CellTemplate>
          </DataGridTemplateColumn>
        </DataGrid.Columns>
      </DataGrid>
      <StackPanel Grid.Row="1" Orientation="Horizontal" Spacing="8" Margin="0,10,0,0">
        <Button Name="AddKeywordBtn" Content="Add keyword" Padding="12,4,12,4"/>
        <Button Name="RemoveKeywordBtn" Content="Remove selected" Padding="12,4,12,4"/>
      </StackPanel>
    </Grid>

    <Grid Grid.Row="2" ColumnDefinitions="Auto,*,Auto,116" Margin="0,16,0,0">
      <TextBlock Grid.Column="0" Text="Font:" FontWeight="SemiBold" FontSize="12" VerticalAlignment="Center" Margin="0,0,8,0"/>
      <TextBox Grid.Column="1" Name="FontFamilyBox"/>
      <TextBlock Grid.Column="2" Text="Size:" FontSize="12" VerticalAlignment="Center" Margin="12,0,8,0"/>
      <NumericUpDown Grid.Column="3" Name="FontSizeBox" Minimum="6" Maximum="72" Increment="1" FormatString="0"/>
    </Grid>

    <StackPanel Grid.Row="3" Margin="0,16,0,0" Spacing="6">
      <DockPanel Margin="0,0,0,4">
        <TextBlock Text="Text color:" FontSize="12" VerticalAlignment="Center" Margin="0,0,8,0"/>
        <ComboBox Name="TextColorBox" Width="180" HorizontalAlignment="Left" DockPanel.Dock="Left"
                  Foreground="{DynamicResource PSTraceText}"
                  Background="{DynamicResource PSTracePanelBg}"
                  BorderBrush="{DynamicResource PSTraceBorder}"/>
        <!-- Live preview of the picked colour on the log surface,
             so the choice is visible before it is applied. -->
        <Border Background="#FF18222E" BorderBrush="{DynamicResource PSTraceBorder}" BorderThickness="1"
                CornerRadius="4" Margin="12,0,0,0" Padding="10,5,10,5" VerticalAlignment="Center">
          <TextBlock Name="TextColorPreviewText" Text="19:53:37  Info  Sample log line"
                     FontFamily="Consolas" FontSize="12" VerticalAlignment="Center"/>
        </Border>
      </DockPanel>
      <TextBlock Text="Detail panel formatting" Classes="section-header"/>
      <WrapPanel>
        <CheckBox Name="FormatJsonBox" Content="Format JSON" Margin="0,0,16,0"/>
        <CheckBox Name="SplitCommaBox" Content="Split on comma" Margin="0,0,16,0"/>
        <CheckBox Name="SplitSpaceBox" Content="Split on space" Margin="0,0,16,0"/>
        <CheckBox Name="SplitPeriodBox" Content="Split on period"/>
      </WrapPanel>
      <DockPanel Margin="0,4,0,0">
        <TextBlock Text="Custom delimiters (separate with ;):" FontSize="12" VerticalAlignment="Center" Margin="0,0,8,0"/>
        <TextBox Name="CustomDelimitersBox"/>
      </DockPanel>
      <DockPanel Margin="0,8,0,0">
        <TextBlock Text="Update speed:" FontSize="12" VerticalAlignment="Center" Margin="0,0,8,0"/>
        <TextBlock Name="UpdateSpeedLabel" Text="3" VerticalAlignment="Center" Margin="8,0,0,0" Width="16"/>
        <Slider Name="UpdateSpeedSlider" Minimum="1" Maximum="5" TickFrequency="1" IsSnapToTickEnabled="True" Value="3"/>
      </DockPanel>
      <DockPanel Margin="0,8,0,0">
        <TextBlock Text="UI scale:" FontSize="12" VerticalAlignment="Center" Margin="0,0,8,0"/>
        <TextBlock Name="UiScaleLabel" Text="100%" VerticalAlignment="Center" Margin="8,0,0,0" Width="40"/>
        <Slider Name="UiScaleSlider" Minimum="75" Maximum="150" TickFrequency="5" IsSnapToTickEnabled="True" Value="100"/>
      </DockPanel>
    </StackPanel>

    <StackPanel Grid.Row="4" Orientation="Horizontal" HorizontalAlignment="Right" Spacing="8" Margin="0,16,0,0">
      <Button Name="OkBtn" Content="OK" Classes="accent" Width="90" Padding="0,6,0,6" HorizontalContentAlignment="Center" VerticalContentAlignment="Center"/>
      <Button Name="CancelBtn" Content="Cancel" Width="90" Padding="0,6,0,6" HorizontalContentAlignment="Center" VerticalContentAlignment="Center"/>
    </StackPanel>
  </Grid>
  </LayoutTransformControl>
</Window>
'@
 $settingsCs=@'
using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using Avalonia.Controls;
using Avalonia.Interactivity;
using Avalonia.Media;

namespace __APPNAME__
{
    // A snapshot of the dialog's visual settings, raised through
    // SettingsWindow.PreviewChanged as the user adjusts them, so
    // the main window shows the effect immediately (Brandon,
    // Nov 22) instead of only after OK.
    public class SettingsPreview
    {
        public string FontFamily { get; set; } = "Consolas";
        public double FontSize { get; set; } = 12;
        public string TextColorHex { get; set; } = "#FFCCD0D6";
        public double UiScale { get; set; } = 1.0;
    }

    public partial class SettingsWindow : Window
    {
        // The dialog's size at 100% scale. The window is resized in
        // proportion to the UI scale so scaled content is never
        // compressed into overlap or pushed off the bottom.
        private const double BaseWidth = 680;
        private const double BaseHeight = 720;

        public event Action<SettingsPreview>? PreviewChanged;
        private readonly AppConfig _config;
        private readonly ObservableCollection<KeywordItem> _keywords = new ObservableCollection<KeywordItem>();

        private DataGrid _keywordGrid = null!;
        private TextBox _fontFamilyBox = null!;
        private NumericUpDown _fontSizeBox = null!;
        private CheckBox _formatJsonBox = null!;
        private CheckBox _splitCommaBox = null!;
        private CheckBox _splitSpaceBox = null!;
        private CheckBox _splitPeriodBox = null!;
        private TextBox _customDelimitersBox = null!;
        private Slider _updateSpeedSlider = null!;
        private TextBlock _updateSpeedLabel = null!;
        private Slider _uiScaleSlider = null!;
        private TextBlock _uiScaleLabel = null!;
        private ComboBox _textColorBox = null!;
        private TextBlock _previewText = null!;
        private LayoutTransformControl _settingsScale = null!;

        // Bound from the keyword colour ComboBox in the DataGrid template.
        public string[] ColorNames => AppConfig.DarkColorMap.Keys.ToArray();

        public bool Accepted { get; private set; }

        // Parameterless constructor for the XAML loader; real use goes
        // through the AppConfig constructor below.
        public SettingsWindow() : this(AppConfig.Load())
        {
        }

        public SettingsWindow(AppConfig config)
        {
            _config = config;
            InitializeComponent();

            _keywordGrid = this.FindControl<DataGrid>("KeywordGrid")!;
            _fontFamilyBox = this.FindControl<TextBox>("FontFamilyBox")!;
            _fontSizeBox = this.FindControl<NumericUpDown>("FontSizeBox")!;
            _formatJsonBox = this.FindControl<CheckBox>("FormatJsonBox")!;
            _splitCommaBox = this.FindControl<CheckBox>("SplitCommaBox")!;
            _splitSpaceBox = this.FindControl<CheckBox>("SplitSpaceBox")!;
            _splitPeriodBox = this.FindControl<CheckBox>("SplitPeriodBox")!;
            _customDelimitersBox = this.FindControl<TextBox>("CustomDelimitersBox")!;
            _updateSpeedSlider = this.FindControl<Slider>("UpdateSpeedSlider")!;
            _updateSpeedLabel = this.FindControl<TextBlock>("UpdateSpeedLabel")!;
            _uiScaleSlider = this.FindControl<Slider>("UiScaleSlider")!;
            _uiScaleLabel = this.FindControl<TextBlock>("UiScaleLabel")!;
            _textColorBox = this.FindControl<ComboBox>("TextColorBox")!;
            _textColorBox.ItemsSource = AppConfig.TextColorPresets.Keys.ToArray();
            _textColorBox.SelectedItem = config.TextColorName;
            _previewText = this.FindControl<TextBlock>("TextColorPreviewText")!;
            _settingsScale = this.FindControl<LayoutTransformControl>("SettingsScale")!;

            // The dialog itself renders at the configured UI scale,
            // and the window is sized in proportion to it.
            ApplyDialogScale(config.UiScale);
            UpdateTextColorPreview();

            foreach (var kv in config.Keywords)
            {
                _keywords.Add(new KeywordItem { Key = kv.Key, Value = AppConfig.NormalizeColorName(kv.Value) });
            }
            _keywordGrid.ItemsSource = _keywords;

            _fontFamilyBox.Text = config.FontFamily;
            _fontSizeBox.Value = (decimal)config.FontSize;
            _formatJsonBox.IsChecked = config.FormatJson;
            _splitCommaBox.IsChecked = config.SplitComma;
            _splitSpaceBox.IsChecked = config.SplitSpace;
            _splitPeriodBox.IsChecked = config.SplitPeriod;
            _customDelimitersBox.Text = string.Join(";", config.CustomDelimiters);
            _updateSpeedSlider.Value = config.UpdateSpeed;
            _updateSpeedLabel.Text = config.UpdateSpeed.ToString();
            _uiScaleSlider.Value = Math.Round(config.UiScale * 100);
            _uiScaleLabel.Text = $"{(int)Math.Round(_uiScaleSlider.Value)}%";

            _updateSpeedSlider.PropertyChanged += (_, e) =>
            {
                if (e.Property == Slider.ValueProperty)
                {
                    _updateSpeedLabel.Text = ((int)Math.Round(_updateSpeedSlider.Value)).ToString();
                }
            };
            _uiScaleSlider.PropertyChanged += (_, e) =>
            {
                if (e.Property == Slider.ValueProperty)
                {
                    _uiScaleLabel.Text = $"{(int)Math.Round(_uiScaleSlider.Value)}%";
                    ApplyDialogScale(Math.Clamp(_uiScaleSlider.Value / 100.0, 0.75, 1.5));
                    RaisePreview();
                }
            };
            _textColorBox.SelectionChanged += (_, _) =>
            {
                UpdateTextColorPreview();
                RaisePreview();
            };
            _fontSizeBox.PropertyChanged += (_, e) =>
            {
                if (e.Property == NumericUpDown.ValueProperty) RaisePreview();
            };
            _fontFamilyBox.PropertyChanged += (_, e) =>
            {
                if (e.Property == TextBox.TextProperty) RaisePreview();
            };

            this.FindControl<Button>("AddKeywordBtn")!.Click += OnAddKeyword;
            this.FindControl<Button>("RemoveKeywordBtn")!.Click += OnRemoveKeyword;
            this.FindControl<Button>("OkBtn")!.Click += OnOk;
            this.FindControl<Button>("CancelBtn")!.Click += (_, _) => Close();
        }

        private void ApplyDialogScale(double scale)
        {
            _settingsScale.LayoutTransform = new ScaleTransform(scale, scale);
            Width = BaseWidth * scale;
            Height = BaseHeight * scale;
        }

        private void UpdateTextColorPreview()
        {
            _previewText.Foreground = new SolidColorBrush(Color.Parse(CurrentTextColorHex()));
        }

        private string CurrentTextColorHex()
        {
            return _textColorBox.SelectedItem is string name &&
                   AppConfig.TextColorPresets.TryGetValue(name, out var hex)
                ? hex
                : _config.TextColorHex();
        }

        private void RaisePreview()
        {
            if (PreviewChanged == null) return;
            PreviewChanged.Invoke(new SettingsPreview
            {
                FontFamily = string.IsNullOrWhiteSpace(_fontFamilyBox.Text) ? _config.FontFamily : _fontFamilyBox.Text.Trim(),
                FontSize = _fontSizeBox.Value.HasValue ? (double)_fontSizeBox.Value.Value : _config.FontSize,
                TextColorHex = CurrentTextColorHex(),
                UiScale = Math.Clamp(_uiScaleSlider.Value / 100.0, 0.75, 1.5),
            });
        }

        private void OnAddKeyword(object? sender, RoutedEventArgs e)
        {
            _keywords.Add(new KeywordItem { Key = "NewKeyword", Value = "Yellow" });
        }

        private void OnRemoveKeyword(object? sender, RoutedEventArgs e)
        {
            if (_keywordGrid.SelectedItem is KeywordItem item)
            {
                _keywords.Remove(item);
            }
        }

        private void OnOk(object? sender, RoutedEventArgs e)
        {
            var rebuilt = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (var item in _keywords)
            {
                string key = (item.Key ?? "").Trim();
                if (key.Length == 0) continue;
                string color = AppConfig.DarkColorMap.ContainsKey(item.Value ?? "") ? item.Value! : "White";
                rebuilt[key] = color;
            }
            _config.Keywords = rebuilt;

            if (!string.IsNullOrWhiteSpace(_fontFamilyBox.Text)) _config.FontFamily = _fontFamilyBox.Text.Trim();
            if (_fontSizeBox.Value.HasValue) _config.FontSize = (double)_fontSizeBox.Value.Value;
            _config.FormatJson = _formatJsonBox.IsChecked == true;
            _config.SplitComma = _splitCommaBox.IsChecked == true;
            _config.SplitSpace = _splitSpaceBox.IsChecked == true;
            _config.SplitPeriod = _splitPeriodBox.IsChecked == true;
            _config.CustomDelimiters = new List<string>(
                (_customDelimitersBox.Text ?? "").Split(new[] { ';' }, StringSplitOptions.RemoveEmptyEntries));
            _config.UpdateSpeed = Math.Clamp((int)Math.Round(_updateSpeedSlider.Value), 1, 5);
            _config.UiScale = Math.Clamp(_uiScaleSlider.Value / 100.0, 0.75, 1.5);
            if (_textColorBox.SelectedItem is string colorName &&
                AppConfig.TextColorPresets.ContainsKey(colorName))
            {
                _config.TextColorName = colorName;
            }

            Accepted = true;
            Close();
        }
    }
}
'@
 $errorAxaml=@'
<Window xmlns="https://github.com/avaloniaui"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        x:Class="__APPNAME__.ErrorLogWindow"
        Title="PSTrace Error Log"
        Width="720" Height="420" MinWidth="420" MinHeight="240"
        FontFamily="Segoe UI, Inter, DejaVu Sans, sans-serif"
        RequestedThemeVariant="Dark"
        Background="{DynamicResource PSTraceSurfaceBg}"
        Foreground="{DynamicResource PSTraceText}"
        WindowStartupLocation="CenterOwner">
  <Grid RowDefinitions="*,Auto" Margin="16">
    <ListBox Name="ErrorList" Grid.Row="0" FontFamily="Consolas" FontSize="12"
             Background="{DynamicResource PSTracePanelBg}"
             Foreground="{DynamicResource PSTraceText}"
             BorderThickness="1" BorderBrush="{DynamicResource PSTraceBorder}"/>
    <StackPanel Grid.Row="1" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
      <Button Name="CloseBtn" Content="Close" Width="90" Padding="0,6,0,6" HorizontalContentAlignment="Center" VerticalContentAlignment="Center"/>
    </StackPanel>
  </Grid>
</Window>
'@
 $errorCs=@'
using Avalonia.Controls;
using Avalonia.Threading;

namespace __APPNAME__
{
    public partial class ErrorLogWindow : Window
    {
        private readonly ListBox _errorList;

        public ErrorLogWindow()
        {
            InitializeComponent();
            _errorList = this.FindControl<ListBox>("ErrorList")!;
            _errorList.ItemsSource = ErrorLog.Snapshot();
            this.FindControl<Button>("CloseBtn")!.Click += (_, _) => Close();
            ErrorLog.Changed += OnErrorLogChanged;
            Closed += (_, _) => ErrorLog.Changed -= OnErrorLogChanged;
        }

        private void OnErrorLogChanged()
        {
            Dispatcher.UIThread.Post(() => _errorList.ItemsSource = ErrorLog.Snapshot());
        }
    }
}
'@
 $remotePathCs=@'
using System;

namespace __APPNAME__
{
    // Builds the UNC path for a log file on a remote Windows computer
    // from the two fields of the Open Remote dialog. This is plain SMB
    // file access: no agent on the remote machine, no new protocol. The
    // resulting path goes through the same OpenLogFile and
    // FileShare.ReadWrite tailer path as a local file, so tailing,
    // filters, and statistics behave identically; only the reachability
    // failures differ, and the tailer reports those.
    public static class RemoteLogPath
    {
        // computer: a NetBIOS name or DNS name, e.g. DC1. Surrounding
        // backslashes are tolerated and stripped.
        // path: the path on that computer, starting with a share name,
        // e.g. C$\Windows\Logs\file.log (admin share) or
        // Logs\share\file.log. A full UNC path (\\computer\share\...)
        // is passed through unchanged, so pasting one works.
        // Returns null when there is not enough to build a path from.
        public static string? Build(string? computer, string? path)
        {
            string p = (path ?? "").Trim();
            string c = (computer ?? "").Trim().Trim('\\');
            if (p.Length == 0) return null;
            if (IsUnc(p)) return p;
            if (c.Length == 0) return null;
            return "\\\\" + c + "\\" + p.TrimStart('\\');
        }

        public static bool IsUnc(string? path) =>
            !string.IsNullOrEmpty(path) &&
            path.StartsWith("\\\\", StringComparison.Ordinal);
    }
}
'@
 $remoteAxaml=@'
<Window xmlns="https://github.com/avaloniaui"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        x:Class="__APPNAME__.RemoteOpenWindow"
        Title="Open Remote Log"
        Width="520" Height="270" MinWidth="420" MinHeight="240"
        FontFamily="Segoe UI, Inter, DejaVu Sans, sans-serif"
        RequestedThemeVariant="Dark"
        Background="{DynamicResource PSTraceSurfaceBg}"
        Foreground="{DynamicResource PSTraceText}"
        WindowStartupLocation="CenterOwner"
        CanResize="False">
  <Grid RowDefinitions="Auto,Auto,Auto,Auto,*,Auto" Margin="16">
    <Grid Grid.Row="0" ColumnDefinitions="120,*" Margin="0,0,0,10">
      <TextBlock Grid.Column="0" Text="Computer name:" FontWeight="SemiBold" FontSize="12" VerticalAlignment="Center"/>
      <TextBox Grid.Column="1" Name="ComputerBox" Watermark="e.g. DC1"/>
    </Grid>
    <Grid Grid.Row="1" ColumnDefinitions="120,*" Margin="0,0,0,10">
      <TextBlock Grid.Column="0" Text="Path:" FontWeight="SemiBold" FontSize="12" VerticalAlignment="Center"/>
      <TextBox Grid.Column="1" Name="PathBox" Watermark="e.g. C$\Logs\file.log or share\folder\file.log"/>
    </Grid>
    <TextBlock Grid.Row="2" TextWrapping="Wrap" FontSize="12" Foreground="{DynamicResource PSTraceMutedText}"
               Text="Opens the file over SMB as \\computer\path. Admin shares such as C$ work when your account has rights on that computer. A full UNC path pasted into the Path field is used as-is."/>
    <TextBlock Grid.Row="3" Name="PreviewText" Margin="0,10,0,0" FontFamily="Consolas" Foreground="{DynamicResource PSTraceAccentText}"/>
    <TextBlock Grid.Row="4" Name="HintText" Margin="0,6,0,0" Foreground="{DynamicResource PSTraceErrorText}" TextWrapping="Wrap"/>
    <StackPanel Grid.Row="5" Orientation="Horizontal" HorizontalAlignment="Right" Spacing="8" Margin="0,12,0,0">
      <Button Name="OpenBtn" Content="Open" Classes="accent" Width="90" Padding="0,6,0,6" HorizontalContentAlignment="Center" VerticalContentAlignment="Center"/>
      <Button Name="CancelBtn" Content="Cancel" Width="90" Padding="0,6,0,6" HorizontalContentAlignment="Center" VerticalContentAlignment="Center"/>
    </StackPanel>
  </Grid>
</Window>
'@
 $remoteCs=@'
using Avalonia.Controls;
using Avalonia.Input;

namespace __APPNAME__
{
    // File, Open Remote dialog. Returns the composed UNC path as the
    // dialog result (ShowDialog<string?>), or null when cancelled. All
    // path composition lives in RemoteLogPath so it can be unit tested
    // without a window.
    public partial class RemoteOpenWindow : Window
    {
        private TextBox _computerBox = null!;
        private TextBox _pathBox = null!;
        private TextBlock _previewText = null!;
        private TextBlock _hintText = null!;

        public RemoteOpenWindow()
        {
            InitializeComponent();

            _computerBox = this.FindControl<TextBox>("ComputerBox")!;
            _pathBox = this.FindControl<TextBox>("PathBox")!;
            _previewText = this.FindControl<TextBlock>("PreviewText")!;
            _hintText = this.FindControl<TextBlock>("HintText")!;

            _computerBox.TextChanged += (_, _) => UpdatePreview();
            _pathBox.TextChanged += (_, _) => UpdatePreview();

            this.FindControl<Button>("OpenBtn")!.Click += (_, _) => TryOpen();
            this.FindControl<Button>("CancelBtn")!.Click += (_, _) => Close(null);

            KeyDown += (_, e) =>
            {
                if (e.Key == Key.Enter) { TryOpen(); e.Handled = true; }
                else if (e.Key == Key.Escape) { Close(null); e.Handled = true; }
            };

            Opened += (_, _) => _computerBox.Focus();
        }

        private void UpdatePreview()
        {
            string? unc = RemoteLogPath.Build(_computerBox.Text, _pathBox.Text);
            _previewText.Text = unc == null ? "" : $"Will open: {unc}";
        }

        private void TryOpen()
        {
            string? unc = RemoteLogPath.Build(_computerBox.Text, _pathBox.Text);
            if (unc == null)
            {
                _hintText.Text = "Enter a computer name and a path, or paste a full UNC path into the Path field.";
                return;
            }
            Close(unc);
        }
    }
}
'@
Set-Content -LiteralPath (Join-Path $Dir ($Name+'.csproj')) -Value $projCs.Replace('__APPNAME__',$Name) -Encoding UTF8
Set-Content -LiteralPath (Join-Path $Dir 'Program.cs') -Value $progCs.Replace('__APPNAME__',$Name) -Encoding UTF8
Set-Content -LiteralPath (Join-Path $Dir 'App.axaml') -Value $appAxaml.Replace('__APPNAME__',$Name) -Encoding UTF8
Set-Content -LiteralPath (Join-Path $Dir 'App.axaml.cs') -Value $appCs.Replace('__APPNAME__',$Name) -Encoding UTF8
Set-Content -LiteralPath (Join-Path $Dir 'LogParser.cs') -Value $parserCs.Replace('__APPNAME__',$Name) -Encoding UTF8
Set-Content -LiteralPath (Join-Path $Dir 'LogTailer.cs') -Value $tailerCs.Replace('__APPNAME__',$Name) -Encoding UTF8
Set-Content -LiteralPath (Join-Path $Dir 'AppConfig.cs') -Value $configCs.Replace('__APPNAME__',$Name) -Encoding UTF8
Set-Content -LiteralPath (Join-Path $Dir 'MainWindow.axaml') -Value $mwAxaml.Replace('__APPNAME__',$Name) -Encoding UTF8
Set-Content -LiteralPath (Join-Path $Dir 'MainWindow.axaml.cs') -Value $mwCs.Replace('__APPNAME__',$Name) -Encoding UTF8
Set-Content -LiteralPath (Join-Path $Dir 'SettingsWindow.axaml') -Value $settingsAxaml.Replace('__APPNAME__',$Name) -Encoding UTF8
Set-Content -LiteralPath (Join-Path $Dir 'SettingsWindow.axaml.cs') -Value $settingsCs.Replace('__APPNAME__',$Name) -Encoding UTF8
Set-Content -LiteralPath (Join-Path $Dir 'ErrorLogWindow.axaml') -Value $errorAxaml.Replace('__APPNAME__',$Name) -Encoding UTF8
Set-Content -LiteralPath (Join-Path $Dir 'ErrorLogWindow.axaml.cs') -Value $errorCs.Replace('__APPNAME__',$Name) -Encoding UTF8
Set-Content -LiteralPath (Join-Path $Dir 'RemoteLogPath.cs') -Value $remotePathCs.Replace('__APPNAME__',$Name) -Encoding UTF8
Set-Content -LiteralPath (Join-Path $Dir 'RemoteOpenWindow.axaml') -Value $remoteAxaml.Replace('__APPNAME__',$Name) -Encoding UTF8
Set-Content -LiteralPath (Join-Path $Dir 'RemoteOpenWindow.axaml.cs') -Value $remoteCs.Replace('__APPNAME__',$Name) -Encoding UTF8
}
function New-Project([string]$ExePath,[string]$Name,[string]$Dir){
Invoke-DotNet -ExePath $ExePath -FailCode 4 -CliArgs @('new','console','-n',$Name,'-o',$Dir)
if(-not (Test-Path -LiteralPath (Join-Path $Dir ($Name+'.csproj')))){Throw-Code 4 'The template reported success but the project workspace could not be created.'}}
function Publish-Project([string]$ExePath,[string]$Dir,[string]$Out){
Write-Info 'Running Windows-targeted package restore...'
Invoke-DotNet -ExePath $ExePath -FailCode 4 -CliArgs @('restore',$Dir,'-r','win-x64','--interactive','false')
Write-Info 'Compiling and publishing self-contained binary...'
Invoke-DotNet -ExePath $ExePath -FailCode 5 -CliArgs @('publish',$Dir,'-c','Release','-r','win-x64','--self-contained','true','-o',$Out,'/p:UseSharedCompilation=false','/p:NodeReuse=false')}
function Start-PublishedApp([string]$Exe,[string]$WorkDir,[string[]]$AppArgs=@()){
try{
if($AppArgs -and $AppArgs.Count -gt 0){
 $quoted=@($AppArgs | ForEach-Object {'"'+($_ -replace '"','\"')+'"'})
Start-Process -FilePath $Exe -WorkingDirectory $WorkDir -ArgumentList ($quoted -join ' ')
}else{
Start-Process -FilePath $Exe -WorkingDirectory $WorkDir
}
return $true}catch{Write-Warn2 "Auto-launch failed: $($_.Exception.Message)";Write-Warn2 'The executable is valid and complete - start manually by double-clicking:';Write-Warn2 "    $Exe";return $false}}
 $sw=[Diagnostics.Stopwatch]::StartNew()
try{
 $ProjectName=Get-SafeName $ProjectName
if([string]::IsNullOrWhiteSpace($BaseDir)){if($PSScriptRoot){$BaseDir=$PSScriptRoot}else{$BaseDir=(Get-Location).Path}}
if($BaseDir.EndsWith('\') -and $BaseDir.Length -gt 3){$BaseDir=$BaseDir.TrimEnd('\')}
if([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)){Throw-Code 1 'The LOCALAPPDATA environment variable is not set.'}
 $ProjectDir=Join-Path $BaseDir $ProjectName
 $PublishDir=Join-Path $ProjectDir 'publish'
 $AppArgs=@()
if(-not [string]::IsNullOrWhiteSpace($FilePath)){$AppArgs+=$FilePath}
if($FileArgs){foreach($a in $FileArgs){if(-not [string]::IsNullOrWhiteSpace($a)){$AppArgs+=$a}}}
Write-Host ''
Write-Host '================================================================' -ForegroundColor Cyan
Write-Host "  Bootstrap: building '$ProjectName' (Avalonia CMTrace log viewer)" -ForegroundColor Cyan
Write-Host '================================================================' -ForegroundColor Cyan
Initialize-Tls
 $Script:StageName='Environment checks'
Write-Stage '1/8' 'Initializing TLS and checking free disk space'
Write-Info "Running on Windows PowerShell $($PSVersionTable.PSVersion); TLS 1.2+ enforced; target framework net8.0."
Test-DiskSpace -Path $BaseDir
 $Script:StageName='Clean slate'
Write-Stage '2/8' "Preparing clean workspace: $ProjectDir"
if(Test-Path -LiteralPath $ProjectDir){Write-Info 'Existing project folder found; destroying it...';if(-not (Remove-Folder -Path $ProjectDir)){Write-Err2 "Could not delete '$ProjectDir' after repeated attempts.";exit 7}Write-Ok 'Old project folder removed and verified gone.'}
try{[void][IO.Directory]::CreateDirectory($BaseDir)}catch{Throw-Code 7 "Could not create base directory '$BaseDir': $($_.Exception.Message)"}
try{[void][IO.Directory]::CreateDirectory($ProjectDir)}catch{Throw-Code 7 "Could not create project directory '$ProjectDir': $($_.Exception.Message)"}
if(-not (Test-Path -LiteralPath $ProjectDir)){Throw-Code 7 "Project directory '$ProjectDir' could not be created."}
Write-Ok 'Fresh project directory is ready.'
 $Script:StageName='.NET SDK detection/install'
Write-Stage '3/8' 'Detecting or installing .NET 8 SDK (user-local, zero elevation)'
 $DotNetExe=Find-DotNetSdk
if($DotNetExe){$sdkSource='pre-existing .NET 8 SDK';Write-Ok "Using verified 8.x SDK: $DotNetExe"}
else{
Write-Info "No functional .NET 8 SDK detected; installing a user-local copy under: $($Script:DotnetDir)"
Install-DotNetSdk
Set-DotNetEnv -Dir $Script:DotnetDir
 $DotNetExe=Join-Path $Script:DotnetDir 'dotnet.exe'
if(-not (Test-SdkWorks -DotNetPath $DotNetExe)){
Write-Warn2 'SDK verification failed. Wiping directory and reinstalling once...'
if(-not (Remove-Folder -Path $Script:DotnetDir)){Throw-Code 3 "Could not delete SDK directory '$($Script:DotnetDir)'."}
Install-DotNetSdk
Set-DotNetEnv -Dir $Script:DotnetDir
if(-not (Test-SdkWorks -DotNetPath $DotNetExe)){Throw-Code 3 'The .NET 8 SDK was installed but still fails basic verification.'}
}
 $sdkSource='freshly installed user-local SDK'
}
Set-DotNetEnv -Dir (Split-Path $DotNetExe)
 $v=(& $DotNetExe --version);if($LASTEXITCODE -ne 0){Throw-Code 3 "dotnet --version failed with exit code $LASTEXITCODE."}
Write-Ok "Verified .NET SDK version: $v ($sdkSource)"
 $Script:StageName='Project creation'
Write-Stage '4/8' 'Initializing project workspace structure'
New-Project -ExePath $DotNetExe -Name $ProjectName -Dir $ProjectDir
Write-Ok 'Workspace initialized.'
 $Script:StageName='Writing sources'
Write-Stage '5/8' 'Writing PSTrace Avalonia source files'
Write-SourceFiles -Dir $ProjectDir -Name $ProjectName
Write-Ok 'All PSTrace source files written.'
 $Script:StageName='Restore/build/publish'
Write-Stage '6/8' 'Restoring Win32 Avalonia packages and publishing self-contained executable'
Publish-Project -ExePath $DotNetExe -Dir $ProjectDir -Out $PublishDir
Write-Ok 'Publish completed.'
 $Script:StageName='Artifact verification'
Write-Stage '7/8' 'Verifying published artifact executable'
 $exe=Join-Path $PublishDir ($ProjectName+'.exe')
if(-not (Test-Path -LiteralPath $exe)){Start-Sleep -Seconds 3}
if(-not (Test-Path -LiteralPath $exe)){Throw-Code 5 "Publish reported success but '$exe' was not found. Your antivirus may have quarantined it - add an exception and re-run."}
 $size=(Get-Item -LiteralPath $exe).Length
if($size -lt 1MB){Throw-Code 5 "Published exe is only $size bytes (too small for a self-contained executable)."}
 $sizeMb=[math]::Round($size/1MB,1)
Write-Ok "Executable verified: $exe ($sizeMb MB)"
 $Script:StageName='Launch'
if($NoLaunch){Write-Stage '8/8' 'Auto-launch skipped (-NoLaunch provided)';Write-Info "Run the app by double-clicking: $exe"}
else{Write-Stage '8/8' 'Launching the freshly built Avalonia application';if($AppArgs.Count -gt 0){Write-Info "Opening log file argument(s): $($AppArgs -join ', ')"};if(-not (Start-PublishedApp -Exe $exe -WorkDir $PublishDir -AppArgs $AppArgs)){exit 6}}
Write-Host ''
Write-Host '================================================================' -ForegroundColor Green
Write-Host '  SUCCESS - application built, verified, and ready' -ForegroundColor Green
Write-Host '================================================================' -ForegroundColor Green
Write-Ok "Project workspace : $ProjectDir"
Write-Ok "Publish directory : $PublishDir"
Write-Ok "Self-contained EXE: $exe ($sizeMb MB)"
Write-Ok "SDK source        : $sdkSource"
Write-Ok ("Build time        : {0:hh\:mm\:ss}" -f $sw.Elapsed)
exit 0
}
catch{
 $code=1;if($_.Exception.Message -match '^\[(\d)\]'){$code=[int]$Matches[1]}
Write-Host ''
Write-Err2 "FAILED during stage: $($Script:StageName)"
Write-Err2 "Error: $($_.Exception.Message)"
Write-Err2 'Next step: address the error above and re-run.'
exit $code
}
finally{
if($Script:InstallerPath -and (Test-Path -LiteralPath $Script:InstallerPath)){Remove-Item -LiteralPath $Script:InstallerPath -Force -ErrorAction SilentlyContinue}
}
