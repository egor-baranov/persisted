# Persisted landing page

A single static page: HTML, CSS, and a small JavaScript file. There is no framework, build dependency, analytics, remote font, or tracking script. All assets and downloads are local.

## Preview

From the repository root:

```sh
python3 -m http.server 4173 --bind 127.0.0.1 --directory site
```

Open http://127.0.0.1:4173. The page also works from a static host. Native `<details>` questions and all three product sections work without JavaScript. The small script adds screenshot enlargement, smooth FAQ expansion/collapse, FAQ hash expansion, and the copy command button. FAQ headings stay neutral on hover and when expanded; the answer and plus/minus animate together, respecting reduced-motion preferences. There are no tabs, carousel timers, or playback controls.

## Screenshots

`assets/screenshots/` contains real SwiftUI view renders with a synthetic, public-safe sample library. They show the saved layout catalog, grouped desktops/apps, and the arrangement editor. They are not images of a user's live windows or saved data. See that folder's README for the exact regeneration command.

## Downloads

```sh
python3 Scripts/package-site.py
```

The script creates an app-only ZIP and an allowlisted source ZIP under `site/downloads/`, plus a size/SHA-256 manifest. It excludes local user data, library backups, signing settings, Git metadata, and build caches. It verifies the packaged app's signature before archiving and reads version, architecture, signature type, and notarization-staple status from the chosen app. The public [release-readiness summary](../docs/Release-Readiness.md) is included in the source archive.

By default it uses `PERSISTED_BUILD_DIRECTORY` or `build`. Select an exact artifact with `python3 Scripts/package-site.py --app /path/to/Persisted.app`, or use `--build-directory output`. A future signed release can refresh the website with `./Scripts/release.sh --package-site`; this publishes the same freshly built and verified app to the existing download URL. That option requires the normal release credentials and is not part of local code verification.

The existing preview is an ad hoc signed Apple silicon development build, not a notarized distribution release. The FAQ links to the artifact manifest; version and signing copy have been removed from the download area at the owner’s request. Use `Scripts/release.sh --package-site` with a valid signing identity and notarization profile for a future public release to replace the download and regenerate its metadata together.

The public repository URL and open-source license are intentionally deferred at the owner's request. No GitHub URL, license identifier, external support address, or production domain is invented. Add those when supplied; the current source download remains available locally. Choosing a license remains a separate owner decision.

## Design references

The initial HTML/CSS/JS revision was generated with the local `adesign` agent from the previous page and the native screenshot assets. The current revision restructures that foundation after a broader reference review: centered hero, three separate screenshot sections, compact Auto/local-storage cards, and a rounded FAQ/footer based on the owner’s TypoTab reference. The main download button uses the requested black pill treatment with an Apple icon. The repeated lower download section has been removed. Header actions use rounded hover/press backgrounds without link underlines. Build instructions are available in an expandable FAQ, linked from the source card and footer. Integration preserves those original images, download targets, accessibility interactions, and page metadata. Intermediate generator workspaces and source archives stay under `build/adesign/` and are not published or included in source downloads.

Primary visual references selected by the owner, reviewed in a browser:

- [TypoTab](https://www.typotab.com/): centered benefit headline and short explanation; related feature headings, copy, and product views stay together.
- [Supaste](https://www.supaste.com/): clear hero-to-product sequence and a FAQ introduction above the questions.
- [VoiceOS](https://www.voiceos.com/): restrained typography and concrete product demonstrations immediately following their introductions.
- [Resurf](https://resurf.so/): one coherent product tour with named views, plus a calm, narrow reading measure.

The broader [Macfolio](https://macfolio.com/) survey included Keyty, Homy, Tangerine, Orion, Minimal Paste, Strata Files, and Shottr. These informed grouping, native product imagery, and download clarity. The current page retains a flat background and unframed screenshot surroundings, rather than adopting the references’ decorative backgrounds. Titles use normal case.

The original monochrome window-tile mark is in `assets/persisted-mark.svg`, with a separate light/dark favicon. A fresh Macfolio icon survey (including Rushilo’s compact bars, Vivaldi’s single-symbol mark, and Zen’s concentric shape) informed the reduction to a few shapes that read at small sizes. The detailed monitor illustration is no longer used in site branding.

The implementation uses original copy and composition. It does not copy their branding, screenshots, code, or claims.

## Publishing

Upload the contents of `site/` to any static web host. No server runtime is required. Before publishing, replace the development preview with the intended release, add the actual repository and license once chosen, and add a canonical URL / absolute Open Graph image URL for the real domain. A local preview is provided; no public deployment has been made.

## Verification

Checked in the Codex in-app browser at 320, 390, 768, and 1280 CSS pixels wide with no horizontal overflow. Screenshot enlargement, close/Escape and focus return, build-command copying, FAQ expansion, and section navigation work. No browser warnings or errors were reported. Both archive URLs return successfully and both ZIP files pass integrity checks.

The reference-driven revision is checked at the same four widths. The hero and feature headings sit above their content, feature headings sit directly above their copy, and screenshot surfaces have no decorative background panels. The “What to expect” link opens its corresponding FAQ. The static page has no dependency on the adesign canvas runtime.

The native screenshot mode builds successfully, uses validated sample layouts and inert services, and exits without reading the user's layout library or requesting Accessibility access. The current code passes 254 Swift tests across 14 suites and 10 release-tooling tests. The generated Xcode project previously passed `plutil -lint`. The installed app and downloadable archives were not replaced during the latest code fixes.

The current revision renders each screenshot at its natural aspect ratio in its own section. All three remain visible in document order. FAQ/footer destinations are real local sections and downloads; no support addresses, repository links, or policy pages are invented.
