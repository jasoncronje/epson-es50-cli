# scan

Tiny macOS CLI for the Epson ES-50 (or any scanner with an Image Capture driver).

    make install          # builds and installs to ~/.local/bin/scan
    scan info             # show scanner capabilities
    scan                  # one page -> ~/Documents/Scans/scan-<time>.pdf
    scan -b bills.pdf     # feed page 1 first, face up, top edge first; Enter when done
    scan -m gray -r 200 note.jpg

Run `scan --help` for all options. Needs Epson's ICA driver (installed with Epson Scan 2 / Software Updater).
