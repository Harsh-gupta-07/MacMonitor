# MacMonitor

MacMonitor is a lightweight, high-performance system monitoring tool for macOS that lives right in your menu bar. Built with Swift and SwiftUI, it provides real-time insights into your system's CPU and RAM health with an interface that feels right at home on modern macOS.

## Features

- **Real-time CPU Monitoring**: Tracks processor load across all cores using high-precision Mach kernels APIs.
- **Accurate RAM Usage**: Calculates memory pressure using Activity Monitor logic (App Memory + Wired + Compressed).
- **Swap Visibility**: Displays swap memory usage alongside physical RAM for a complete picture of memory pressure.

## Prerequisites

- **OS**: macOS 13.0 (Ventura) or later.
- **Tools**: Swift Compiler (`swiftc`) and `make`. These are included with **Xcode** or **Xcode Command Line Tools**.
  - To install command line tools, run: `xcode-select --install`

## Setup & Installation

1. **Clone the Repository**:

   ```bash
   git clone https://github.com/Harsh/MacMonitor.git
   cd MacMonitor
   ```

2. **Build the Application**:
   Use the provided `Makefile` to compile the app:

   ```bash
   make build
   ```

   _This will create the executable in the `./bin` directory._

3. **Run MacMonitor**:

   ```bash
   make run
   ```

4. **Run in Background (Detached)**:
   If you want to keep it running after closing your terminal:
   ```bash
   make run-detach
   ```

## Usage

- **Click** the percentage display in your menu bar (`CPU% : RAM%`) to open the detailed monitor window.
- **View Stats**: See the breakdown of physical RAM used, swap used, and total system capacity.
- **Quit**: Click the `X` icon in the top right of the monitor window to exit the application.

## Development

The project is designed to be extremely simple to modify. The core logic is contained entirely within `MenuBarWidgetApp.swift`.

- **Compiler Flags**: `-parse-as-library -framework SwiftUI -framework AppKit`
- **APIs Used**: `mach_host_self`, `host_processor_info`, `host_statistics64`, `sysctlbyname`.
