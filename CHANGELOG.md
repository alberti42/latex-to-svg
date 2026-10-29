# Changelog

All notable changes to this project are documented in this file.

This repository ships six packages that share one version/tag stream:
`latex-to-svg-frontend` (the core) and its `latex-to-svg-for-markdown`,
`latex-to-svg-for-org`, `latex-to-svg-for-latex`, `latex-to-svg-for-gnus`
and `latex-to-svg-for-elfeed` adaptors.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Requires `latex-to-svg-backend` 0.18.1, whose texres engine no longer
  cuts off the right side of an equation wider than the `varwidth` box
  (`latex-to-svg-backend-line-width`, default `\linewidth` ≈ 345pt).

## [0.25.1] - 2026-10-23

### Changed

- Requires `latex-to-svg-backend` 0.18.0, which makes
  `latex-to-svg-backend-preamble-not-precompiled` and
  `latex-to-svg-backend-preamble-not-precompiled-files` options again,
  for a package that cannot be dumped, and no longer turns precompiling
  off for the rest of the session after a failed dump. The previews
  follow the new names. The obsolete `-preamble-macros` and
  `-preamble-macro-files` still work. The README puts macro files in
  `latex-to-svg-backend-preamble-packages`, listed in
  `latex-to-svg-backend-preamble-package-files`.

### Fixed

- The editing preview's frame no longer stays visible over the text
  typed after math, after the math is deleted, or after the buffer is
  erased and filled again (pdf-tools does this in the buffer that edits
  an annotation). Text typed right after the closing delimiter counted
  as part of the math typeset while typing.

## [0.25.0] - 2026-10-21

### Changed

- Requires `latex-to-svg-backend` 0.17.0, which renames
  `latex-to-svg-backend-preamble` to `latex-to-svg-backend-preamble-base`.
  The previews follow the new name. The old name still works and shows a
  warning.

## [0.24.2] - 2026-10-20

### Added

- Setting the obsolete `latex-to-svg-frontend-padding` non-nil shows a
  warning, once per session, that says what to set instead. Before, Emacs
  reported it only when it compiled the code that set it, which an init
  file seldom is. The obsolete names
  `latex-to-svg-frontend-background-padding`,
  `latex-to-svg-frontend-inline-rescale` and
  `latex-to-svg-frontend-display-rescale` warn when they are set before
  the package loads, as an init file does; set after it loads, they cannot
  be told from the options they name.

### Removed

- The adaptors no longer check, when they are loaded, that the
  front-end Emacs loaded is the one of their release. MELPA builds each
  package on its own schedule, so for a few hours after a release an
  adaptor could be newer than the front-end, and it signalled an error
  at load. The front-end still checks the backend, and
  `latex-to-svg-frontend-check-version` stays for other packages.

## [0.24.1] - 2026-10-20

### Fixed

- The error an adaptor signals when Emacs loaded a front-end before
  0.24.0 starts with the adaptor's name as an argument of the message,
  so checkdoc, which wants a message to start with a capital letter,
  passes. The message is the same.

## [0.24.0] - 2026-10-20

### Added

- While point is in an equation and its LaTeX source is shown, the
  equation's image is shown in a child frame above it, so the rendered
  equation stays in view while you read or edit the source. The frame
  covers the text under it, which does not move. An edit is typeset once
  Emacs has been idle for
  `latex-to-svg-frontend-editing-preview-delay` (default 50 ms), with the
  equation's own engine and fallback, and the frame shows the new image;
  each new request cancels the one before. These requests write no warning
  for a failed formula, and a half-typed formula does not leave a failure
  record in the cache at every pause. Math with no picture yet, typed
  new or failed, shows the frame from its first picture on. When the edit
  does not typeset, as while it is half typed, the frame keeps the last
  image and draws its border in the foreground of the new face
  `latex-to-svg-frontend-editing-preview-failure-border`, which inherits
  `error`.
  `latex-to-svg-frontend-editing-preview-engine` typesets every edit with
  one engine instead, `ratex`, `texres` or `latex`, with no fallback: with
  `ratex` the picture comes sooner, but it may differ from the one the
  equation gets when point leaves it.
  `latex-to-svg-frontend-editing-preview` sets where the frame goes: `above`
  and `below` above or below the equation, starting where it starts and
  following it when the window scrolls; `smart-above-below` (default) above
  unless the frame fits only below, and `smart-below-above` below unless it
  fits only above; `right` at the right edge, beside the equation, and
  `smart-right` the same unless the frame would cover the lines of the
  equation, then as `smart-right-corner`; `top-right`, `top-left`,
  `bottom-left` or `bottom-right` at that corner; `smart-right-corner` is
  `top-right`, or `bottom-right` when the frame there would cover lines of the
  equation, and `smart-left-corner` the same on the left; nil turns the frame
  off.
  `latex-to-svg-frontend-editing-preview-padding` sets the padding around the
  image in the frame, with the values of the other padding options (pt;
  default 4). `latex-to-svg-frontend-editing-preview-margin` sets the
  distance in pixels between the frame and the edges of the text,
  `(TOP-BOTTOM LEFT-RIGHT)` (default `(4 4)`); a negative number moves the
  frame past the edge. Only on a graphical frame.
- Setting `latex-to-svg-backend-preamble-package-files` or
  `latex-to-svg-backend-preamble-macro-files`, the files the project's
  preambles load (backend 0.16.0), updates the previews, as setting a
  preamble does.
- `latex-to-svg-frontend-in-math-p` returns the math point is inside, or
  nil: strictly between its delimiters, and not in a reference. For a
  function that acts only in math, such as a completion function in
  `completion-at-point-functions`.
- When the front-end is loaded, it signals an error if the backend Emacs
  loaded is older than the one it requires, naming the backend's file,
  and says to update the backend to that version or newer and restart
  Emacs (issue #12). Before, an old backend failed at the first equation
  with an error about a keyword argument, such as `:x-height`. Each
  adaptor does the same for the front-end, with
  `latex-to-svg-frontend-check-version`, or, with a front-end before
  0.24.0, which has no such function, says that it must be 0.24.0 or
  newer.
- `latex-to-svg-frontend-version` and a version constant in each
  adaptor, such as `latex-to-svg-for-org-version`.
  `latex-to-svg-frontend-check-version` takes `:package`, `:version` and
  `:requires`, for another package that requires the front-end.

### Changed

- The front-end requires `latex-to-svg-backend` 0.16.1, which has
  `latex-to-svg-backend-version`, the version the front-end checks when it
  is loaded. 0.16.0 cancels a request (`latex-to-svg-backend-cancel`)
  and takes the `:tentative` keyword: the editing preview cancels the
  request before each new one, and a half-typed formula does not leave a
  failure record in the cache at every pause. The README and the docstrings use the backend's new
  names of the two preamble options,
  `latex-to-svg-backend-preamble-packages` and
  `latex-to-svg-backend-preamble-macros`.

### Fixed

- A color option that is not a color is reported when a graphical window
  first shows the buffer, if the mode turned on while no frame was
  graphical, as in a daemon. Before, it was ignored with no warning.
- An equation is fontified again before it is drawn when point leaves it
  after an edit, so the preview takes the color of its current faces
  (issue #10). Before, in `markdown-ts-mode`, changing `\[` to `$$` in
  an equation holding a line of `=`, and then `\]` to `$$`, left the
  opening line with `markdown-ts-setext-heading`, and the preview in the
  heading's color, until the buffer was fontified again.

## [0.23.0] - 2026-10-18

### Added

- `latex-to-svg-for-elfeed`, an adaptor for Elfeed's `elfeed-show-mode`,
  such as the titles and abstracts of the arXiv feeds. It draws the
  previews again each time Elfeed shows an entry, from
  `elfeed-show-update-hook`, excludes no region, and turns equation
  numbering off in the entry buffer. Not on MELPA yet.
- An equation that no engine could typeset shows a warning icon before its
  source, with the tooltip of the source: the engine, the error and the
  command that opens the log (issue #7). Before, it looked like an equation not typeset yet. The icon
  is hidden while point is in the equation, and shown again when point
  leaves it unchanged. `latex-to-svg-frontend-failure-mark` (default t)
  turns it off; `customize-icon` changes the icon
  (`latex-to-svg-frontend-failure`).
- `latex-to-svg-frontend-show-error-log` opens the log of the failed
  equation at point, or shows the error in the echo area when there is no
  log. The tooltip of a failed equation names it.

- `latex-to-svg-for-org-mode` warns when Org's own preview ran as the
  file opened, because `org-startup-with-latex-preview` is non-nil: set
  by the file's `#+startup: latexpreview`, or in the user's config. The
  warning says how to turn Org's preview off and links to the Org
  adaptor's Troubleshooting section, which now covers the config case
  and the slow opening too. Refs #9.
- `latex-to-svg-for-org-mode` warns when `org-latex-preview-mode`, which
  Org's next release brings, is on in the same buffer, each time one of
  the two turns on while the other is on. If it is on `org-mode-hook`,
  the warning says to remove it from the hook; otherwise, to turn it off
  with `M-x org-latex-preview-mode`. The adaptor does not turn Org's
  mode off. The Org adaptor's page documents it under Troubleshooting.
- `latex-to-svg-for-latex-mode` warns when `preview-auto-mode`, from the
  `preview-auto` package, is on in the same buffer, each time one of the
  two turns on while the other is on: `preview-auto-mode` calls
  preview-latex's functions directly, so the remap of its commands does
  not stop it. The warning links to the new Troubleshooting section of
  the LaTeX adaptor's page.

### Changed

- The front-end requires `latex-to-svg-backend` 0.15.1, whose warnings
  are shown once per buffer per cause and name the buffer.
- The tooltip of an equation that no engine could typeset no longer
  names its log file. `latex-to-svg-frontend-show-error-log` opens the
  log.
- A color option (`latex-to-svg-frontend-foreground-color`,
  `latex-to-svg-frontend-background-color`) whose value is not a color is
  reported when `latex-to-svg-frontend-mode` turns on and when an option
  of this package is set, in each buffer with the mode on, instead of
  once for the life of the Emacs process, when an equation was first
  drawn. Drawing an equation ignores such a value with no warning, as it
  ignored it before after the first warning.
- A function in `latex-to-svg-frontend-reveal` that signals an error
  is reported each time it fails, naming the buffer, instead of once for
  the life of the Emacs process. The warning suggests fixing the
  function, or setting the option to `always`, `writable` or nil, which
  need no function. The failure still counts as nil.

### Fixed

- A jump from `\eqref` / `\ref` to an equation in a folded Markdown
  section showed nothing: the section stayed folded.
  `latex-to-svg-for-markdown-mode` now shows the heading and entry that
  hold the equation, and the headings above them, as Org's default
  (`ancestors` in `org-fold-show-context-detail`) does.
  `latex-to-svg-for-latex-mode` does the same in a section that
  `outline-minor-mode` folded, also after a jump to a `\label` that no
  equation defines (a section's, a figure's), in the buffer or through
  xref.
- In `markdown-ts-mode`, the same equation was drawn in different colors
  depending on its delimiters: in the color of `shadow` between `\[` and
  `\]` (the grammar reads `\[` as an escaped bracket), in the color of
  `markdown-ts-latex` between `$$` and `$$`. A line holding only `=` or
  `-` inside an equation made the lines above it a setext heading, and
  the equation took the heading's color. `latex-to-svg-for-markdown-mode`
  now gives every equation the face of `$...$`, `markdown-ts-latex`, and
  removes the heading's face when the underline is inside an equation. A heading whose underline is outside every equation keeps
  its face. Refs #10.

## [0.22.2] - 2026-10-17

### Fixed

- A package that turns the mode off in a new clone, as
  markdown-ts-appear does, no longer empties the base buffer's table of
  pending requests. When the mode was turned on before that package,
  the package's function on `clone-indirect-buffer-hook` ran before
  ours, and turned the mode off while the clone still held the base
  buffer's table. The equations the base buffer was waiting for then
  showed their source. Our function now runs before every other
  function on `clone-indirect-buffer-hook`, so the clone has its own
  table by then.

## [0.22.1] - 2026-10-16

### Changed

- In Markdown buffers, a keystroke or a command that moves point costs
  about 0.5 ms less. The Markdown adaptor finds code blocks with a
  tree-sitter query, which it passed as a list, so Emacs compiled it again
  on every call. The query is now compiled once, at first use. Font-lock
  of one line with the mode on takes 185 µs instead of 683 µs, against
  111 µs without the mode.

### Fixed

- Previews in indirect buffers follow edits made in the other buffers
  that share the text. An indirect buffer shares its text with its base
  buffer: `C-x 4 c` (`clone-indirect-buffer`) makes one, and so does
  `C-c C-x b` (`org-tree-to-indirect-buffer`) in Org. Before, an
  equation edited in one of the two buffers kept its old picture in the
  other. Now, while point is in the edited equation, every other buffer
  with the mode on shows its source; when point leaves it, it is
  rendered in all of them. A paste or an undo reaches them too, from
  the debounced pass of the buffer where it happened.
- Turning the mode off in a clone no longer affects the base buffer. A clone
  started with the base buffer's own table of pending requests, timer
  and marker, so turning the mode off there dropped the pictures the
  base buffer was waiting for, which then showed their source, and
  cancelled its pending pass. A clone now starts with its own state and
  renders its own previews, from the cache.

## [0.22.0] - 2026-10-14

### Added

- `latex-to-svg-frontend-reveal` accepts a function, called after every
  command with point on math or a reference, with its kind (`inline`,
  `display`, `environment` or `reference`); non-nil means the source is
  shown. With `(lambda (_kind) (evil-insert-state-p))`, the source is
  shown only in Evil's insert state. When the value of the function changes with point on an
  equation, its preview opens or closes there, and an equation edited or
  typed new is rendered. A function that signals an error counts as nil
  and is reported once.
- `latex-to-svg-frontend-spans` and `latex-to-svg-frontend-span-at`:
  where the math and the references are in the buffer, as this package
  detects them, each with its kind (`inline`, `display`, `environment`
  or `reference`), for a package that decorates the same buffer and
  leaves them alone.

### Changed

- Fontifying a large region at once is faster with the mode on, as
  `font-lock-ensure` does on the whole buffer: 0.33 s instead of 3.9 s for
  a Markdown buffer of 118,000 characters with 1,500 equations. The time
  of the font-lock keyword that removes emphasis from math grew with the
  number of face runs times the number of equations in the region; it
  now grows with their sum.
- The Markdown adaptor, not the core, shows the markup that
  `markdown-ts-hide-markup` or `markdown-hide-markup` hides inside math.
  With both off, its font-lock keyword returns at once: font-lock of the
  same buffer in jit-lock's chunks takes 290 ms instead of 350 ms, against
  180 ms without the mode.
- Point right after the closing delimiter of an equation reveals its
  source, so `DEL` there deletes a character you can see. This is the
  position at which newly typed math was already not rendered yet. Where
  one equation ends and the next starts, point reveals the next.
- Requires `latex-to-svg-backend` 0.15.0, which calls the callback of
  every request with its outcome: nil when the picture is ready, or a
  plist that describes the failure.

### Fixed

- In `markdown-ts-mode` with `markdown-ts-hide-markup` on, the delimiters
  of math are visible: the `$` of `$...$` when point is on the equation,
  and the backslash of `\(` and `\[`, which showed as `(x^2)` with no
  preview. The Markdown adaptor removes the `invisible` property from
  math source while `markdown-ts-hide-markup` or `markdown-hide-markup`
  is on; `markdown-mode` hides the same backslashes.
- In LaTeX buffers, inline `$` pairs as TeX does: the first `$`
  after an opening one ends the span, whatever surrounds it. Before, the
  pandoc guards of Markdown applied there too, so `{$\lambda $}, x
  unit=\si{\meter}, ylabel={$v$}` was read as the equation `$}, x
  unit=\si{\meter}, ylabel={$`. The buffer-local variable
  `latex-to-svg-frontend-dollar-guards` (default t) controls this; the
  LaTeX adaptor sets it to nil.
- A preview whose compile finishes after its request was replaced is
  no longer installed: when the equation was edited and rendered again,
  its preview cleared, or the mode turned off. A preview that arrives
  while point is on its equation and the source is shown leaves the
  source shown. ([#5](https://github.com/alberti42/latex-to-svg/issues/5))
- An equation that fails to compile shows its source. Before, an
  equation edited so that it no longer compiled showed the picture it had
  before the edit once point entered and left it again. An equation
  compiled again after a change of the preamble, and failing, shows its
  source too, where it kept its old picture before. Its `help-echo`
  names the engine and gives the error message and the log. A numbered
  equation that failed keeps its numbers, so the equations below it keep
  theirs. ([#6](https://github.com/alberti42/latex-to-svg/issues/6))
- Math keeps the faces its markup gives it, and its preview is tinted
  with their colour: `markdown-ts-latex` in `markdown-ts-mode`,
  `org-latex-and-related` in Org with `org-highlight-latex-and-related`
  set, and AUCTeX's `font-latex-math-face` in LaTeX buffers. Before,
  `latex-to-svg-frontend-suppress-emphasis` removed every face whose run
  ended inside an equation, so the source and the preview took the
  default foreground. It now removes only the markup's emphasis faces:
  those of `org-emphasis-alist` in Org, the emphasis faces of
  `markdown-mode` and `markdown-ts-mode` in Markdown, none in LaTeX. The
  buffer-local variable `latex-to-svg-frontend-emphasis-faces` holds the
  list, which each adaptor sets.
  ([#8](https://github.com/alberti42/latex-to-svg/issues/8))
- Detecting math in a region that ends inside an equation signaled
  "Invalid search bound (wrong side of point)". Font-lock passes such a
  region when a chunk it fontifies ends inside a display equation, and so
  can the pass after an edit with no clean leave, such as a paste. The
  equation is now found whole.
- Emphasis inside a display equation is removed wherever font-lock
  starts the chunk it fontifies. When a chunk started inside the
  equation, its lower part kept the emphasis, so `E_32 = m c^2 +
  \sum_{k=0}` in Markdown showed in italic from `_32` on.

## [0.21.0] - 2026-10-11

### Added

- Equations in a table cell are drawn in the tables of
  [pretty-tables](https://github.com/alberti42/pretty-tables.el). Each
  image carries its width in pixels as `:width`, which pretty-tables
  reads, and an image shown in a row pretty-tables has drawn has that
  table drawn again.
- `latex-to-svg-frontend-foreground-ignored-faces`: faces whose
  foreground the color of an equation does not follow. The next face of
  the text at the opening delimiter that specifies a foreground is used,
  else `latex-to-svg-frontend-foreground-color`. In a LaTeX buffer,
  AUCTeX puts `font-latex-sedate-face` on `\(` and
  `font-lock-keyword-face` on `\begin`, so those equations had the color
  of these faces.

### Changed

- An equation is compiled only while some frame is graphical, whether or
  not a window shows its buffer: a buffer buried in a graphical session
  is compiled ahead. While every frame is a terminal frame, as in an
  Emacs daemon with only terminal clients, nothing is compiled. Up to
  `latex-to-svg-backend` 0.13.0 the backend compiled only while the
  selected frame was graphical, or always with
  `latex-to-svg-backend-render-on-non-graphic`; 0.14.0 makes that option
  obsolete, and this package has no replacement for it.
- Requires `latex-to-svg-backend` 0.14.0, which reads no faces and no
  frames. The front-end reads the colors on the frame that shows the
  buffer and passes them to the backend as `#rrggbb` strings: the tint of
  an equation in text with no foreground of its own, when
  `latex-to-svg-frontend-foreground-color` is nil, is the foreground of
  the `default` face on that frame, and a name in
  `latex-to-svg-frontend-foreground-color` or
  `latex-to-svg-frontend-background-color` is resolved there. A name the
  frame cannot resolve, or a value that is not a string, is reported with
  a warning and treated as nil.
- An equation's lowercase letters have the height of the text's around
  it: the front-end passes the x-height of the font at the equation's
  opening delimiter, the height of its lowercase `x` in pixels, as
  `:x-height`, where it passed the font's line height as `:font-height`.
  The x-height of two fonts of one size differs (at 18 pixels, 9.9 in
  JetBrains Mono, 8.37 in Calibri); matching it, as CSS's
  `font-size-adjust` does, sizes an equation to the text in either.
  Capitals and digits come out about 10% larger than the text's. Each
  image has its width in pixels, so the size is the same on every port;
  on macOS equations were drawn at 0.75 of the line height. An inline
  equation sits on the text's baseline. The backend compiles every
  equation once more after the update.
- The check for a theme or font change compares the colors of the
  `default` face on the frame that shows the buffer, where it compared
  those of the selected frame.
- The check for a theme or font change does nothing while no graphical
  window shows the buffer.

### Fixed

- An equation that has no preview because no graphical window showed its
  buffer, or because no frame was graphical, is drawn when a graphical
  window shows the buffer. Before, it stayed text until
  `latex-to-svg-frontend-refresh` or until the mode was turned off and on.

## [0.20.0] - 2026-10-10

### Added

- A third engine, `texres`: `latex-to-svg-frontend-engine` and the
  `% engine=texres` cookie send an equation to the backend with
  `:engine 'texres`, which compiles it with the `pdflatex` of
  [texres](https://github.com/leoliu0/texres) and converts the PDF with
  `pdftocairo`. Numbering works as with `latex`: a `\setcounter` prefix and
  the compile metadata. `C-u M-x latex-to-svg-frontend-refresh` deletes
  texres's `.fmt` file too. An equation texres rejects has a LaTeX error, so it
  gets no fallback. Requires `latex-to-svg-backend` 0.12.1.

### Changed

- `latex-to-svg-for-latex-mode` keeps a global `latex-to-svg-frontend-engine`
  of `texres`, since texres reads the preamble. It still replaces a global
  `ratex` with `latex`.
- A `% engine=` cookie naming an engine whose program is not found no longer
  warns from the front-end: the equation is sent to the backend like any
  other, and the backend warns, naming the engine and the program, for the
  cookie and for `latex-to-svg-frontend-engine` alike. Before, only a cookie
  warned, and an engine set by the option drew the backend's placeholder.
- Each equation is tinted and sized like the text at its opening delimiter:
  an equation in a Gnus Subject, an Org heading or a link has the color and
  the font height of that text (issue #3: the equations of a Subject were
  white and the Subject yellow). The color is read again at every redraw, so
  a theme change re-tints them. Equations in text with the default
  foreground and the default font look as before.
- `latex-to-svg-frontend-foreground-color` now colors the equations in text
  drawn in the default foreground; an equation in colored text keeps the
  color of the text. Before, it colored every equation.
- Inline math directly followed by a digit, such as `$x$2`, is no longer
  detected; this is the price of the digit rule above, which pandoc also
  applies. What still reads as math is shell variables such as `$HOME/$USER`
  (see `latex-to-svg-frontend-detect-dollar-inline`).

### Fixed

- In a Gnus article, `latex-to-svg-for-gnus-mode` removed Gnus's faces: the
  colours of the headers, the larger Subject, and the proportional font of an
  HTML body (issue #3). The mode added its font-lock keyword
  (`latex-to-svg-frontend-suppress-emphasis`) in every buffer, so font-lock
  fontified a buffer it had nothing to do in, and fontifying first removes
  every `face` property. The keyword is now added only when the major mode
  sets `font-lock-defaults`, as Org, Markdown and LaTeX modes do; it undoes
  their font-lock, and a buffer without one needs nothing undone.
- `latex-to-svg-for-org-mode` read Org syntax with `$` in it as math (issue
  #4): a table formula such as `#+TBLFM: $2=$1*2`, which refers to columns as
  `$1`, `$2`, …, and a fixed-width line (`: …`, a literal example) such as
  `: echo ${VARNAME}`, whose `$` could pair with a `$` later in the paragraph
  and hide a real equation. Both are now excluded, like comment lines.
- A `$` that cannot close an inline `$…$` (it follows whitespace) no longer
  lets the span run on to a later `$`: in `it costs $5 and $x$`, the scanner
  read `$5 and $x$` as one equation and lost `$x$`. As in TeX, the first `$`
  after an opening one ends the span, and when it cannot close it there is no
  span. This holds in every adaptor.
- A no-space price range such as `$100-$200` is no longer read as the equation
  `100-`: a closing `$` must not be followed by a digit, as in pandoc.

## [0.19.1] - 2026-10-08

### Added

- `latex-to-svg-for-gnus`, an adaptor for Gnus's `gnus-article-mode` (see
  `docs/latex-to-svg-for-gnus.md`), for articles such as the abstracts of the
  arXiv feeds on gwene.org (issue #3). It draws the previews again for each
  article Gnus shows, turns equation numbering off in the article buffer, and
  removes Gnus's emphasis (`gnus-emphasis-alist`) from inside math.

### Fixed

- Inline math whose source spans lines, as in a paragraph filled with hard
  line breaks, no longer joins the line holding the equation and the line
  after it. The line breaks where a fill would break it, at the first spaces
  after the equation, so punctuation attached to the equation stays on its
  line.
- Display math with text before or after it on the lines of its delimiters,
  such as `we have $$a$$, where`, starts and ends a line, as in the typeset
  document: the spaces before it and the first spaces after it are shown as
  line breaks. With `latex-to-svg-frontend-center-display-math` on, the image
  is centered on its own line.

## [0.19.0] - 2026-10-08

### Added

- `latex-to-svg-frontend-reveal` sets when the preview point is on is shown
  as its LaTeX source: `always`, `writable` (in a buffer that is not
  read-only) or `nil` (never). During an Isearch it is shown whatever the
  value.

### Changed

- In a read-only buffer the preview point is on stays drawn, except during
  an Isearch. Set `latex-to-svg-frontend-reveal` to `always` for the former
  behavior.

## [0.18.1] - 2026-09-28

### Fixed

- The Org and Markdown adaptors required `latex-to-svg-frontend` 0.11.0, the
  oldest frontend their code runs on, so upgrading one of them left the
  frontend where it was, without the fixes of the releases since; a user who
  installed only an adaptor does not upgrade the frontend by hand. Each
  adaptor now requires the frontend of its own release, here 0.18.1, so
  upgrading an adaptor upgrades the frontend too, and the frontend the backend
  it was tested with.

## [0.18.0] - 2026-09-28

### Added

- `latex-to-svg-for-latex`, an adaptor for AUCTeX's `LaTeX-mode` and the
  built-in `latex-mode` (see `docs/latex-to-svg-for-latex.md`, and the demo
  `docs/example.tex`). It skips comments, `comment` environments, `\iffalse` …
  `\fi`, the verbatim environments and macros, and the preamble. `\ref` and
  `\eqref` show the numbers read from the document's `.aux` file, found
  through AUCTeX or a template (`latex-to-svg-for-latex-aux-file`), and a jump
  to a label in another file goes through `xref`. It sets the engine to
  `latex` in its buffers and remaps AUCTeX's preview-latex commands to a
  message.
- `latex-to-svg-frontend-padding-inline` and
  `latex-to-svg-frontend-padding-display` set the padding of inline and
  display previews separately, with the values `latex-to-svg-frontend-padding`
  takes. They are safe as file-local values and update the previews when set.
- Setting one of the backend's options in the cache key that a project sets
  in `.dir-locals.el` (`latex-to-svg-backend-preamble`,
  `latex-to-svg-backend-appended-preamble`,
  `latex-to-svg-backend-preamble-not-precompiled`,
  `latex-to-svg-backend-line-width`, `latex-to-svg-backend-ratex-macros`)
  updates the previews on its own, like this package's own options: a
  buffer-local value (from `.dir-locals.el`) updates that buffer, a default
  value every buffer that uses it.
- `latex-to-svg-frontend-labels-function`, a protocol variable for
  adaptors: a function returning a table from label to its printed number,
  a string such as `2.1`. When set, `\ref` / `\eqref` resolve against it
  instead of the equation labels in the buffer, and are drawn with
  numbering off too. The LaTeX adaptor fills it from the `.aux` file.
- `latex-to-svg-frontend-find-label-function`, a protocol variable for
  adaptors: a function the jump from a reference calls, with point on the
  reference, when no equation in the buffer defines the label. The LaTeX
  adaptor asks `xref` for labels in other files.

### Changed

- Requires `latex-to-svg-backend` 0.11.1, for
  `latex-to-svg-backend-preamble-not-precompiled`, for the preambles read in
  the requesting buffer, and for `latex-to-svg-backend-invalidate-format`.
- A change of an option's default value no longer updates a buffer that has
  its own local value of that option, since the change does not reach it.
- `C-u M-x latex-to-svg-frontend-refresh` also deletes the buffer's `.fmt`
  file (`latex-to-svg-backend-invalidate-format`) when an equation is
  typeset with LaTeX, as the engine or the fallback. The `.fmt` file holds
  the files the preamble loads as they were when it was dumped, so before,
  an edit to one, such as the `macros.tex` of an `\input{macros.tex}`, did
  not reach the recompiled equations. The next compile dumps it again.
- The README describes each adaptor briefly, under "One adaptor per
  markup", and leaves the details to a page per adaptor in `docs/`. It has a
  new section, "Projects with their own macros", on setting a project's
  preamble in `.dir-locals.el` and trusting its directory.
- The README and the adaptor pages install the Org and Markdown adaptors
  from MELPA, which pulls in the frontend and the backend, instead of from
  git. Under "One adaptor per markup", each adaptor has its own heading, with
  its MELPA badges below it. The LaTeX adaptor, not on MELPA yet, keeps a git
  recipe.

### Deprecated

- `latex-to-svg-frontend-padding`, which padded both kinds alike. It still
  works: a kind whose own option is nil (the default) takes its value.
- `latex-to-svg-frontend-inline-rescale` and
  `latex-to-svg-frontend-display-rescale` are renamed
  `latex-to-svg-frontend-rescale-inline` and
  `latex-to-svg-frontend-rescale-display`, so the four per-kind options share
  their roots and complete together. The old names keep working as obsolete
  aliases.

### Fixed

- `latex-to-svg-frontend-refresh` compiles a preview whose picture is not in
  the cache, as after a change of `latex-to-svg-backend-preamble`. Before, it
  asked the backend for the picture without a callback, so the backend
  started no compile and the preview kept its old picture. The redraw after a
  theme or zoom change goes through the same code.
- In a buffer visiting a file, the first render runs after the file's local
  variables are applied. Emacs runs a major mode's hooks, where the mode is
  usually turned on, before it applies them, so the first render ignored an
  option set in `.dir-locals.el`, such as
  `latex-to-svg-backend-preamble-not-precompiled`: every equation using a
  project macro was compiled without it and failed. The render now runs from
  a timer. Other buffers render at once, as before.
- `normal-mode` and `revert-buffer` no longer leave old previews on screen.
  Changing the major mode kept the overlays, so a preview compiled with the
  old options stayed until its new picture was compiled, and stayed for good
  when the equation no longer compiled. The mode now turns itself off before
  the major mode changes, which clears its previews.

## [0.17.0] - 2026-09-27

### Added

- `latex-to-svg-frontend-engine` chooses the program that typesets the
  previews: `latex` (the default: `latex` + `dvisvgm`) or `ratex` (RaTeX's
  `render-svg`). It is passed to the backend as `:engine` with every call,
  and is safe as a file- or directory-local variable. With `ratex`, a
  numbered environment gets its numbers as a `\tag{N}` on each numbered row
  instead of a `\setcounter` prefix, and every `\label` is removed from what
  RaTeX receives; `\eqref` / `\ref` resolve as before. Environments RaTeX
  does not have (`multline`, `eqnarray`, `flalign`, …) are typeset with LaTeX
  by the fallback (below), or, with it off, fail with the backend's warning.
  With `latex`, the value sent to the backend is unchanged, so no cached
  equation is recompiled.
- A cookie at the top of a display equation chooses its engine:
  `% engine=latex` (alias `tex`), `% engine=ratex`, or
  `% engine=skip` (alias `none`) to leave the source as text. It stands on
  the opener line or alone on the line after it, optionally written
  `% latex-to-svg: engine=…`. A skipped equation still takes its numbers.
  An unknown key or value, or an engine whose programs are not found, warns
  and leaves the source visible. The cookie is removed from what the backend
  receives, so a cookie that selects the engine an equation would get anyway
  shares the cached picture of the same equation written without it.
- `latex-to-svg-frontend-fallback` (default `t`): an equation whose engine
  is not `latex` and rejects it, such as one using siunitx's `\SI` under
  RaTeX, is typeset with LaTeX instead, passed to the backend as
  `:fallback`. A fallback equation is typeset in LaTeX's style next to
  RaTeX's, and compiles in about 300 ms instead of about 6 ms. Without
  `latex` and `dvisvgm`, the backend warns; install them or set the option to
  nil.
- `latex-to-svg-frontend-quiet` (default nil): when non-nil, a failed compile
  gives no warning, passed to the backend as `:quiet`. Safe as a file- or
  directory-local variable. Configuration problems still warn.
- Hovering over a preview names the engine that typeset it before the
  source: "Typeset with RaTeX: …", or "Typeset with LaTeX (RaTeX could not
  parse it): …" for a fallback picture, from
  `latex-to-svg-backend-engine-used`.
- Recompiling (`C-u M-x latex-to-svg-frontend-refresh`) also deletes the
  fallback engine's picture and the record of the engine's failure, so the
  engine is tried again.
- Setting an option that affects the previews (`-engine`, `-fallback`,
  `-foreground-color`, `-background-color`, `-padding`, `-inline-rescale`,
  `-display-rescale`, `-center-display-math`) with `setq`, `setq-local` or
  Customize updates the previews on its own, through a variable watcher: a
  global value updates every buffer with previews, a buffer-local one that
  buffer. A let-binding updates nothing. Before, each needed
  `latex-to-svg-frontend-refresh`.
- Org: while `latex-to-svg-for-org-mode` is on, `org-latex-preview` is
  remapped to `latex-to-svg-for-org-preview-disabled`, which says that Org's
  preview is off and that turning the mode off brings it back. Org's preview
  would draw its own images over this package's. The remap lives in the Org
  adaptor's own keymap, so it applies whatever key runs `org-latex-preview`,
  only in Org buffers with the mode on.
- Tests: a drift guard over the release metadata — the three `Version:` headers
  must agree, and the newest dated `CHANGELOG.md` section must not claim a
  version the sources have not reached.

### Changed

- Requires `latex-to-svg-backend` 0.10.0, for `:engine`, `:fallback` and
  `:quiet`.
- `latex-to-svg-frontend-refresh` brings the buffer's previews up to date:
  it renders equations with no preview (except the one containing point),
  renders again those whose engine or fallback no longer matches the options,
  redraws the rest from cache, and reconciles numbers. It used to only redraw
  existing previews, so an engine change needed a re-render. With a prefix
  argument it recompiles the buffer's previews, bypassing the cache. It
  touches only the current buffer: `C-u` used to apply it to every buffer,
  which the variable watcher now does for a global option change. The
  automatic refresh after a theme, zoom or display change still only redraws.
- In the documentation, "engine" now names the program that typesets an
  equation, LaTeX or RaTeX, and "backend" names `latex-to-svg-backend`. The
  released versions' entries below use "engine" for the backend, as they were
  written.

### Deprecated

- `latex-to-svg-frontend-regenerate`: run `latex-to-svg-frontend-refresh`
  with a prefix argument.
- The command `latex-to-svg-frontend` is an obsolete alias for
  `latex-to-svg-frontend-refresh`. The mode renders math as it arrives, and
  options update the previews when set, so its toggle at point and its prefix
  arguments had no remaining use.

### Removed

- The `C-c C-x C-l` binding in `latex-to-svg-frontend-mode-map`, which is now
  empty. It shadowed `markdown-toggle-url-hiding` in `markdown-mode`.

### Fixed

- Math pasted, yanked or restored by an undo is rendered a moment later, by
  the debounced pass over the changed range (`latex-to-svg-frontend-reconcile-idle`).
  Rendering was triggered only by point leaving an equation, so such math
  stayed as text until point went through each equation. The equation
  containing point is skipped, as before, so half-typed math is not compiled.
- Hovering over a preview shows its LaTeX source as written. Emacs passes a
  `help-echo` string through `substitute-command-keys`, which read `\[` as a
  key reference and `\{` as a keymap, so `\[E=mc^2\]` showed as
  "M-x, E=mc^2, \"; the source is now quoted with `\=`. The same quoting
  fixes four docstrings that `C-h` showed with "M-x" in place of `\[…\]`.
- The docstrings of `latex-to-svg-frontend-inline-rescale` and
  `-display-rescale` named `latex-to-svg-font-scale`, which does not exist;
  the backend's option is `latex-to-svg-backend-font-scale`. Three docstrings
  showed "=--" where "--" was meant.

## [0.16.2] - 2026-09-18

### Added

- GitHub Actions: a `CI` workflow (byte-compilation with warnings as errors,
  checkdoc and the ERT suite, on Emacs 29.1 through master) and a `melpazoid`
  workflow that runs MELPA's own checks once per recipe. The README carries
  their badges, next to MELPA and MELPA Stable for `latex-to-svg-frontend`.

### Fixed

- Markdown: excluding code blocks no longer signals on Emacs 29 when the
  `markdown` tree-sitter grammar is installed. `treesit-parser-list` only
  accepts a language argument from Emacs 30 on; the buffer's parsers are now
  filtered by `treesit-parser-language` instead. The resulting
  `wrong-number-of-arguments` was not a `treesit-error`, so the handler that
  falls back to the regexp scanner did not catch it. Present since 0.7.2.
- Two core docstrings reworded so `checkdoc` passes; no behavior changed.

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

[Unreleased]: https://github.com/alberti42/latex-to-svg/compare/v0.25.1...HEAD
[0.25.1]: https://github.com/alberti42/latex-to-svg/compare/v0.25.0...v0.25.1
[0.25.0]: https://github.com/alberti42/latex-to-svg/compare/v0.24.2...v0.25.0
[0.24.2]: https://github.com/alberti42/latex-to-svg/compare/v0.24.1...v0.24.2
[0.24.1]: https://github.com/alberti42/latex-to-svg/compare/v0.24.0...v0.24.1
[0.24.0]: https://github.com/alberti42/latex-to-svg/compare/v0.23.0...v0.24.0
[0.23.0]: https://github.com/alberti42/latex-to-svg/compare/v0.22.2...v0.23.0
[0.22.2]: https://github.com/alberti42/latex-to-svg/compare/v0.22.1...v0.22.2
[0.22.1]: https://github.com/alberti42/latex-to-svg/compare/v0.22.0...v0.22.1
[0.22.0]: https://github.com/alberti42/latex-to-svg/compare/v0.21.0...v0.22.0
[0.21.0]: https://github.com/alberti42/latex-to-svg/compare/v0.20.0...v0.21.0
[0.20.0]: https://github.com/alberti42/latex-to-svg/compare/v0.19.1...v0.20.0
[0.19.1]: https://github.com/alberti42/latex-to-svg/compare/v0.19.0...v0.19.1
[0.19.0]: https://github.com/alberti42/latex-to-svg/compare/v0.18.1...v0.19.0
[0.18.1]: https://github.com/alberti42/latex-to-svg/compare/v0.18.0...v0.18.1
[0.18.0]: https://github.com/alberti42/latex-to-svg/compare/v0.17.0...v0.18.0
[0.17.0]: https://github.com/alberti42/latex-to-svg/compare/v0.16.2...v0.17.0
[0.16.2]: https://github.com/alberti42/latex-to-svg/compare/v0.16.1...v0.16.2
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
