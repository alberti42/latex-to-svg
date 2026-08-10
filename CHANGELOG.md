# Changelog

All notable changes to this project are documented in this file.

This repository ships three packages that share one version/tag stream:
`latex-to-svg-frontend` (the core) and its `latex-to-svg-for-markdown` and
`latex-to-svg-for-org` adaptors.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.9.3] - 2026-08-10

### Changed

- Frontend: neutralize strike-through/underline drawn across previews and
  strip spurious bold/italic emphasis decoration from math source text, so
  markup around an equation never bleeds into the rendered image.
- Realigned all three packages to a single lockstep version (0.9.3) and fixed
  the adaptors' stale `latex-to-svg-frontend` dependency floor (was 0.1.0).

### Fixed

- checkdoc cleanups across all three files (document arguments, complete the
  first-line summary, drop an embedded keycode, silence an unused argument) —
  MELPA pre-submission tidy-up.

## [0.9.0] - 2026-08-02

### Changed

- Split the dollar and bracket delimiter toggles into separate inline vs
  display toggles.

## [0.8.0] - 2026-08-02

### Changed

- Incremental, overlay-driven reconcile on cursor-leave; the whole-buffer scan
  is now O(n) and the reconcile's double scan is gone.

## [0.7.2] - 2026-08-02

### Added

- Restructured into a reusable `latex-to-svg-frontend` core plus
  `latex-to-svg-for-markdown` and `latex-to-svg-for-org` adaptors (previously
  an Org-only tool). Renaming an equation's label now re-points its references.

### Changed

- Synchronous reconcile on cursor-leave; renamed the internal `--render-left`
  to `--render-on-leave`.

## [0.7.1] - 2026-08-02

### Changed

- References re-resolve on every reconcile; a dangling reference shows as a
  plain-text `(??)` overlay (never LaTeX-typeset).

## [0.7.0] - 2026-08-02

### Added

- Auto-render newly typed math on cursor-leave.

### Removed

- Dropped calls to the removed `latex-to-svg-flush-metrics`.

## [0.6.1] - 2026-08-01

### Fixed

- Don't reveal a reference reached by mouse — a click is a jump, not an edit.

## [0.6.0] - 2026-08-01

### Added

- Reveal `\eqref`/`\ref` source on cursor entry for label editing.

## [0.5.0] - 2026-08-01

### Added

- Separate size multipliers for inline and display math.

## [0.4.3] - 2026-08-01

### Fixed

- Close the preview at the previous point rather than a tracked reference.

## [0.4.2] - 2026-08-01

### Added

- Re-render fragments that were edited and then left by point.

## [0.4.1] - 2026-08-01

### Changed

- Clear Org's native LaTeX previews when taking over rendering.

## [0.4.0] - 2026-08-01

### Added

- Reveal preview source on cursor entry.

## [0.3.0] - 2026-08-01

### Added

- Ground-truth equation numbers via a reconcile loop.

## [0.2.2] - 2026-08-01

### Changed

- Render `\eqref`/`\ref` as native buffer text rather than LaTeX.

## [0.2.1] - 2026-08-01

### Added

- Click-to-jump on `\eqref`/`\ref` previews.

## [0.2.0] - 2026-08-01

### Added

- Equation numbering and `\eqref`/`\ref` support.

## [0.1.1] - 2026-08-01

### Added

- Regenerate/clear commands; saner prefix arguments.

## [0.1.0] - 2026-08-01

Initial release (as the Org-only `org-latex-to-svg`).

### Added

- Preview Org LaTeX math as SVG images.

[0.9.3]: https://github.com/alberti42/latex-to-svg/compare/v0.9.0...v0.9.3
[0.9.0]: https://github.com/alberti42/latex-to-svg/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/alberti42/latex-to-svg/compare/v0.7.2...v0.8.0
[0.7.2]: https://github.com/alberti42/latex-to-svg/compare/v0.7.1...v0.7.2
[0.7.1]: https://github.com/alberti42/latex-to-svg/compare/v0.7.0...v0.7.1
[0.7.0]: https://github.com/alberti42/latex-to-svg/compare/v0.6.1...v0.7.0
[0.6.1]: https://github.com/alberti42/latex-to-svg/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/alberti42/latex-to-svg/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/alberti42/latex-to-svg/compare/v0.4.3...v0.5.0
[0.4.3]: https://github.com/alberti42/latex-to-svg/compare/v0.4.2...v0.4.3
[0.4.2]: https://github.com/alberti42/latex-to-svg/compare/v0.4.1...v0.4.2
[0.4.1]: https://github.com/alberti42/latex-to-svg/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/alberti42/latex-to-svg/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/alberti42/latex-to-svg/compare/v0.2.2...v0.3.0
[0.2.2]: https://github.com/alberti42/latex-to-svg/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/alberti42/latex-to-svg/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/alberti42/latex-to-svg/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/alberti42/latex-to-svg/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/alberti42/latex-to-svg/releases/tag/v0.1.0
