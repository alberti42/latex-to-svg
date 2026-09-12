# Changelog

All notable changes to this project are documented in this file.

This repository ships three packages that share one version/tag stream:
`latex-to-svg-frontend` (the core) and its `latex-to-svg-for-markdown` and
`latex-to-svg-for-org` adaptors.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.16.1] - 2026-09-12

### Fixed

- Org: inline `~code~` / `=verbatim=` spans are now excluded from detection,
  so writing about the delimiters themselves (`=\(=` and `=\)=`) stays literal
  text instead of being previewed as math. The exclusion reuses Org's own
  `org-verbatim-re` when available (so what we skip is exactly what Org
  fontifies as verbatim), with an equivalent built-in fallback otherwise.
- Markdown: block code is now excluded even with no `markdown` tree-sitter
  grammar installed. A regexp fallback (used only when the parse did not run)
  covers CommonMark fenced blocks with **either** fence character — 3+
  backticks or 3+ tildes, closing fence at least as long as the opening one,
  an unclosed fence running to end of buffer — and 4-space / tab **indented**
  code blocks, which have no delimiters at all. The fallback does not treat
  list continuation, a paragraph's indented lines, or `~~strikethrough~~` as
  code. Inline code spans were, and remain, excluded regardless of grammar.

## [0.16.0] - 2026-09-09

### Added

- `latex-to-svg-frontend-padding` now accepts per-side values, so
  the box can have a left gutter (or any other asymmetric inset) instead of the
  same inset all round: a list of one to four numbers read in CSS order —
  `(ALL)`, `(VERTICAL HORIZONTAL)`, `(TOP HORIZONTAL BOTTOM)`,
  `(TOP RIGHT BOTTOM LEFT)`. A left gutter and nothing else is `(0 0 0 6)`. A
  plain number keeps its meaning (all four sides), and the customize `:type`
  offers both forms. Requires `latex-to-svg-backend` 0.9.0.

### Added

- `latex-to-svg-frontend-center-display-math` (default nil): center
  display-math previews in the window, the way a LaTeX document centers them.
  Inline math is never centered. This is a display-time indent, not part of
  the image — a `before-string` whose stretch is
  `(space :align-to (- center (0.5 . IMAGE)))`, so redisplay re-centers on a
  window resize, a split, a font change or `display-line-numbers-mode` with no
  refresh and, notably, without measuring the image (`image-size` on an
  undisplayed SVG is not reliable, which is why the engine does not measure
  either). An equation wider than the window, or one not starting its own
  line, stays where it is.
- `:safe` predicates on **every** option except `latex-to-svg-frontend-mode-hook`,
  so a per-file or per-project value in a `-*-` line or `.dir-locals.el`
  applies without the "risky local variable" prompt. These carry data only —
  booleans, numbers, color strings, environment names; no paths and no code —
  which is the same rule the engine follows. The mode hook is deliberately
  excluded: a file-local hook is arbitrary code. What is executed and which
  LaTeX gets compiled belong to the engine, which keeps those options unsafe.
  The padding predicate accepts every shape the engine takes (one to four
  numbers), including the CSS shorthands Customize cannot express.

### Changed

- `latex-to-svg-frontend-background-padding` is renamed
  `latex-to-svg-frontend-padding`: with per-side values the option is no longer
  only about the background box — without a box color the padding is
  transparent, so a symmetric value is invisible, but an asymmetric one still
  shifts the equation within its own image (a left-only pad indents it). The
  old name keeps working as an obsolete alias, declared *before* the
  `defcustom` so a config that sets it before this file loads is still
  honored.
- The docstring no longer claims padding is visible *only* with a background
  color, for the same reason.

## [0.15.2] - 2026-09-07

### Fixed

- Key names in docstrings are no longer written as `` `RET' ``. Back-quotes in a
  docstring link an Elisp symbol, and `RET` is a key, so those rendered as dead
  links in help.

## [0.15.1] - 2026-09-03

### Changed

- Installation instructions no longer install the engine by hand:
  `latex-to-svg-backend` is on MELPA and arrives through the
  `Package-Requires` header.
- A tree-sitter failure while excluding Markdown code blocks is now reported
  once per buffer instead of passed over. Node names vary between `markdown`
  grammars, so a grammar that does not know the query signals rather than
  matching nothing -- and the silent recovery left fenced and indented blocks
  unexcluded, rendering math inside them with no hint why.
- A buffer font the frame cannot measure is now reported once per buffer,
  instead of being passed over silently. The height stays unknown either way,
  so the engine still defers sizing to display time; the difference is that a
  frame whose font cannot be opened now says so.

## [0.15.0] - 2026-08-24

### Added

- `latex-to-svg-frontend-environments`: the list of LaTeX environments to
  render, extendable (`tikzpicture`, a package's own display, …) or `t` for
  any environment. A trailing `*` is ignored when matching, so `equation`
  covers `equation*`. `latex-to-svg-frontend-detect-environments` remains the
  on/off switch for the family; this says which names it covers.

### Changed

- An environment opener is now only recognised when nothing but whitespace
  precedes it on its line. Prose that mentions `\begin{equation}`
  mid-sentence is no longer turned into a preview. The matching `\end{env}`
  is unrestricted.
- `\begin{env}` is no longer detected for *every* environment name, only for
  those in `latex-to-svg-frontend-environments`. Previously any name was
  compiled — including non-math ones like `itemize` or an inner-only
  `pmatrix`, which is not valid as a standalone document. Add a name back to
  the list to restore it.

## [0.14.0] - 2026-08-19

### Added

- Previews now follow a **frame** font change (`set-frame-font`,
  `doom/increase-font-size`, `doom-big-font-mode`, …): add the handler to
  `after-setting-font-hook`. `text-scale-mode-hook`, which the mode installs
  itself, only covers buffer-local zoom, so previews previously rescaled only
  on their next redisplay. As with the theme hook, nothing is installed on
  your behalf. Thanks to @howsiwei (#1).

### Changed

- One handler for both global appearance hooks:
  `latex-to-svg-frontend-on-appearance-change`. Theme switch and frame font
  change need the exact same work (an appearance-checked sweep of the mode's
  buffers), so there is one function to add to both hooks:

  ```elisp
  (add-hook 'enable-theme-functions
            #'latex-to-svg-frontend-on-appearance-change)
  (add-hook 'after-setting-font-hook
            #'latex-to-svg-frontend-on-appearance-change)
  ```

### Deprecated

- `latex-to-svg-frontend-on-theme-change` is now an obsolete alias of
  `latex-to-svg-frontend-on-appearance-change`. Existing configurations keep
  working; update them at your convenience.

## [0.13.0] - 2026-08-14

### Added

- `latex-to-svg-frontend-refresh` takes a prefix argument (non-nil ALL from
  Lisp) to refresh **every** buffer with previews, not just the current one —
  for a global change no appearance check can see, such as setting
  `latex-to-svg-frontend-foreground-color`, `-background-color`,
  `-background-padding`, or the rescales. Without it the command keeps its
  current-buffer-only behavior.

### Fixed

- Org adaptor: `latex-to-svg-for-org--exclusions` signalled *"Invalid search
  bound (wrong side of point)"* when a bounded scan ended inside a
  `#+begin_src`/`example`/`export`/`comment` block — the unbounded `#+end_…`
  search left point past END, breaking the next bounded search. Since the
  failure happened on `post-command-hook`, Emacs silently removed
  `latex-to-svg-frontend--handle-cursor` from the hook and reveal-on-cursor /
  render-on-leave stopped working for the rest of the session.

## [0.12.0] - 2026-08-13

### Added

- `latex-to-svg-frontend-return-follows-reference` (default `nil`): whether
  `RET` on an `\eqref` / `\ref` preview follows it.

### Changed

- References no longer steal `RET`. The keyboard gesture is now `C-c C-o`, as
  in Org (`org-open-at-point`); `RET` inserts a newline again — it previously
  followed the reference even with point at its first character, so a line like
  `  \eqref{eq:test}  ` could not be broken there. Set
  `latex-to-svg-frontend-return-follows-reference` to `t` for the old binding
  (the analogue of `org-return-follows-link`, also `nil` by default).

- `\eqref` / `\ref` previews are now clickable the standard Emacs way instead
  of hard-binding `mouse-1`. `latex-to-svg-frontend--reference-keymap` binds
  `mouse-2` (as Org's `org-mouse-map` does) and declares the span a link with
  `[follow-link]` -> `mouse-face`, so `mouse-1-click-follows-link` (default
  450 ms) applies: a **short** `mouse-1` click jumps, a **long** press falls
  through to `mouse-set-point` and reveals the LaTeX source, and dragging from
  inside a reference selects text again instead of jumping. `RET` still jumps.
- Reference reveal-on-cursor still ignores mouse events (a click is a jump, not
  an edit) — now for a hard reason as well as a stylistic one: revealing on the
  button press reflows the line, so Emacs sees a different buffer position at
  release and reports `drag-mouse-1`, which never follows a link.
- Reference `help-echo` now reads `"mouse-2: jump to the equation labelled …"`,
  which `mouse-fixup-help-message` rewrites to `mouse-1` / `double-mouse-1` /
  `Long mouse-1` according to the user's `mouse-1-click-follows-link`.

### Fixed

- Emphasis suppression now handles markup that **bridges across equations**. A
  stray marker inside one equation (the `=` in `\(\Delta{=}0\)`, the `+` in
  `(+)`, ...) can pair with a marker inside the *next* equation, and the markup
  fontifier then decorates everything in between — including the prose caught
  between the two (`Isotropic model ...`). The suppression pass now walks the
  font-lock face runs and clears any run anchored to a marker that lives inside
  a detected math span, over its whole extent, so the bridged prose is fixed
  too. A legitimate prose emphasis that merely *contains* inline math (markers
  in prose) is left untouched.
- Over math *source text* the spurious face is now **removed outright** rather
  than masked, so the emphasis colour (e.g. the `org-verbatim` tint) is cleared
  as well, not just the strike-through / underline. Preview overlays keep using
  the masking face (an image hides the text, so only drawn-over decoration
  matters).

## [0.11.0] - 2026-08-10

### Added

- `latex-to-svg-frontend-on-theme-change`: a function you can add to
  `enable-theme-functions` for instant re-tinting when you switch themes:

      (add-hook 'enable-theme-functions
                #'latex-to-svg-frontend-on-theme-change)

### Changed

- Previews no longer add any hooks merely by loading the package.
  `latex-to-svg-frontend-mode` installs its appearance-refresh hooks
  **buffer-locally** on activation (`window-buffer-change-functions` for
  redisplay, `text-scale-mode-hook` for zoom) and removes them on
  deactivation.  The package installs no global hooks: theme re-tinting is
  opt-in via the function above (previews otherwise re-tint on their next
  redisplay).  Loading is now side-effect-free.

## [0.10.0] - 2026-08-10

### Added

- `latex-to-svg-frontend-foreground-color`,
  `latex-to-svg-frontend-background-color`, and
  `latex-to-svg-frontend-background-padding`: customize the preview tint, paint
  an optional box color behind previews (e.g. a light-gray background), and pad
  that box beyond the ink. All default to nil (follow the buffer foreground /
  transparent / cropped to the ink, unchanged behavior) and are passed to
  `latex-to-svg-backend` as `:color` / `:background` / `:padding`, so they
  re-tint / re-box / re-pad from cache without a LaTeX recompile; run
  `latex-to-svg-frontend-refresh` after changing them.

### Changed

- Measure the buffer font height against the buffer's actual display frame and
  pass it to the engine as `:font-height`, so previews size correctly even when
  an async render/callback fires while a TTY/daemon frame is selected, and the
  engine never has to guess a frame. Requires `latex-to-svg-backend` 0.8.0.

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

[Unreleased]: https://github.com/alberti42/latex-to-svg/compare/v0.16.1...HEAD
[0.16.1]: https://github.com/alberti42/latex-to-svg/compare/v0.16.0...v0.16.1
[0.16.0]: https://github.com/alberti42/latex-to-svg/compare/v0.15.2...v0.16.0
[0.15.2]: https://github.com/alberti42/latex-to-svg/compare/v0.15.1...v0.15.2
[0.15.1]: https://github.com/alberti42/latex-to-svg/compare/v0.15.0...v0.15.1
[0.15.0]: https://github.com/alberti42/latex-to-svg/compare/v0.14.0...v0.15.0
[0.14.0]: https://github.com/alberti42/latex-to-svg/compare/v0.13.0...v0.14.0
[0.13.0]: https://github.com/alberti42/latex-to-svg/compare/v0.12.0...v0.13.0
[0.12.0]: https://github.com/alberti42/latex-to-svg/compare/v0.11.0...v0.12.0
[0.11.0]: https://github.com/alberti42/latex-to-svg/compare/v0.10.0...v0.11.0
[0.10.0]: https://github.com/alberti42/latex-to-svg/compare/v0.9.3...v0.10.0
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
