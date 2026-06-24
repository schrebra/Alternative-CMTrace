# PowerShell CMTrace Log Tool

A high-performance, WPF-based log viewer for PowerShell, specifically engineered to handle **massive log files (up to 10 million lines)** with minimal memory overhead and near-instant parsing. It mimics the functionality of the classic `CMTrace` utility while providing modern customization, multithreaded file tailing, and regex/keyword-based highlighting.

<img width="60%" alt="image" src="https://github.com/user-attachments/assets/85c2ddf4-a7c5-435f-ad51-f5575b9a14ad" />


## Key Features

* **Massive Log Support:** Capable of seamlessly loading, retaining, and viewing up to **10,000,000 log lines** in memory without crashing, trimming, or freezing the UI.
* **Crash-Proof Bulk UI Updates:** Implements a custom `ObservableRangeCollection<T>` that properly suppresses individual notifications during bulk adds, preventing WPF `ItemsControl` inconsistency exceptions and massive layout thrashing.
* **Multithreaded Performance:** Uses a dedicated background Runspace with a highly tuned 10,000-item drain limit per 50ms tick to tail files, preventing UI freezes during massive log reads.
* **WPF-Powered UI:** Modern `DataGrid` interface with strict item-level virtualization, ensuring smooth scrolling even with millions of log entries.
* **Throttled UI Rendering:** Intelligent UI update throttling ensures the statistics panel recalculates at a maximum of 1Hz during continuous heavy tailing, keeping the interface buttery smooth.
* **Optimized Initial Load:** Real-time total line count updates without triggering heavy layout recalculations during the initial file flush, keeping the window draggable and responsive.
* **Zero-Cost Timestamp Parsing:** High-speed C# log parsing integrated directly into the script. Extracts timestamps via direct string slicing instead of `DateTime.TryParse`, yielding a ~5x parsing speedup.
* **Customizable Highlighting:** Define custom keywords and color schemes (Red, Orange, Yellow, Green, Blue, Purple, White) to instantly spot errors and warnings.
* **Detail Formatting:** Includes intelligent JSON formatting and delimiter splitting (comma, space, period) in the bottom detail panel for easier log analysis.
* **Persistent Configuration:** Automatically saves user settings, window state, and keyword preferences to an `.ini` file in `AppData`.

## Architecture Highlights

* **Optimized Tailer:** Uses a `System.IO.StreamReader` with a 64KB buffer and `FileShare.ReadWrite` to reliably tail active log files at maximum disk I/O speeds without locking them.
* **High-Capacity Memory Management:** Pre-allocates 500,000 initial entries and dynamically scales up to 11 million items before trimming, drastically reducing array resizing overhead and GC pressure.
* **O(1) Auto-Scrolling:** Caches the WPF `ScrollViewer` reference and uses `ScrollToEnd()` instead of `ScrollIntoView()`, bypassing expensive visual tree realization and layout calculations.
* **Smart Filtering Bypass:** Automatically skips the C# filtering logic and injects raw batches directly into the UI collection if no level filters are active.
* **Zero-GC Pressure:** Uses `StringBuilder` and efficient string slicing (avoiding unnecessary concatenations and date parsing) to parse logs with minimal garbage collection.
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

* **10 Million Line Capacity:** `MaxRetainedEntries` increased to 10,000,000. `InitialCapacity` increased to 500,000 to prevent constant array resizing during massive file loads.
* **WPF Crash Fix:** Completely rewrote `ObservableRangeCollection` to fire a single `Reset` event after bulk additions, fixing the "ItemsControl is inconsistent with its items source" crash when ingesting hundreds of thousands of lines per second.
* **5x Faster Parsing:** Replaced `DateTime.TryParse` with direct `Substring` extraction for CMTrace timestamps.
* **High-Throughput I/O:** Increased `StreamReader` buffer size to 64KB to minimize system calls during initial file reads.
* **Instant Auto-Scroll:** Replaced `DataGrid.ScrollIntoView()` with cached `ScrollViewer.ScrollToEnd()` for O(1) scrolling performance.
* **UI Thread Protection:** Tuned `MaxDrainPerTick` to 10,000 and the refresh timer to 50ms, ensuring the UI thread is never starved even if the background parser ingests 50,000+ logs/sec.

---

*Developed for high-performance systems administration and rapid troubleshooting of massive log files.*
