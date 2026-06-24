# PowerShell CMTrace Log Tool

A high-performance, WPF-based log viewer for PowerShell, specifically engineered to handle **massive log files (up to 2,000,000 lines)** with minimal memory overhead and near-instant parsing. It mimics the functionality of the classic `CMTrace` utility while providing modern customization, multithreaded file tailing, and regex/keyword-based highlighting.

<img width="60%" alt="image" src="https://github.com/user-attachments/assets/85c2ddf4-a7c5-435f-ad51-f5575b9a14ad" />


## Key Features

* **Massive Log Support:** Now capable of seamlessly loading, retaining, and viewing up to **2,000,000 log lines** in memory without crashing or freezing the UI.
* **Multithreaded Performance:** Uses a dedicated background Runspace with an increased 50,000-item drain limit per tick to tail files, preventing UI freezes during massive log reads.
* **WPF-Powered UI:** Modern `DataGrid` interface with virtualization, ensuring smooth scrolling even with millions of log entries.
* **Throttled UI Rendering:** Intelligent UI update throttling ensures the statistics panel recalculates at a maximum of 1Hz during continuous heavy tailing, keeping the interface buttery smooth.
* **Optimized Initial Load:** Real-time total line count updates without triggering heavy layout recalculations during the initial file flush, keeping the window draggable and responsive.
* **Native Parsing:** High-speed C# log parsing integrated directly into the script, optimized to eliminate memory boxing/unboxing.
* **Customizable Highlighting:** Define custom keywords and color schemes (Red, Orange, Yellow, Green, Blue, Purple, White) to instantly spot errors and warnings.
* **Detail Formatting:** Includes intelligent JSON formatting and delimiter splitting (comma, space, period) in the bottom detail panel for easier log analysis.
* **Persistent Configuration:** Automatically saves user settings, window state, and keyword preferences to an `.ini` file in `AppData`.

## Architecture Highlights

* **Optimized Tailer:** Uses a `System.IO.StreamReader` with `FileShare.ReadWrite` to reliably tail active log files without locking them.
* **High-Capacity Memory Management:** Pre-allocates up to 200,000 initial entries and dynamically scales up to 2.2 million items before trimming, drastically reducing array resizing overhead.
* **Memory Efficiency:** Implements `ObservableRangeCollection<T>` to handle bulk UI updates efficiently.
* **Zero-GC Pressure:** Uses `StringBuilder` and efficient string slicing (avoiding unnecessary concatenations) to parse logs with minimal garbage collection.
* **Mouse-Wheel Smoothing:** Features custom `PreviewMouseWheel` handling to provide granular, "slow" scrolling for precise log investigation.

## Getting Started

1. **Requirements:** PowerShell 5.1 or later (64-bit host required for large memory allocations).
2. **Run:** Simply execute the script in a PowerShell host capable of rendering WPF (e.g., `powershell.exe` or `pwsh.exe`).
3. **Opening Logs:** Use `File > Open...` to select a `.log` or `.txt` file.

## Settings & Configuration

The application allows full customization of:

* **Visuals:** Font family, font size, and window layout.
* **Highlighting:** Add, remove, or modify keyword/color mappings in the **Settings** menu.
* **Formatting:** Toggle JSON beautification or add custom delimiters for parsing complex message strings.

## Recent Optimizations & New Features

* **Increased Capacity Limits:** `MaxRetainedEntries` increased from 100k to 2,000,000. `InitialCapacity` increased to 200,000 to prevent constant array resizing during large file loads.
* **Faster Queue Processing:** `MaxDrainPerTick` increased to 50,000 to process background queue items significantly faster.
* **UI Performance Overhaul:** Added a 1-second throttle to `Update-StatusBar` for heavy statistics recalculations.
* **Initial Load Optimization:** During the initial file flush, the UI now only updates the total count text (an O(1) operation) instead of triggering full layout updates, ensuring the window remains responsive while loading massive files.

---

*Developed for high-performance systems administration and rapid troubleshooting of massive log files.*
