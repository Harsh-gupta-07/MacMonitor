build:
	@swiftc -parse-as-library -o ./bin/MacMonitor -framework SwiftUI -framework AppKit MenuBarWidgetApp.swift

run: build
	@./bin/MacMonitor

run-detach: build
	@./bin/MacMonitor & disown


