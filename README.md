# BahaiResearch

Desktop research assistant for finding sourced Bahá’í quotes from a **local authenticated corpus** (with optional AI-assisted intent/reranking).

## What this project does

- Uses a local SQLite corpus for quote retrieval. Source titles are from baha.org/library
- Supports curated source ingest (DOCX/HTML/PDF) from `data/corpus/curated/en`
- Returns structured results (quote, author, book, locator/page, URL)
- Runs in local-only mode (no web lookup at query time)
- Originally was set up to use Gemini AI and look for quotes on the web, but there were hallucinations
- BahaResearchofResults.docx has a list of quotes returned when the AI was producing quotes from the web
- AI now evaluates research input and ranks words for search. It also tries to guess a good source -- author, title
- AI also ranks the returned quotes in order of most relevant
- Search uses a NEAR → AND → OR query tier: 2-keyword searches try proximity matching first (both words within 15 words of each other), then fall back to AND, then OR
- Author dropdown drives the Title dropdown — selecting an author loads only that author's titles from the DB; Title is disabled until an author is chosen
- Future plans to research other AI api's to see if they perform better. 
- Each result includes a clickable Source link that opens the browser at the exact paragraph. Locators are HTML anchor IDs embedded in the bahai.org xhtml source files. For the 4 non-xhtml files (docx/pdf), Source opens the file in the registered OS handler (Word, Edge, etc.), but goes to the beginnin of file. Use Search for these.
- Used chatgpt-5.3-codex for original design and coding. Used sonnet-4.6 for improvements to search algorithm and finish. 

## Android Version

An Android port of this app exists at `D:/AI-Python/BahaiResearchA` (also on GitHub as BahaiResearchA).

**That project is dependent on this one.** The Android app ships with a pre-built copy of `data/corpus/corpus.db` as a static asset. It does not perform ingestion. If new books are added to this corpus and re-ingested, the updated `corpus.db` must be copied to the Android project's `app/src/main/assets/corpus.db` to pick up the new content.

## BahaiSearchCommon ##
This is the common search routines used by this Windows version and the Android version.
It is a separater project and is imported by gradle during the build of this project.


---

## Tech stack

- Java 21
- JavaFX
- SQLite
- Gradle
- Inno Setup
- Optional Gemini API integration for intent/reranking

---

## Build

All commands below are run from project root.

### Windows installer release (normal path)

The installer needs nothing but Inno Setup on Windows: no JDK, Gradle, jpackage or WiX.
All building happens on Linux.

The version lives only in `build.gradle` (`version = '1.5.0'`). Bump it there and every
downstream step follows, including the number stamped into the installer.

1) On Linux, build the payload:

```bash
./tools/package-windows-payload.sh
```

This produces `dist/installer/BahaiResearch/` (the `{app}` layout: `app/` with a universal
jar that runs on Windows and Linux, `runtime/` cross-built by `jlink` from the Windows JDK,
and the curated sources) plus `dist/BahaiResearch-win-payload-<version>.zip`, about 87 MB.

2) Copy the zip to the Windows machine and place it in the project's `dist\` folder:

```bash
cp dist/BahaiResearch-win-payload-<version>.zip /media/     # VirtualBox shared folder
```

```cmd
move X:\BahaiResearch-win-payload-<version>.zip D:\AI-Python\BahaiResearch\dist\
```

The script packages this file if it is present and skips the download. It echoes the zip's
byte size and timestamp, which should match what the Linux script printed. Publishing the
zip as a release asset also works: delete the local copy and the script downloads it.

3) On Windows, compile the installer:

```cmd
cd D:\AI-Python\BahaiResearch
git pull
tools\release-windows.bat 1.5.0
```

Output lands in `dist\installer-output\BahaiResearch-Setup.exe`, ready to upload to the
release. Nothing is edited on Windows.

### Legacy: portable app-image built on Windows

`package-installer.bat` still works on a Windows machine with a JDK, and produces a portable
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

---

## Runtime configuration (`KEY_PATH`)

The app reads settings from a properties file pointed to by environment variable `KEY_PATH`. If KEY_PATH is not set, reads from project root .properties file.

Create a local file like `bahai-research.example.properties` (do **not** commit real secrets):

```properties
gemini.apiKey=YOUR_API_KEY
gemini.model=gemini-2.5-flash

research.debugIntent=false
research.aiMode=full
research.noResultsText=No Results                ** text for No Results in output
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

---

## Run

### Option A: direct command

```cmd
set KEY_PATH=c:\path\to\bahai-research.properties && java -jar target\BahaiResearch-1.0.0-SNAPSHOT-all.jar
```

### Option B: helper script

```cmd
run-app.bat c:\path\to\bahai-research.properties
```

---

## Packaging recommendations

Use `tools/package-windows-payload.sh` (then `tools\release-windows.bat`) for end-user
distribution. The payload contains:

- `app/BahaiResearch-all.jar` — the fat jar, carrying both Linux and Windows JavaFX natives
- `runtime/` — a private Windows Java runtime from `jlink`, so no Java install is needed
- `app/data/corpus/curated/en/` (xhtml source files + manifest — required for Source deep links)
- `app/bahai-research.properties` (distributed privately, with ingest enabled on first run)

On first run the app ingests from the curated source files and builds `corpus.db` locally.

Recommended runtime flags:

- `corpus.autoIngestIfEmpty=true`
- `corpus.forceReingest=false`

Note: the curated xhtml source files must always be co-located with the app. The Source deep links resolve files at runtime using `corpus.basePath`.

---

## Git notes

- `.gitignore` excludes build output, runtime DB artifacts, ingest/snapshot outputs, and `*.properties`
- Keep secrets out of Git (especially API keys)

Typical workflow:

```cmd
git add .
git commit -m "Describe change"
git push
```

---

## Useful docs

- `DEPLOYMENT.md` – packaging and run details
- `SEARCH.md` – full search algorithm: query tiers, ranking, filters, debug logging

Version 2 notes:
Rough effort estimate:

- __Core v2 (safe split, no blending):__ low-to-medium effort
- __Polished v2 (ranking, source quality controls, better UI toggles):__ medium effort

The key is design:

1. keep authoritative quotes pipeline exactly as-is,
2. add optional commentary retrieval pipeline,
3. render in separate section with explicit label.

So yes — manageable, and your current local-first design makes it much easier and safer to add. If you want, I can draft a v2 implementation plan in phases (MVP → hardened).Not too difficult — __very doable for v2__ if you keep your current architecture and add commentary as a separate lane.

Rough effort estimate:

- __Core v2 (safe split, no blending):__ low-to-medium effort
- __Polished v2 (ranking, source quality controls, better UI toggles):__ medium effort

The key is design:

1. keep authoritative quotes pipeline exactly as-is,
2. add optional commentary retrieval pipeline,
3. render in separate section with explicit label.

## Warnings on Install and Firewall warning
This installer is safe, but it is not yet code‑signed.
Because of this, Windows SmartScreen may display a warning such as “Windows protected your PC” or “Unknown publisher.”
To install:

Click More info or Keep Anyway
Click Run anyway or Delete(DownArrow) -Keep Anyway

This happens because the installer is newly published and has not yet built up Windows reputation.
No system files are modified outside the application’s install directory.

On first use, Windows Firewall may ask for permission for the Java HTML server to run. This server provides access to the HTML source files #anchor numbers to open file to exact location of quote, but does not need access through the firewall, so deny the firewall rule setup.
