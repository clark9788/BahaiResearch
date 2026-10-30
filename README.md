# BahaiResearch

Desktop research assistant for finding sourced Bahá'í quotes from a **local authenticated
corpus**, with optional AI-assisted intent parsing and reranking.

## Contents

- [What this project does](#what-this-project-does)
- [Tech stack](#tech-stack)
- [Build](#build)
- [Run](#run)
- [Runtime configuration](#runtime-configuration-key_path)
- [Packaging recommendations](#packaging-recommendations)
- [Installing on Windows](#installing-on-windows)
- [Related projects](#related-projects)
- [Useful docs](#useful-docs)
- [Git notes](#git-notes)
- [Possible v2: commentary lane](#possible-v2-commentary-lane)

## What this project does

- Uses a local SQLite corpus for quote retrieval. Source titles are from baha.org/library.
- Supports curated source ingest (DOCX/HTML/PDF) from `data/corpus/curated/en`.
- Returns structured results (quote, author, book, locator/page, URL).
- Runs in local-only mode — no web lookup at query time.
- Search uses a NEAR → AND → OR query tier: 2-keyword searches try proximity matching first
  (both words within 15 words of each other), then fall back to AND, then OR.
- The Author dropdown drives the Title dropdown: selecting an author loads only that author's
  titles from the DB, and Title is disabled until an author is chosen.
- Each result includes a clickable Source link that opens the browser at the exact paragraph.
  Locators are HTML anchor IDs embedded in the baha.org xhtml source files. For the four
  non-xhtml files (docx/pdf), Source opens the file in the registered OS handler (Word, Edge,
  etc.) but lands at the beginning of the file — use Search for those.
- AI is optional. It evaluates research input, ranks words for the search, guesses a likely
  author/title, and orders the returned quotes by relevance.

History: the app originally used Gemini AI to find quotes on the web, but that produced
hallucinations. `BahaiResearchOfResults.docx` records the quotes returned during that period.
AI is now confined to intent parsing and reranking, and local search works without it.

## Tech stack

- Java 21
- JavaFX
- SQLite
- Gradle
- Inno Setup (Windows installer)
- Optional Gemini API integration for intent/reranking

## Build

All commands below are run from the project root.

### Windows installer release (normal path)

The installer needs nothing but Inno Setup on Windows: no JDK, Gradle, jpackage or WiX. All
building happens on Linux.

The version lives only in `build.gradle` (`version = '1.5.0'`). Bump it there and every
downstream step follows, including the number stamped into the installer.

1) On Linux, build the payload:

```bash
./tools/package-windows-payload.sh
```

This produces `dist/installer/BahaiResearch/` (the `{app}` layout: `app/` with a universal jar
that runs on Windows and Linux, `runtime/` cross-built by `jlink` from the Windows JDK, and
the curated sources) plus `dist/BahaiResearch-win-payload-<version>.zip`, about 87 MB.

2) Copy the zip to the Windows machine and place it in the project's `dist\` folder:

```bash
cp dist/BahaiResearch-win-payload-<version>.zip /media/     # VirtualBox shared folder
```

```cmd
move X:\BahaiResearch-win-payload-<version>.zip D:\AI-Python\BahaiResearch\dist\
```

The script packages that file if it is present and skips the download. It echoes the zip's
byte size and timestamp, which should match what the Linux script printed. Publishing the zip
as a release asset also works: delete the local copy and the script downloads it.

3) On Windows, compile the installer:

```cmd
cd D:\AI-Python\BahaiResearch
git pull
tools\release-windows.bat 1.5.0
```

Output lands in `dist\installer-output\BahaiResearch-Setup.exe`, ready to upload to the
release. Nothing is edited on Windows.

`assets/BahaiResearch.ico` supplies the icon for the desktop and Start menu shortcuts, the
uninstaller entry, and the installer itself. It is already committed, so a normal release does
not touch it. To regenerate it after the Android launcher artwork changes, run this from a
Linux shell (Pillow is required and is not part of the Python standard library):

```bash
sudo apt install python3-pil    # or: pip install Pillow
python3 tools/make-windows-icon.py
```

It reads `BahaiResearchA/app/src/main/ic_launcher-playstore.png` by default; use `--source` if
that project lives elsewhere. No Windows machine is involved.

### Legacy: portable app-image built on Windows

`package-installer.bat` still works on a Windows machine with a JDK and produces a portable
jpackage app-image (plus an exe installer when WiX Toolset 3.x is present). It is not used for
installer releases any more: its version numbers are hardcoded in several places and must be
edited by hand for each release.

```cmd
gradlew.bat shadowJar
build-runtime-image.bat
package-installer.bat
```

Run `build-runtime-image.bat` again only when the Java version changes, the runtime modules
change, or `runtime/` is missing.

### Output artifacts

| Command | Output |
|---|---|
| `gradlew shadowJar` | `build/libs/BahaiResearch-<version>-all.jar` |
| `tools/package-windows-payload.sh` | `dist/installer/BahaiResearch/` and `dist/BahaiResearch-win-payload-<version>.zip` |
| `tools\release-windows.bat <version>` | `dist\installer-output\BahaiResearch-Setup.exe` |

## Run

Development runs need `KEY_PATH`, either as an environment variable, as the first argument, or
as a `bahai-research.properties` file next to the script.

### Option A: helper script

```cmd
run-app.bat c:\path\to\bahai-research.properties
```

On Linux:

```bash
./run-app.sh /path/to/bahai-research.properties
```

### Option B: direct command

```cmd
gradlew.bat run
```

or, against a built jar:

```cmd
set KEY_PATH=c:\path\to\bahai-research.properties
java -jar build\libs\BahaiResearch-1.5.0-all.jar
```

## Runtime configuration (`KEY_PATH`)

The app reads settings from the properties file named by the `KEY_PATH` environment variable.
If `KEY_PATH` is not set, it falls back to `bahai-research.properties` in the project root.

Copy `bahai-research.local-only.example.properties` and fill in real values. Do **not** commit
real secrets.

```properties
gemini.apiKey=YOUR_API_KEY
gemini.model=gemini-flash-latest

research.debugIntent=false
research.aiMode=full
research.noResultsText=No Results
research.maxQuotes=8
research.requestTimeoutSeconds=90

corpus.basePath=data/corpus
corpus.databaseFileName=corpus.db
corpus.snapshotsDirName=snapshots
corpus.ingestDirName=ingest
corpus.autoInitialize=true

corpus.sourceBaseUrl=https://www.bahai.org
corpus.ingestSeedUrl=https://www.bahai.org/library/
corpus.ingestMaxPages=5000
corpus.ingestRequestDelayMillis=150
corpus.minPassageLength=80

corpus.autoIngestIfEmpty=false
corpus.forceReingest=false

corpus.curatedIngestEnabled=true
corpus.curated.baseDir=curated/en
corpus.curated.manifestFileName=manifest.csv
```

Keep the file outside the repository (for example `~/.credentials/bahai-research.properties`)
and point `KEY_PATH` at it. `*.properties` is git-ignored, but an explicit path is safer.

## Packaging recommendations

Use `tools/package-windows-payload.sh` and then `tools\release-windows.bat` for end-user
distribution. The payload contains:

- `app/BahaiResearch-all.jar` — the fat jar, carrying both Linux and Windows JavaFX natives
- `runtime/` — a private Windows Java runtime from `jlink`, so no Java install is needed
- `app/data/corpus/curated/en/` — xhtml source files plus manifest, required for Source deep links
- `app/bahai-research.properties` — shipped privately, with ingest enabled on first run

On first run the app ingests from the curated source files and builds `corpus.db` locally.
Recommended flags for a packaged build:

- `corpus.autoIngestIfEmpty=true`
- `corpus.forceReingest=false`

The curated xhtml source files must always be co-located with the app: Source deep links
resolve files at runtime using `corpus.basePath`.

## Installing on Windows

### SmartScreen

The installer is safe, but it is not code-signed, so Windows SmartScreen may show "Windows
protected your PC" or "Unknown publisher". To install:

1. Click **More info** (or **Keep anyway**)
2. Click **Run anyway**

This happens because the installer is newly published and has not yet built up Windows
reputation. No system files are modified outside the application's install directory.

### Smart App Control

Windows 11 may also have Smart App Control, which has no "Run anyway" option. The install then
ends with:

```text
Unable to execute file in the temporary directory. Setup aborted.
Error 4551: An Application Control policy has blocked this file
```

To proceed, turn it off: Settings > Privacy & security > Windows Security > App & browser
control > Smart App Control > Off. Turning it off is one-way — Windows will not let you turn it
back on without reinstalling or resetting Windows. The alternative is a code-signed installer.

### Firewall prompt

On first use, Windows Firewall may ask for permission for the local Java HTML server. That
server only serves the bundled HTML sources on `localhost` so that `#anchor` links open at the
right paragraph. It does not need network access, so deny the firewall rule.

## Related projects

### Android version

An Android port exists at `D:/AI-Python/BahaiResearchA` (on the Linux side,
`~/projects/BahaiResearchA`), also on GitHub as `BahaiResearchA`.

**That project depends on this one.** The Android app ships a pre-built copy of
`data/corpus/corpus.db` as a static asset and performs no ingestion. When books are added here
and the corpus is re-ingested, the updated `corpus.db` must be copied to the Android project's
`app/src/main/assets/corpus.db`.

Build `corpus.db` on Linux only. A Windows-built database stores absolute paths from the
Windows filesystem and creates merge conflicts in the binary asset.

### BahaiSearchCommon

The shared search routines used by both this desktop version and the Android version. It is a
separate project, pulled in with `includeBuild('../BahaiSearchCommon')` during the Gradle build.

## Useful docs

- `SEARCH.md` — search algorithm: query tiers, ranking, filters, debug logging
- `README-Distribution.md` — notes to include with a distributed build
- `MoveToLinux.md` — Windows to Ubuntu migration notes
- `WindowsReleasePlan.md` — how the Linux-built Windows payload works, and what was verified
- `STYLE_GUIDE.md` — code style
- `ANDROID-PLAN.md`, `planSearchAdjust.md`, `search-improvements-plan.md` — design history

## Git notes

- `.gitignore` excludes build output, runtime database artifacts, ingest/snapshot outputs,
  `dist/`, and `*.properties`
- Keep secrets out of Git, especially API keys
- `data/corpus/corpus.db` is intentionally untracked: it is a build product, regenerated by
  ingest

Typical workflow:

```cmd
git add .
git commit -m "Describe change"
git push
```

## Possible v2: commentary lane

Keeping authoritative quotes separate from commentary is very doable without disturbing the
current architecture. Rough effort:

- **Core v2** (safe split, no blending): low-to-medium effort
- **Polished v2** (ranking, source quality controls, better UI toggles): medium effort

The key is design:

1. keep the authoritative quotes pipeline exactly as-is,
2. add an optional commentary retrieval pipeline,
3. render it in a separate section with an explicit label.
