# scan

Tiny macOS CLI for the Epson ES-50 (or any scanner with an Image Capture driver).

    make install          # builds and installs to ~/.local/bin/scan
    scan info             # show scanner capabilities
    scan                  # one page -> ./scan-<time>.pdf in the current folder
    scan -b bills.pdf     # feed page 1 first, face up, top edge first; Enter when done
    scan -m gray -r 200 note.jpg
    scan clean old.pdf    # straighten/clean an existing scan -> old-clean.pdf
    scan -l -b report.pdf # long fanfold/dot-matrix printout, split into 11" pages

Pages are cropped to the sheet, turned upright, straightened and cleaned up
(white paper, darker text); blank pages are dropped. `--raw` turns this off,
`--keep-blank` keeps blank pages.

Long printouts (`-l`): tear off the tractor-hole strips (max width 8.5"), feed up
to 72" (6 pages) per stretch, top edge first, guiding the paper by hand. The
unused tail is trimmed, pages are cut at the gap nearest every `--page-length`
(default 11"), and greenbar/bluebar stripes are removed. `--no-split` keeps one
tall page.

Run `scan --help` for all options. Needs Epson's ICA driver (installed with Epson Scan 2 / Software Updater).
