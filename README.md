

# PowerShell CMTrace Log Tool

A high-performance, WPF-based log viewer for PowerShell, specifically designed to handle large log files with minimal memory overhead and near-instant parsing. It mimics the functionality of the classic `CMTrace` utility while providing modern customization, multithreaded file tailing, and regex/keyword-based highlighting.

<img width="60%" alt="image" src="https://github.com/user-attachments/assets/ef912c06-0994-4d2e-a78d-2c7b7a5b18fe" />

## Key Features

* **Multithreaded Performance:** Uses a dedicated background Runspace to tail files, preventing UI freezes during large log reads.
* **WPF-Powered UI:** Modern `DataGrid` interface with virtualization, ensuring smooth scrolling even with hundreds of thousands of log entries.
* **Native Parsing:** High-speed C# log parsing integrated directly into the script, optimized to eliminate memory boxing/unboxing.
* **Customizable Highlighting:** Define custom keywords and color schemes (Red, Orange, Yellow, Green, Blue, Purple, White) to instantly spot errors and warnings.
* **Detail Formatting:** Includes intelligent JSON formatting and delimiter splitting (comma, space, period) in the bottom detail panel for easier log analysis.
* **Persistent Configuration:** Automatically saves user settings, window state, and keyword preferences to an `.ini` file in `AppData`.

## Architecture Highlights

* **Optimized Tailer:** Uses a `System.IO.StreamReader` with `FileShare.ReadWrite` to reliably tail active log files without locking them.
* **Memory Efficiency:** Implements `ObservableRangeCollection<T>` to handle bulk UI updates efficiently.
* **Zero-GC Pressure:** Uses `StringBuilder` and efficient string slicing (avoiding unnecessary concatenations) to parse logs with minimal garbage collection.
* **Mouse-Wheel Smoothing:** Features custom `PreviewMouseWheel` handling to provide granular, "slow" scrolling for precise log investigation.

## Getting Started

1. **Requirements:** PowerShell 5.1 or later.
2. **Run:** Simply execute the script in a PowerShell host capable of rendering WPF (e.g., `powershell.exe` or `pwsh.exe`).
3. **Opening Logs:** Use `File > Open...` to select a `.log` or `.txt` file.

## Settings & Configuration

The application allows full customization of:

* **Visuals:** Font family, font size, and window layout.
* **Highlighting:** Add, remove, or modify keyword/color mappings in the **Settings** menu.
* **Formatting:** Toggle JSON beautification or add custom delimiters for parsing complex message strings.

## Roadmap & Optimization

The tool is designed for developers who require:

* Minimal RAM footprint during long-duration tailing.
* The ability to easily regex/search across massive log data sets.
* A responsive, non-blocking UI for real-time diagnostics.

---

*Developed for high-performance systems administration and rapid troubleshooting.*
