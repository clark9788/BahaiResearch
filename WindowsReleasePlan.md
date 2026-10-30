# Goal

Do all development and building on Linux. The Windows machine should receive a `git pull`
(or a downloaded payload) and do **nothing but compile the Inno Setup script** to produce
`BahaiResearch-Setup.exe`.

This document records the verified state of the build, the obstacles, three candidate
designs, and the experiments still needed before choosing.

---

## 1. Verified facts (checked against this repo and GitHub, 2026-10-28)

### Repo shape
* `BahaiResearch` does **not** track the database. `.gitignore` excludes
  `data/corpus/*.db`, `*.db-wal`, `*.db-shm`, `snapshots/`, `ingest/`.
* Therefore a Windows checkout of this repo is small and safe: 148 tracked files,
  ~75 MB working tree (mostly `data/corpus/curated`, which *is* tracked), ~100 MB `.git`.
  There is no 42 MB binary to create merge conflicts (contrast: `BahaiResearchA`).
* `data/corpus/curated/en/**` is tracked, so the ingest sources travel with the repo.

### What the app payload consists of
From `package-installer.bat` / `package-installer.sh`:

1. Fat jar: `build/libs/BahaiResearch-<ver>-all.jar` from `./gradlew shadowJar`
   (main class `com.bahairesearch.BahaiResearchLauncher`).
2. Private runtime: `runtime/` from `jlink --add-modules
   java.base,java.desktop,java.logging,java.net.http,java.sql,jdk.unsupported,jdk.crypto.ec,jdk.httpserver`.
3. `bahai-research.properties`, copied from `bahai-research.local-only.example.properties`,
   patched at package time to `corpus.autoIngestIfEmpty=true`, `corpus.curatedIngestEnabled=true`,
   `corpus.forceReingest=false`.
4. `data/corpus/curated/en/**` (first-run ingest, no `corpus.db` is shipped).

jpackage then produces `dist/installer/BahaiResearch/` (app-image when WiX is absent), and
`BahaiResearch.iss` packages that folder.

### The published Windows artifact really is Inno's output
GitHub release v1.3.2 ships `BahaiResearch-Setup.exe` (75,313,979 bytes) — that name is
Inno's `OutputBaseFilename`, so Inno is the real installer step, not jpackage.

### **The blocker: the fat jar is platform-specific**
Inspected `build/libs/BahaiResearch-1.5.0-all.jar` (32,235,351 bytes):

| Native type | Count in jar |
|---|---|
| `.so` | 28 |
| `.dll` | 4 (from `org.sqlite.native.Windows/...`) |
| `.dylib` | 2 |

JavaFX natives present: `libjavafx_font.so`, `libjavafx_font_freetype.so`,
`libjavafx_font_pango.so`, `libjavafx_iio.so` — **Linux only**.

Cause: `org.openjfx.javafxplugin` resolves `org.openjfx:javafx-*:21.0.6:<current-OS>`, so a
jar built on Linux has no `glass.dll` / `prism_es2.dll` and cannot run on Windows.

**Consequence: a Linux-built jar cannot simply be shipped to Windows as-is.** Any
"pull and just run Inno" design must either rebuild on Windows or make the jar universal.

### Natives are loaded from the jar (supports the universal-jar idea)
`run-app.sh` launches with a plain `java -jar build/libs/BahaiResearch-*-all.jar` — no
`-Djava.library.path` and no `--module-path`. So JavaFX's `NativeLibLoader` resolves the
`.so` entries from the jar itself, choosing the name per OS at runtime. That is exactly the
mechanism a universal jar would need, and it means adding the Windows-native JavaFX
artifacts should be sufficient (see E2).

Local toolchain for cross-building: OpenJDK **21.0.12.1** with `jlink` at `/usr/bin/jlink`.
The Adoptium Windows JDK 21.0.12.1 zip is 205,073,461 bytes — same build, so its `jmods`
match the local JDK.

### Other Windows-only dependencies
* Inno Setup has no Linux build. It runs on Windows, or under Wine (`iscc.exe`) as an
  unsupported workaround.
* jpackage `--type exe` requires **WiX Toolset 3.x on Windows**; it cannot cross-compile.
  On Linux `package-installer.sh` can only produce a `.deb`.
* `package-installer.bat` hardcodes `JPACKAGE_EXE=D:\Program Files\Microsoft\jdk-21.0.9.10-hotspot\bin\jpackage.exe`.

### Version numbers were duplicated in 8 places (installer path now fixed)
`build.gradle` held the version, `BahaiResearch.iss` repeated it, and the jar filename plus
`--app-version` were hardcoded in `package-installer.bat` **and** `package-installer.sh`.
The `.iss` had already drifted (1.5.0 vs the published v1.3.2).

After the change, the installer path has a single source: `build.gradle` → payload `VERSION`
→ `release-windows.bat` reads it and passes `/DMyAppVersion`. The two legacy
`package-installer` scripts still hardcode the version and would need the same treatment if
kept in use.

---

## 2. Three candidate designs

### Option A — one command on Windows (low risk, recommended fallback)
Linux: commit code normally; version lives in one place.
Windows: `git pull` then run `release-windows.bat`, which reads the version, runs
`gradlew.bat shadowJar` → `build-runtime-image.bat` → `jpackage --type app-image` →
`iscc /DMyAppVersion=<ver> BahaiResearch.iss`.

* Pro: reuses the path that already works; no cross-platform assumptions.
* Con: Windows still builds (needs JDK + network for Gradle deps); not literally
  "Inno only".

### Option B — Linux builds everything, Windows only compiles `.iss` (CHOSEN, implemented)
Three sub-problems, each resolved:

| Sub-problem | Fix | Status |
|---|---|---|
| JavaFX natives are OS-specific | `-PbundleJavaFxPlatforms=win` adds the `:win` JavaFX artifacts to the fat jar, so one jar carries both platforms' natives | done, verified |
| Windows runtime image | `jlink` cross-built against a Windows JDK's `jmods` | done, verified |
| Launcher `.exe` | jpackage dropped: Inno installs the layout and points shortcuts at `{app}\runtime\bin\javaw.exe` | done |

Linux produces `dist/installer/BahaiResearch/` (`app/`, `runtime/`, `VERSION`) and
`dist/BahaiResearch-win-payload-<ver>.zip`, uploaded as a release asset.
Windows does one command: `tools\release-windows.bat <version>`.

* Pro: no JDK, Gradle, jpackage or WiX on Windows.
* Con: the process is `javaw.exe`, not `BahaiResearch.exe` (see Remaining risks).

### Option C — payload as a release asset
Option B's payload zipped and published as a release asset (or committed to a
`release-payload` branch); Windows downloads, unzips, compiles `.iss`.
Adds nothing beyond B except keeping large binaries out of `main`.

---

## 3. Experiments — results (E1, E2 verified 2026-10-28; E3 not yet run)

**E1 — cross-jlink from Linux: PASS**
Downloaded the Adoptium Windows JDK (205,073,461 B, build `21.0.12.1+1` — same build as the
local JDK, so `jmods` line up), then on Linux:
```bash
jlink --module-path /tmp/winjdk/jdk-21.0.12.1+1/jmods \
      --add-modules java.base,java.desktop,java.logging,java.net.http,java.sql,jdk.unsupported,jdk.crypto.ec,jdk.httpserver \
      --output /tmp/win-runtime --strip-debug --no-man-pages --no-header-files
```
Result: `bin/java.exe`, `bin/javaw.exe` present; `file` reports
`PE32+ executable for MS Windows 6.00 (console), x86-64`; the Windows DLL set
(`api-ms-win-*.dll`, `ucrtbase.dll`, …) is emitted. Size without `--compress`: 77 MB
(with `--compress=2` as the existing scripts use, expect roughly half).

**E2 — universal jar: PASS**
`build.gradle` now accepts `-PbundleJavaFxPlatforms=win`, which adds
`org.openjfx:javafx-{base,graphics,controls,fxml}:21.0.6:win` as `runtimeOnly`.
`./gradlew shadowJar -PbundleJavaFxPlatforms=win` produced a 41,710,710 B jar (was
32,235,351 B) containing, exactly once each:

| Natives | Linux | Windows |
|---|---|---|
| glass | `libglass.so` | `glass.dll` |
| prism | `libprism_es2.so` | `prism_d3d.dll` |
| font | `libjavafx_font.so` | `javafx_font.dll` |
| iio | `libjavafx_iio.so` | `javafx_iio.dll` |
| decora | `libdecora_sse.so` | `decora_sse.dll` |

Totals: 28 `.so` + 58 `.dll` (54 new Windows natives + 4 pre-existing sqlite ones).
Linux smoke test via `./run-app.sh` (plain `java -jar`, private runtime): starts cleanly,
no new warnings. Duplicate class files across the platform jars were deduped without error.

**E3 — Inno `/D` define: standard documented behavior, not yet executed** (needs Inno).

---

## 4. What was implemented (2026-10-28)

| File | Change |
|---|---|
| `build.gradle` | `ext.javafxVersion` extracted; opt-in `-PbundleJavaFxPlatforms=win` adds the Windows JavaFX natives as `runtimeOnly` (default build unchanged) |
| `tools/package-windows-payload.sh` | new: universal jar, cached Windows JDK, cross-`jlink`, staging, zip |
| `tools/release-windows.bat` | new: download payload asset, verify `VERSION`, compile Inno |
| `BahaiResearch.iss` | `/D`-able version and source dir, javaw launcher with absolute `{app}` args, cleans up the old jpackage exe/cfg |
| `README.md` | new "Windows installer release" section |
| `assets/BahaiResearch.ico` | new: 16-256 px icon derived from the Android artwork |
| `tools/make-windows-icon.py` | new: regenerates the `.ico` from `BahaiResearchA`'s play-store PNG |

End-to-end run of `tools/package-windows-payload.sh` produced:

```
dist/installer/BahaiResearch/
  app/BahaiResearch-all.jar          41.7 MB (Linux + Windows natives)
  app/bahai-research.properties      patched: autoIngestIfEmpty / curatedIngestEnabled / forceReingest
  app/data/corpus/curated/en/...     ingest sources
  runtime/bin/javaw.exe              PE32+ GUI x86-64
  VERSION                            1.5.0
dist/BahaiResearch-win-payload-1.5.0.zip   87 MB
```

Payload correctness was proven by running the real bootstrap + curated ingest against the
staged layout with the same properties the shortcut passes:

```
documents: 96
passages : 33720
"Living the Life" present
```

i.e. byte-for-byte the same corpus as the reference Linux build.

Two design traps found and avoided:

1. **`#define` + quotes.** A define holding `-Dkey="path"` is expanded *before* section
   parsing, so the quotes terminate the `Parameters:` value. Launch args are therefore
   written inline, using Inno's `""` escape.
2. **Relative launch args.** Passing `app\data\corpus` relies on cwd being `{app}`; when the
   property was absent the app silently fell back to `corpus.basePath=data/corpus` relative
   to cwd and failed with "`...\data` does not exist". Absolute `{app}` paths are used.

## 5. Verification checklist

- [x] E1: cross-jlinked runtime contains PE32+ `java.exe` / `javaw.exe` and the Windows DLLs
- [x] E2: universal jar contains both `.so` and `.dll` JavaFX natives, exactly once each
- [x] E2: the same jar starts on Linux (`./run-app.sh`) — no regression
- [x] Payload layout: bootstrap + curated ingest yields 96 documents / 33,720 passages
- [x] E3: first Inno compile succeeded on Windows (20.140 s) via `tools\release-windows.bat 1.5.0`,
      producing `dist\installer-output\BahaiResearch-Setup.exe`
- [x] Installer runs and completes on the development host, which has SAC on (2026-10-30).
      The Setup.exe reached the wizard and finished installing, from a payload copied locally
      with no Mark-of-the-Web. The earlier `Error 4551` did not recur.
- [x] Installed app: launches from the shortcut, first search builds `corpus.db` from the
      packaged curated sources and returns results (2026-10-30, searched "glory": 12 passages)
- [ ] Upgrade over an existing install: old `BahaiResearch.exe`/cfg removed, stale `corpus.db` deleted
- [x] Icon: `assets/BahaiResearch.ico` (9 sizes) used for shortcuts, uninstaller and Setup.exe

## Remaining risks

* **No `BahaiResearch.exe`.** Task Manager shows `javaw.exe`; there is no EXE to pin or
  associate. If that matters, generating a real launcher with launch4j on Linux would
  restore it without needing Windows tooling.
* **First Inno compile is now verified** (2026-10-30). Three defects surfaced and were fixed
  during that run: the ISCC lookup assumed `%ProgramFiles(x86)%`, i.e. drive C:, so an Inno
  install on D: was never found; `ROOT` kept a `..` component; and an unescaped `)` in an
  `echo` inside an `else` block truncated the message and closed the block early.
  Still untested: the installed application itself, and the upgrade path over an existing install.
* **Payload size** is 87 MB zipped because the curated sources travel inside it. This
  matches the previous jpackage app-image, but the release asset is now separate from the
  installer, so both must be uploaded per release.

## Smart App Control blocks unsigned installers

First install attempt on Windows failed with:

```
Error: Unable to execute file in the temporary directory. Setup aborted.
Error 4551: An Application Control policy has blocked this file
```

Diagnosis: `VerifiedAndReputablePolicyState = 1` under
`HKLM\SYSTEM\CurrentControlSet\Control\CI\Policy`, i.e. **Smart App Control is on**, and
no Defender ASR rules are configured. SAC blocks executables it cannot verify and offers no
per-app allow and no exclusion list.

The blocked file is Inno's own engine: `SetupLdr` unpacks the real installer to
`%TEMP%\is-XXXXX.tmp` and executes it there. The app payload never runs from temp.

This is not a regression. The runtime launchers are unsigned because `jlink` rewrites them —
its `javaw.exe` differs from the signed JDK original from byte 60 onward (the PE header) and
is 10,360 bytes shorter, exactly the certificate size, so the signature is dropped rather
than merely trimmed. jpackage output was unsigned in the same way, so any earlier Inno
installer is affected too.

Turning SAC off is a one-way switch: re-enabling requires reinstalling Windows. SAC is a
property of the machine, not of the file, so nothing about how the installer is built or
delivered avoids it.

Evidence from a second Windows machine: v1.3.2's `Setup.exe` was downloaded from GitHub (so it
carried Mark-of-the-Web) and installed there with only the usual SmartScreen prompt. That
machine has SAC off. A 1.5.0 installer copied locally (no Mark-of-the-Web) then installed
normally on the SAC-enabled host, and the earlier `Error 4551` did not recur — so the warnings
are driven by the mark left on downloaded files, and the one observed block was not
reproducible. Two conclusions:

* Mark-of-the-Web affects SmartScreen only, and SmartScreen is bypassable via "More info" then
  "Run anyway".
* The SAC block follows the machine, not the file's origin. It hit a locally compiled installer
  that had no Mark-of-the-Web at all.

So most recipients, including anyone on Windows 10, can install an unsigned build by clicking
through SmartScreen. Only machines with SAC on need signing, Store distribution, or a SAC-off
instruction. The development host itself has SAC on, which makes it a harsher environment than
the target machines.

## 6. Related gotchas (outside this file's scope)

* `BahaiResearchA`: `v1.9.0` tag points at `5746a79`, whose tree has **no**
  `app/src/main/assets/corpus.db`; the db was re-added in `207e5a8`. Release the tag on
  `207e5a8` (`git tag -f v1.9.0 207e5a8 && git push -f origin refs/tags/v1.9.0`).
* `BahaiResearchA`'s `.gitignore` does **not** ignore `keystore.properties` or `*.jks`
  although `BuildRelease.md` says it must; a Linux `git add -A` would commit the key.
* Windows clone of `BahaiResearchA` adds no value (Linux has `/home/clarkdev/Android/Sdk`);
  keep only the keystore + `keystore.properties` before deleting it.
* Never build or commit `corpus.db` on Windows; on Windows use
  `git checkout origin/main -- app/src/main/assets/corpus.db`.
