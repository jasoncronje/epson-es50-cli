# scan

Tiny macOS CLI for the Epson ES-50 (or any scanner with an Image Capture driver).

    make install          # builds and installs to ~/.local/bin/scan
    scan info             # show scanner capabilities
    scan                  # one page -> ./scan-<time>.pdf in the current folder
    scan -b bills.pdf     # feed page 1 first, face up, top edge first; Enter when done
    scan -m gray -r 200 note.jpg
    scan clean old.pdf    # straighten/clean an existing scan -> old-clean.pdf
    scan -l contract.pdf  # long document (up to 72") as one tall page; --split for 11" pages

Pages are cropped to the sheet, turned upright, straightened and cleaned up
(white paper, darker text); blank pages are dropped. `--raw` turns this off,
`--keep-blank` keeps blank pages.

Long printouts (`-l`): tear off the tractor-hole strips (max width 8.5"), feed up
to 72" (6 pages) per stretch, top edge first, guiding the paper by hand. The
unused tail is trimmed and it is saved as one tall page. `--split` (or
`--page-length N`) cuts it into pages at the gap nearest every 11" (or N"). `--greenbar` removes green/blue bar stripes from computer printouts,
but also fades blue or coloured ink, so use it only on greenbar paper.

The ES-50 takes paper up to 72", but Image Capture and stock SANE stop at 14".
`sane/build.sh` builds SANE's epsonds backend with `sane/epsonds-long-paper.patch`
(it lets the scan area use the scanner's reported maximum, `#ADF AMAX`) into
`~/.local/share/scan/sane`. When that build exists, `scan -l` scans through it;
otherwise long scans stop at 14".

Run `scan --help` for all options. Needs Epson's ICA driver (installed with Epson Scan 2 / Software Updater).
