# epson-es50-cli

I didn't want Epson's pile of scanner software on my Mac, so I wrote `scan`: a small
command-line tool that drives the Epson ES-50 directly. It's built to be run by AI agents and
scripts as much as by hand.

![A tilted yellow receipt on dark scanner backing, and the same receipt cropped, straightened and cleaned](docs/before-after.png)

*Made-up receipt: raw scan on the left, `scan`'s output on the right.*

## What it does

- Scans to PDF, JPEG or PNG
- Crops, straightens, turns upright and cleans every page, and drops blank pages
- Cuts small receipts and slips out of the scanner background
- Scans long documents up to 72" (stock drivers stop at 14")
- Needs no Epson software

## Install

Needs macOS 12+, Xcode command-line tools and Homebrew. Tested on the ES-50 only.

    sane/build.sh    # builds the patched SANE driver into ~/.local/share/scan/sane
    make install     # installs ~/.local/bin/scan

## Commands

| Command | Does |
|---|---|
| `scan` | Scans one sheet to `./scan-<time>.pdf` |
| `scan file.pdf` | Scans one sheet to `file.pdf` (`.jpg` / `.png` work too) |
| `scan -b file.pdf` | Batch: one PDF, page 1 first; Enter, Ctrl+C or `--wait` timeout finishes |
| `scan -b -n 5 file.pdf` | Batch that stops after 5 pages |
| `scan -l file.pdf` | Long document up to 72" as one tall page |
| `scan -l --split file.pdf` | Long document cut into 11" pages |
| `scan clean in.pdf [out.pdf]` | Cleans an existing PDF or image (`in-clean.pdf` by default) |
| `scan info` | Shows the scanner and what it supports |

## Options

| Option | Does |
|---|---|
| `-s letter\|legal\|a4\|a5\|b5` | Paper size (default letter) |
| `-m color\|gray\|bw` | Colour mode (default color) |
| `-r 200\|300\|400\|600` | Resolution in dpi (default 300) |
| `-w SECS` | How long to wait for paper (default 30) |
| `--raw` | Skips the clean-up |
| `--keep-blank` | Keeps blank pages |
| `--faint` / `--no-faint` | Softer clean-up for dot-matrix or carbon text (default on with `-l`) |
| `--greenbar` | Removes green-bar stripes from printouts (fades coloured ink) |
| `--page-length IN` | With `-l`, cuts pages every IN inches |
| `--json` | Prints a JSON result instead of file paths |
| `--open` | Opens the result |
| `-v` | Verbose log |

Feed sheets face up, top edge first, against the left side of the slot.

## For agents and scripts

- stdout has only the result: saved paths, one per line, or with `--json`:
  `{"files":["/path/a.pdf"],"pages":3,"skipped_blank":1}`, or on failure
  `{"error":"no sheet detected within 30s","exit":4}`
- Progress and errors go to stderr.
- It never prompts. With no terminal, a batch ends on `--wait`, `-n`, or SIGTERM / SIGINT,
  which save the pages scanned so far.

| Exit | Meaning |
|---|---|
| 0 | Saved |
| 2 | Bad usage or missing input file |
| 3 | No scanner found |
| 4 | No paper fed within `--wait` |
| 5 | Every page was blank |
| 6 | Scan or file error |
| 130 | Cancelled before anything was scanned |

## How long paper works

The ES-50 reports a 72" maximum (`#ADF AMAX`), but Epson's driver and stock SANE only use the
14" area. `sane/epsonds-long-paper.patch` makes SANE's `epsonds` backend use the maximum.
`sane/build.sh` builds that one backend from Homebrew's SANE source.

## Removing Epson's software

`sudo sh sane/remove-epson.sh` lists Epson's scanner apps, drivers and launch agents. Add
`--yes` to delete them. It's written for the ES-50, so check the list first.

## License

MIT. The SANE patch is GPL-2.0-or-later like the code it changes (`sane/LICENSE`).
