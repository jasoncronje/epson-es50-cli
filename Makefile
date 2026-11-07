PREFIX ?= $(HOME)/.local

scan: scan.swift
	swiftc -O scan.swift -o scan

install: scan
	install -d $(PREFIX)/bin
	install -m 755 scan $(PREFIX)/bin/scan

clean:
	rm -f scan
