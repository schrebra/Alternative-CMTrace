# Ensure we are running in an environment that supports WPF
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Warning "This script requires PowerShell 5.1 or later."
    return
}

# Load WPF and Drawing Assemblies
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, Microsoft.VisualBasic, System.Drawing

# Define a C# class to support DataGrid inline adding (CanUserAddRows)
if (-not ("KeywordItem" -as [type])) {
    Add-Type @"
    public class KeywordItem {
        public string Key { get; set; }
        public string Value { get; set; }
    }
"@
}

# --- Helper: Slow Down Mouse Wheel Scrolling ---
function Find-ScrollViewer {
    param($depObj)
    if ($depObj -is [System.Windows.Controls.ScrollViewer]) { return $depObj }
    if ($null -eq $depObj) { return $null }
    for ($i = 0; $i -lt [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($depObj); $i++) {
        $child = [System.Windows.Media.VisualTreeHelper]::GetChild($depObj, $i)
        $result = Find-ScrollViewer $child
        if ($null -ne $result) { return $result }
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

# --- Configuration & INI Management ---
 $script:ConfigPath = "$env:APPDATA\PS_CMTraceViewer.ini"

# Friendly color names mapped to pastel hex codes for UI backgrounds
 $script:ColorMap = @{
    "Red"    = "#FFFFCDD2"
    "Orange" = "#FFFFE0B2"
    "Yellow" = "#FFFFF9C4"
    "Green"  = "#FFC8E6C9"
    "Blue"   = "#FFE1F5FE"
    "Purple" = "#FFE1BEE7"
    "White"  = "#FFFFFFFF"
}

# Reverse map to clean up old INI files
 $script:ReverseColorMap = @{}
foreach($k in $script:ColorMap.Keys) { $script:ReverseColorMap[$script:ColorMap[$k]] = $k }

# Expanded default keywords
 $script:Config = @{
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
    WindowWidth        = 1000
    WindowHeight       = 700
    Keywords           = @{
        "Fatal"         = "Red"
        "Critical"      = "Red"
        "Error"         = "Orange"
        "Failure"       = "Orange"
        "Exception"     = "Orange"
        "Warning"       = "Yellow"
        "Warn"          = "Yellow"
        "Verbose"       = "Blue"
        "Debug"         = "Blue"
        "Trace"         = "Blue"
        "Info"          = "White"
        "Information"   = "White"
        "Success"       = "Green"
        "Audit"         = "Green"
        "Stopped"       = "Purple"
    }
}

function Load-Config {
    if (Test-Path $script:ConfigPath) {
        $section = ""
        $kw = @{}
        $delims = @()
        $settings = @{
            FontFamily        = $script:Config.FontFamily
            FontSize          = $script:Config.FontSize
            BottomPanelHeight = $script:Config.BottomPanelHeight
            FormatJson        = $script:Config.FormatJson
            SplitComma        = $script:Config.SplitComma
            SplitSpace        = $script:Config.SplitSpace
            SplitPeriod       = $script:Config.SplitPeriod
            UpdateSpeed       = $script:Config.UpdateSpeed
            LastLogFile       = ""
            WindowWidth       = 1000
            WindowHeight      = 700
        }
        
        foreach($line in Get-Content $script:ConfigPath) {
            if ($line -match '^\[(.+)\]$') { 
                $section = $matches[1] 
            }
            elseif ($line -match '^(.+)=(.*)$') {
                $key = $matches[1]; $val = $matches[2]
                if ($section -eq "Settings") { $settings[$key] = $val }
                elseif ($section -eq "Keywords") {
                    if ($script:ReverseColorMap.ContainsKey($val)) { $val = $script:ReverseColorMap[$val] }
                    $kw[$key] = $val
                }
                elseif ($section -eq "Delimiters") {
                    $delims += $val
                }
            }
        }
        $script:Config.FontFamily = $settings["FontFamily"]
        $script:Config.FontSize = [int]$settings["FontSize"]
        $script:Config.BottomPanelHeight = [int]$settings["BottomPanelHeight"]
        $script:Config.FormatJson = [bool]::Parse($settings["FormatJson"])
        $script:Config.SplitComma = [bool]::Parse($settings["SplitComma"])
        $script:Config.SplitSpace = [bool]::Parse($settings["SplitSpace"])
        $script:Config.SplitPeriod = [bool]::Parse($settings["SplitPeriod"])
        $script:Config.UpdateSpeed = [int]$settings["UpdateSpeed"]
        $script:Config.LastLogFile = $settings["LastLogFile"]
        $script:Config.WindowWidth = [int]$settings["WindowWidth"]
        $script:Config.WindowHeight = [int]$settings["WindowHeight"]
        if ($kw.Count -gt 0) { $script:Config.Keywords = $kw }
        if ($delims.Count -gt 0) { $script:Config.CustomDelimiters = $delims }
    }
}

function Save-Config {
    try {
        $lines = @()
        $lines += "[Settings]"
        $lines += "FontFamily=$($script:Config.FontFamily)"
        $lines += "FontSize=$($script:Config.FontSize)"
        $lines += "BottomPanelHeight=$($script:Config.BottomPanelHeight)"
        $lines += "FormatJson=$($script:Config.FormatJson)"
        $lines += "SplitComma=$($script:Config.SplitComma)"
        $lines += "SplitSpace=$($script:Config.SplitSpace)"
        $lines += "SplitPeriod=$($script:Config.SplitPeriod)"
        $lines += "UpdateSpeed=$($script:Config.UpdateSpeed)"
        $lines += "LastLogFile=$($script:Config.LastLogFile)"
        $lines += "WindowWidth=$($script:Config.WindowWidth)"
        $lines += "WindowHeight=$($script:Config.WindowHeight)"
        $lines += ""
        $lines += "[Keywords]"
        foreach($kv in $script:Config.Keywords.GetEnumerator()) {
            $lines += "$($kv.Key)=$($kv.Value)"
        }
        $lines += ""
        $lines += "[Delimiters]"
        $i = 1
        foreach($d in $script:Config.CustomDelimiters) {
            $lines += "$i=$d"
            $i++
        }
        $lines | Out-File $script:ConfigPath -Encoding UTF8 -Force
    } catch {
        [System.Windows.MessageBox]::Show("Failed to save settings: $_", "Error", "OK", "Error")
    }
}

# Load config on startup
Load-Config

# Pre-compile Regex for extreme performance
 $script:LogRegex = [regex]::new(
    '<!\[LOG\[(?<Message>.*?)\]LOG\]!><time="(?<Time>.*?)"\s+date="(?<Date>.*?)"\s+component="(?<Component>.*?)"\s+context=".*?"\s+type="(?<Type>.*?)"\s+thread="(?<Thread>.*?)"\s+file=".*?">', 
    [System.Text.RegularExpressions.RegexOptions]::Compiled
)

# Global buffer for partial writes
 $script:PendingBuffer = ""

# --- Main XAML UI ---
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:sys="clr-namespace:System;assembly=mscorlib"
        Title="Configuration Manager Trace Log Tool" Height="$($script:Config.WindowHeight)" Width="$($script:Config.WindowWidth)" WindowStartupLocation="CenterScreen">
    <Window.Resources>
        <Style TargetType="DataGridCell">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderBrush" Value="Transparent"/>
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
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
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="5"/>
            <RowDefinition Height="$($script:Config.BottomPanelHeight)" x:Name="BottomRow"/>
        </Grid.RowDefinitions>
        
        <Menu Grid.Row="0" Background="#FFF0F0F0">
            <MenuItem Header="_File">
                <MenuItem Header="_Open..." Name="OpenMenu"/>
                <Separator/>
                <MenuItem Header="_Exit" Name="ExitMenu"/>
            </MenuItem>
            <MenuItem Header="_Edit">
                <MenuItem Header="_Find..." Name="FindMenu"/>
            </MenuItem>
            <MenuItem Header="_Tools">
                <MenuItem Header="_Settings..." Name="SettingsMenu"/>
            </MenuItem>
        </Menu>

        <StackPanel Grid.Row="1" Orientation="Horizontal" Background="#FFF0F0F0" Margin="0,2,0,2">
            <ToggleButton Name="PauseBtn" Content="Pause Auto-Refresh" Width="150" Margin="5,0,0,0"/>
            <ToggleButton Name="ScrollBtn" Content="Auto-Scroll: ON" Width="150" Margin="5,0,0,0" IsChecked="True"/>
            
            <TextBlock Text="Find:" VerticalAlignment="Center" Margin="15,0,0,0" FontWeight="Bold"/>
            <TextBox Name="SearchBox" Width="250" Margin="5,0,0,0"/>
            <Button Name="SearchBtn" Content="Find Next" Width="80" Margin="5,0,0,0"/>
            <Button Name="ClearSearchBtn" Content="Clear" Width="50" Margin="5,0,0,0"/>
        </StackPanel>

        <DataGrid Grid.Row="2" Name="LogDataGrid" 
                  Background="White" Foreground="Black"
                  GridLinesVisibility="Horizontal" HorizontalGridLinesBrush="#FFD0D0D0"
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
                  VirtualizingPanel.ScrollUnit="Pixel">
            
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

        <GridSplitter Grid.Row="3" Height="5" HorizontalAlignment="Stretch" Background="#FFD0D0D0" ResizeDirection="Rows" ResizeBehavior="PreviousAndNext"/>

        <TextBox Grid.Row="4" Name="DetailTextBox" 
                 IsReadOnly="True" 
                 Background="#FFF8F8F8" 
                 BorderThickness="1,0,1,1" BorderBrush="#FFD0D0D0"
                 VerticalScrollBarVisibility="Auto" 
                 HorizontalScrollBarVisibility="Auto"
                 TextWrapping="Wrap" 
                 Padding="5,5,5,5" />
    </Grid>
</Window>
"@

# Read XAML and create the window
 $reader = (New-Object System.Xml.XmlNodeReader $xaml)
 $Window = [Windows.Markup.XamlReader]::Load($reader)

# Connect UI Elements
 $OpenMenu = $Window.FindName("OpenMenu")
 $ExitMenu = $Window.FindName("ExitMenu")
 $FindMenu = $Window.FindName("FindMenu")
 $SettingsMenu = $Window.FindName("SettingsMenu")
 $LogDataGrid = $Window.FindName("LogDataGrid")
 $DetailTextBox = $Window.FindName("DetailTextBox")
 $PauseBtn = $Window.FindName("PauseBtn")
 $ScrollBtn = $Window.FindName("ScrollBtn")
 $BottomRow = $Window.FindName("BottomRow")
 $SearchBox = $Window.FindName("SearchBox")
 $SearchBtn = $Window.FindName("SearchBtn")
 $ClearSearchBtn = $Window.FindName("ClearSearchBtn")

# Apply Slow Scroll to Main UI elements
Add-SlowScroll $LogDataGrid
Add-SlowScroll $DetailTextBox

# Global variables
 $script:CurrentLogFile = $null
 $script:LastFileLength = 0
 $script:RefreshTimer = $null

# --- Dynamic Styling Logic ---
function Apply-ConfigToGui {
    try {
        $font = New-Object System.Windows.Media.FontFamily($script:Config.FontFamily)
        $LogDataGrid.FontFamily = $font
        $DetailTextBox.FontFamily = $font
        $LogDataGrid.FontSize = $script:Config.FontSize
        $DetailTextBox.FontSize = $script:Config.FontSize

        if ($BottomRow -ne $null) {
            $BottomRow.Height = New-Object System.Windows.GridLength([double]$script:Config.BottomPanelHeight)
        }

        $styleXml = "<Style TargetType='DataGridRow' xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'>"
        $styleXml += "<Setter Property='Background' Value='White'/>"
        $styleXml += "<Setter Property='Foreground' Value='Black'/>"
        $styleXml += "<Style.Triggers>"
        
        foreach ($kw in $script:Config.Keywords.Keys) {
            $colorName = $script:Config.Keywords[$kw]
            $hex = $script:ColorMap[$colorName]
            if (-not $hex) { $hex = "#FFFFFFFF" }
            $styleXml += "<DataTrigger Binding='{Binding Level}' Value='$kw'><Setter Property='Background' Value='$hex'/></DataTrigger>"
        }
        
        $styleXml += "<Trigger Property='IsSelected' Value='True'><Setter Property='Background' Value='Blue'/><Setter Property='Foreground' Value='White'/></Trigger>"
        
        $styleXml += "</Style.Triggers>"
        $styleXml += "</Style>"
        
        $style = [Windows.Markup.XamlReader]::Parse($styleXml)
        $LogDataGrid.ItemContainerStyle = $style
    } catch {
        [System.Windows.MessageBox]::Show("Failed to apply UI styles: $_", "UI Error", "OK", "Warning")
    }
}

Apply-ConfigToGui

# --- Log Parsing Logic ---
function Get-LogLevel {
    param([string]$Message, [string]$TypeVal)
    $msgLower = $Message.ToLower()
    foreach ($kw in $script:Config.Keywords.Keys) {
        if ($msgLower -match [regex]::Escape($kw.ToLower())) { return $kw }
    }
    if ($TypeVal -eq "1") { return "Error" }
    if ($TypeVal -eq "2") { return "Warning" }
    if ($TypeVal -eq "4") { return "Verbose" }
    return "Info"
}

function Format-LogDetails {
    param([string]$RawMsg)
    $msg = $RawMsg

    if ($script:Config.FormatJson) {
        $trimMsg = $msg.TrimStart()
        if ($trimMsg.StartsWith("{") -or $trimMsg.StartsWith("[")) {
            try {
                $jsonObj = $msg | ConvertFrom-Json -ErrorAction Stop
                $msg = $jsonObj | ConvertTo-Json -Depth 10
            } catch { }
        }
    }

    if ($script:Config.SplitComma) { $msg = $msg -replace ',', ",`r`n" }
    if ($script:Config.SplitSpace) { $msg = $msg -replace ' ', " `r`n" }
    if ($script:Config.SplitPeriod) { $msg = $msg -replace '\.', ".`r`n" }

    if ($script:Config.CustomDelimiters.Count -gt 0) {
        foreach ($d in $script:Config.CustomDelimiters) {
            if (-not [string]::IsNullOrWhiteSpace($d)) {
                $msg = $msg -replace [regex]::Escape($d), "$d`r`n"
            }
        }
    }
    return $msg
}

function Parse-CMTraceLine {
    param([string]$Line)
    $match = $script:LogRegex.Match($Line)
    
    if ($match.Success) {
        $timeStr = $match.Groups['Time'].Value
        $dateStr = $match.Groups['Date'].Value
        $combinedStr = "$dateStr $timeStr"
        $dt = [datetime]::Now
        $parsedDate = $null
        
        if ([datetime]::TryParse($combinedStr, [ref]$parsedDate)) {
            $dt = $parsedDate
        } else {
            $cleanTime = $timeStr -replace '\+\d+$', '' -replace '-\d+$', ''
            $combinedStr = "$dateStr $cleanTime"
            if ([datetime]::TryParse($combinedStr, [ref]$parsedDate)) {
                $dt = $parsedDate
            }
        }

        $typeVal = $match.Groups['Type'].Value
        $rawMsg = $match.Groups['Message'].Value
        $level = Get-LogLevel -Message $rawMsg -TypeVal $typeVal

        return [PSCustomObject]@{
            Message   = "[$($dt.ToString('HH:mm:ss.fff'))] $rawMsg"
            RawMsg    = $rawMsg
            Level     = $level
            TypeVal   = $typeVal
        }
    } else {
        $level = Get-LogLevel -Message $Line -TypeVal "0"
        
        return [PSCustomObject]@{
            Message   = $Line
            RawMsg    = $Line
            Level     = $level
            TypeVal   = "0"
        }
    }
}

function Update-LogData {
    if (-not $script:CurrentLogFile -or -not (Test-Path $script:CurrentLogFile)) { return }
    
    $stream = $null
    $reader = $null
    
    try {
        $fileInfo = Get-Item $script:CurrentLogFile -ErrorAction Stop
        $currentLength = $fileInfo.Length
        if ($currentLength -eq $script:LastFileLength) { return }
        if ($currentLength -lt $script:LastFileLength) { 
            $script:LastFileLength = 0 
            $script:PendingBuffer = ""
        }

        $stream = [System.IO.File]::Open($script:CurrentLogFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $reader = New-Object System.IO.StreamReader($stream)
        
        if ($script:LastFileLength -gt 0) { 
            $reader.BaseStream.Seek($script:LastFileLength, [System.IO.SeekOrigin]::Begin) | Out-Null 
        }
        
        $newContent = $reader.ReadToEnd()
        $script:LastFileLength = $currentLength

        $allText = $script:PendingBuffer + $newContent
        $script:PendingBuffer = ""
        
        $lines = $allText -split "`r`n"
        
        if ($lines.Count -gt 0) {
            $lastLine = $lines[-1]
            if ($lastLine -match '^<!\[LOG\[' -and -not ($script:LogRegex.IsMatch($lastLine))) {
                $script:PendingBuffer = $lastLine
                $lines = $lines[0..($lines.Count - 2)]
            }
        }
        
        $lines = $lines | Where-Object { $_.Trim() -ne "" }
        $newEntries = @()
        $buffer = ""
        
        foreach ($line in $lines) {
            if ($line -match '^<!\[LOG\[' -and $buffer -ne "") { $newEntries += (Parse-CMTraceLine -Line $buffer); $buffer = $line }
            elseif ($line -match '^<!\[LOG\[') { $buffer = $line }
            elseif ($buffer -ne "") { $buffer += "`r`n$line" }
            else { $newEntries += (Parse-CMTraceLine -Line $line) }
        }
        if ($buffer -ne "") { $newEntries += (Parse-CMTraceLine -Line $buffer) }

        if ($newEntries.Count -gt 0) {
            $ObservableCollection = $LogDataGrid.ItemsSource
            if (-not ($ObservableCollection -is [System.Collections.ObjectModel.ObservableCollection[PSCustomObject]])) {
                $ObservableCollection = [System.Collections.ObjectModel.ObservableCollection[PSCustomObject]]::new()
            }
            
            foreach ($entry in $newEntries) { $ObservableCollection.Add($entry) }
            $LogDataGrid.ItemsSource = $ObservableCollection

            if ($ScrollBtn.IsChecked) {
                if ($LogDataGrid.Items.Count -gt 0) { 
                    $LogDataGrid.ScrollIntoView($LogDataGrid.Items[$LogDataGrid.Items.Count - 1]) 
                }
            }
        }
    } catch {
        # Silently fail to prevent timer crashes
    } finally {
        if ($reader -ne $null) { $reader.Dispose() }
        if ($stream -ne $null) { $stream.Dispose() }
    }
}

# --- Event Handlers ---

 $PauseBtn.Add_Click({
    if ($PauseBtn.IsChecked) { $PauseBtn.Content = "Resume Auto-Refresh" } else { $PauseBtn.Content = "Pause Auto-Refresh" }
})

 $ScrollBtn.Add_Click({
    if ($ScrollBtn.IsChecked) { $ScrollBtn.Content = "Auto-Scroll: ON" } else { $ScrollBtn.Content = "Auto-Scroll: OFF" }
})

 $LogDataGrid.Add_SelectionChanged({
    if ($LogDataGrid.SelectedItem -ne $null) {
        $item = $LogDataGrid.SelectedItem
        $formattedDetails = Format-LogDetails -RawMsg $item.RawMsg
        
        # Add 2 explicit blank lines above the log for visual separation
        $DetailTextBox.Text = "`r`n`r`n" + $formattedDetails
    }
})

 $OpenMenu.Add_Click({
    $openFileDialog = New-Object Microsoft.Win32.OpenFileDialog
    $openFileDialog.Filter = "Log files (*.log)|*.log|Text files (*.txt)|*.txt|All files (*.*)|*.*"
    if ($openFileDialog.ShowDialog() -eq $true) {
        $script:CurrentLogFile = $openFileDialog.FileName
        $script:LastFileLength = 0
        $script:PendingBuffer = ""
        $script:Config.LastLogFile = $openFileDialog.FileName
        $Window.Title = "Configuration Manager Trace Log Tool - $($openFileDialog.FileName)"
        $LogDataGrid.ItemsSource = $null
        $DetailTextBox.Text = ""
        Update-LogData
    }
})

 $ExitMenu.Add_Click({ $Window.Close() })

function Perform-Search {
    $searchText = $SearchBox.Text
    if ([string]::IsNullOrWhiteSpace($searchText)) { return }

    if (-not $PauseBtn.IsChecked) {
        $PauseBtn.IsChecked = $true
        $PauseBtn.Content = "Resume Auto-Refresh"
    }
    if ($ScrollBtn.IsChecked) {
        $ScrollBtn.IsChecked = $false
        $ScrollBtn.Content = "Auto-Scroll: OFF"
    }

    $items = $LogDataGrid.Items
    if (-not $items -or $items.Count -eq 0) { return }

    $startIndex = $LogDataGrid.SelectedIndex + 1
    if ($startIndex -ge $items.Count -or $startIndex -lt 0) { $startIndex = 0 }
    
    for ($i = $startIndex; $i -lt $items.Count; $i++) {
        $item = $items[$i]
        if ($item -ne $null -and $item.Message -like "*$searchText*") {
            $LogDataGrid.SelectedIndex = $i
            $LogDataGrid.ScrollIntoView($item)
            $LogDataGrid.Focus()
            return
        }
    }
    
    for ($i = 0; $i -lt $startIndex; $i++) {
        $item = $items[$i]
        if ($item -ne $null -and $item.Message -like "*$searchText*") {
            $LogDataGrid.SelectedIndex = $i
            $LogDataGrid.ScrollIntoView($item)
            $LogDataGrid.Focus()
            return
        }
    }
}

 $SearchBtn.Add_Click({ Perform-Search })
 $SearchBox.Add_KeyDown({
    if ($_.Key -eq 'Return' -or $_.Key -eq 'Enter') { 
        $_.Handled = $true
        Perform-Search 
    }
})

 $ClearSearchBtn.Add_Click({
    $SearchBox.Text = ""
    $LogDataGrid.SelectedIndex = -1
    $DetailTextBox.Text = ""
    $SearchBox.Focus()
})

 $FindMenu.Add_Click({ $SearchBox.Focus() })

 $Window.Add_Closing({
    try {
        if ($script:RefreshTimer -ne $null) {
            $script:RefreshTimer.Stop()
            $script:RefreshTimer = $null
        }
        $script:Config.BottomPanelHeight = [int]$BottomRow.Height.Value
        $script:Config.WindowWidth = $Window.Width
        $script:Config.WindowHeight = $Window.Height
        Save-Config
    } catch {} 
})

# Settings Dialog
 $SettingsMenu.Add_Click({
    [xml]$settingsXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:sys="clr-namespace:System;assembly=mscorlib"
        Title="Settings" Height="680" Width="450" FontSize="11" WindowStartupLocation="CenterOwner" Background="#FFF4F4F4" ResizeMode="CanResize">
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
                <ComboBox Name="FontCombo" Grid.Column="1" Margin="2"/>
                <TextBlock Text="Size:" Grid.Column="2" Margin="5,0,2,0" VerticalAlignment="Center"/>
                <ComboBox Name="SizeCombo" Grid.Column="3" Width="40" Margin="2"/>
                <TextBlock Text="Speed (s):" Grid.Column="4" Margin="5,0,2,0" VerticalAlignment="Center"/>
                <ComboBox Name="SpeedCombo" Grid.Column="5" Width="40" Margin="2"/>
            </Grid>
        </GroupBox>

        <GroupBox Header=" Detail Panel Formatting " Grid.Row="1" Margin="0,0,0,5" Padding="3">
            <WrapPanel Margin="2">
                <CheckBox Name="JsonCheck" Content="Format JSON" Margin="2"/>
                <CheckBox Name="CommaCheck" Content="Split Commas" Margin="2"/>
                <CheckBox Name="SpaceCheck" Content="Split Spaces" Margin="2"/>
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
                    <TextBox Name="NewDelim" Width="60" Margin="2"/>
                    <Button Name="AddDelimBtn" Content="Add" Width="50" Margin="2"/>
                    <Button Name="RemoveDelimBtn" Content="Remove Selected" Width="100" Margin="2"/>
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
                <DataGrid Name="KeywordsGrid" Grid.Row="0" AutoGenerateColumns="False" HeadersVisibility="Column" CanUserAddRows="True" CanUserDeleteRows="True" Margin="2" VirtualizingPanel.ScrollUnit="Pixel">
                    <DataGrid.Columns>
                        <DataGridTextColumn Header="Keyword" Binding="{Binding Key}" Width="*" IsReadOnly="False"/>
                        <DataGridTemplateColumn Header="Color" Width="100">
                            <DataGridTemplateColumn.CellTemplate>
                                <DataTemplate>
                                    <ComboBox SelectedItem="{Binding Value, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" ItemsSource="{StaticResource ColorList}" Margin="1"/>
                                </DataTemplate>
                            </DataGridTemplateColumn.CellTemplate>
                        </DataGridTemplateColumn>
                    </DataGrid.Columns>
                </DataGrid>
                <Button Name="RemoveBtn" Content="Remove Selected" Grid.Row="1" Width="100" HorizontalAlignment="Left" Margin="2"/>
            </Grid>
        </GroupBox>

        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Grid.Row="4" Margin="5,2,0,2">
            <Button Name="SaveBtn" Content="Save &amp; Apply" Width="90" Margin="0,0,5,0" IsDefault="True"/>
            <Button Name="CancelBtn" Content="Cancel" Width="70" IsCancel="True"/>
        </StackPanel>
    </Grid>
</Window>
"@
    $sReader = (New-Object System.Xml.XmlNodeReader $settingsXaml)
    $sWindow = [Windows.Markup.XamlReader]::Load($sReader)
    $sWindow.Owner = $Window
    
    $FontCombo = $sWindow.FindName("FontCombo")
    $SizeCombo = $sWindow.FindName("SizeCombo")
    $SpeedCombo = $sWindow.FindName("SpeedCombo")
    $JsonCheck = $sWindow.FindName("JsonCheck")
    $CommaCheck = $sWindow.FindName("CommaCheck")
    $SpaceCheck = $sWindow.FindName("SpaceCheck")
    $PeriodCheck = $sWindow.FindName("PeriodCheck")
    $NewDelim = $sWindow.FindName("NewDelim")
    $AddDelimBtn = $sWindow.FindName("AddDelimBtn")
    $RemoveDelimBtn = $sWindow.FindName("RemoveDelimBtn")
    $DelimList = $sWindow.FindName("DelimList")
    
    $KeywordsGrid = $sWindow.FindName("KeywordsGrid")
    $RemoveBtn = $sWindow.FindName("RemoveBtn")
    $SaveBtn = $sWindow.FindName("SaveBtn")
    $CancelBtn = $sWindow.FindName("CancelBtn")

    # Apply Slow Scroll to Settings UI elements
    Add-SlowScroll $KeywordsGrid
    Add-SlowScroll $DelimList
    
    foreach($f in [System.Drawing.FontFamily]::Families | Select-Object -ExpandProperty Name) { $FontCombo.Items.Add($f) | Out-Null }
    $FontCombo.SelectedItem = $script:Config.FontFamily
    
    8..24 | ForEach-Object { $SizeCombo.Items.Add($_) | Out-Null }
    $SizeCombo.SelectedItem = $script:Config.FontSize
    
    1..10 | ForEach-Object { $SpeedCombo.Items.Add($_) | Out-Null }
    $SpeedCombo.SelectedItem = $script:Config.UpdateSpeed
    
    $JsonCheck.IsChecked = $script:Config.FormatJson
    $CommaCheck.IsChecked = $script:Config.SplitComma
    $SpaceCheck.IsChecked = $script:Config.SplitSpace
    $PeriodCheck.IsChecked = $script:Config.SplitPeriod
    
    foreach($d in $script:Config.CustomDelimiters) { $DelimList.Items.Add($d) | Out-Null }
    
    $kwList = New-Object System.Collections.ObjectModel.ObservableCollection[KeywordItem]
    foreach($kv in $script:Config.Keywords.GetEnumerator()) {
        $kwList.Add((New-Object KeywordItem -Property @{ Key=$kv.Key; Value=$kv.Value }))
    }
    $KeywordsGrid.ItemsSource = $kwList
    
    $AddDelimBtn.Add_Click({
        if(-not [string]::IsNullOrEmpty($NewDelim.Text)) {
            $DelimList.Items.Add($NewDelim.Text)
            $NewDelim.Text = ""
        }
    })
    $RemoveDelimBtn.Add_Click({
        if($DelimList.SelectedItem -ne $null) { $DelimList.Items.Remove($DelimList.SelectedItem) }
    })
    
    $RemoveBtn.Add_Click({
        if($KeywordsGrid.SelectedItem -ne $null) { 
            if ($KeywordsGrid.SelectedItem -is [KeywordItem]) {
                $kwList.Remove($KeywordsGrid.SelectedItem) 
            }
        }
    })
    
    $SaveBtn.Add_Click({
        $script:Config.FontFamily = $FontCombo.SelectedItem
        $script:Config.FontSize = [int]$SizeCombo.SelectedItem
        $script:Config.UpdateSpeed = [int]$SpeedCombo.SelectedItem
        $script:Config.FormatJson = $JsonCheck.IsChecked
        $script:Config.SplitComma = $CommaCheck.IsChecked
        $script:Config.SplitSpace = $SpaceCheck.IsChecked
        $script:Config.SplitPeriod = $PeriodCheck.IsChecked
        
        $delims = @()
        foreach($d in $DelimList.Items) { $delims += $d }
        $script:Config.CustomDelimiters = $delims
        
        $newKw = @{}
        foreach($item in $kwList) {
            if ($item -ne $null -and -not [string]::IsNullOrWhiteSpace($item.Key)) {
                $newKw[$item.Key] = $item.Value
            }
        }
        $script:Config.Keywords = $newKw
        
        Save-Config
        Apply-ConfigToGui
        
        # --- DYNAMIC RE-COLORING LOGIC ---
        $items = $LogDataGrid.ItemsSource
        if ($items -is [System.Collections.ObjectModel.ObservableCollection[PSCustomObject]]) {
            # Detach to prevent UI thread thrashing
            $LogDataGrid.ItemsSource = $null
            foreach ($item in $items) {
                # Recalculate Level based on new Keywords
                $item.Level = Get-LogLevel -Message $item.RawMsg -TypeVal $item.TypeVal
            }
            # Reattach to force WPF to redraw all rows with new colors
            $LogDataGrid.ItemsSource = $items
        }

        try {
            $script:RefreshTimer.Stop()
            $script:RefreshTimer.Interval = [TimeSpan]::FromSeconds($script:Config.UpdateSpeed)
            $script:RefreshTimer.Start()
        } catch {}
        
        $sWindow.Close()
    })
    
    $CancelBtn.Add_Click({ $sWindow.Close() })
    $sWindow.ShowDialog() | Out-Null
})

# Bulletproof DispatcherTimer
 $script:RefreshTimer = New-Object System.Windows.Threading.DispatcherTimer
 $script:RefreshTimer.Interval = [TimeSpan]::FromSeconds($script:Config.UpdateSpeed)
 $script:RefreshTimer.Add_Tick({
    try {
        if (-not $PauseBtn.IsChecked -and $script:CurrentLogFile) { 
            Update-LogData 
        }
    } catch {}
})
 $script:RefreshTimer.Start()

# Auto-load last log file if it exists
if (-not [string]::IsNullOrWhiteSpace($script:Config.LastLogFile) -and (Test-Path $script:Config.LastLogFile)) {
    $script:CurrentLogFile = $script:Config.LastLogFile
    $Window.Title = "Configuration Manager Trace Log Tool - $($script:Config.LastLogFile)"
    Update-LogData
}

# Show Main Window
 $Window.ShowDialog() | Out-Null
