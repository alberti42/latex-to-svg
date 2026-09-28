# Typst adaptor — ideas not built

A design for previewing the math of Typst documents, worked out and set aside
so that the work is not repeated. It is not planned.

Recorded 2026-09-28.

## Which case

Typst does not read LaTeX: it writes `sqrt(pi)/2` and
`integral_0^oo e^(-x^2) dif x`, not `\frac{\sqrt\pi}{2}`. So a Typst engine
cannot typeset the math of Org, Markdown or LaTeX buffers.

- **Typst documents** (`.typ` files, `typst-ts-mode`): the case this note
  covers. It needs a new engine in the backend and a new adaptor.
- **LaTeX math typeset by Typst**, through a converter such as the Typst
  package `mitex`: rejected. It adds nothing over RaTeX, which already
  typesets LaTeX math without a TeX installation.

The stack is named `latex-to-svg`; a Typst adaptor would not involve LaTeX.

## Allowed engines per adaptor

A new buffer-local protocol variable, such as `latex-to-svg-frontend-engines`:
the list of engines allowed in the buffer, set by each adaptor.

| Adaptor | Allowed engines | Default engine |
|---|---|---|
| Org, Markdown | `latex`, `ratex` | the option's value |
| LaTeX | `latex`, `ratex` | `latex`, set buffer-locally (as today) |
| Typst | `typst` | `typst`, set buffer-locally |

What the list changes in the core:

- **`--engine-for`:** an engine outside the list returns a warning string,
  for example "Engine `ratex' is not allowed in this buffer". The equation
  stays as text through `--set-unrendered-overlay`, as it does today when an
  engine's programs are not found. This covers a `.dir-locals.el` that sets
  `latex-to-svg-frontend-engine` to `ratex` for a project that also has
  `.typ` files.
- **`--fallback-for`:** falls back to `latex` only when `latex` is in the
  list. In a Typst buffer there is no fallback: an equation Typst rejects
  stays as text.
- **`latex-to-svg-frontend-engine`'s `:type` and `:safe`** gain `typst`. The
  list, not the option, keeps `typst` out of Org and Markdown buffers.
- **nil** for the list means `latex` and `ratex`, so a buffer whose adaptor
  sets nothing works as it does today.

## The backend engine

A `typst` engine next to `latex` and `ratex`, in its own file, as
`latex-to-svg-backend-ratex.el` (332 lines) is for RaTeX.

Checked with Typst 0.15.1 (Homebrew):

- With `#set page(width: auto, height: auto, margin: 0pt)` it writes an SVG
  cropped to the equation.
- It reads the source from stdin: `typst compile - out.svg`.
- One equation: 0.28 s warm, 1.3 s on the first run.
- Glyphs are coloured with `fill="#…"`. Whether the backend's
  `currentColor` tinting works on it as on LaTeX's output: not checked.
- The inline baseline: not checked.

## The adaptor

The core's scanner assumes that the math delimiters are identical across
markups. In Typst they are not:

- `$x$` is inline, and `$ x $`, with spaces inside, is display;
- there is no `\[…\]` and no `\begin{…}`;
- a label is `<eq:x>` after the closing `$`, and a reference is `@eq:x`;
- numbering is set with `#set math.equation(numbering: "(1)")`;
- comments are `//` and `/* … */`, so the `% engine=` cookie does not apply.
  With one allowed engine, the adaptor needs no cookie.

The adaptor needs its own `detect-function` (the core's escape hatch), its own
exclusions (raw blocks and comments), and its own numbering and references.

## Numbering

`--backend-value` builds the string per engine. For `typst` the prefix works
as the LaTeX path's `\setcounter{equation}{K}`, and Typst prints the number
itself:

```typst
#set math.equation(numbering: "(1)")
#counter(math.equation).update(K)
$ … $
```

Checked: with `update(4)`, Typst prints (5).

### Which equations are numbered

Checked with Typst 0.15.1 on this document:

```typst
#set math.equation(numbering: "(1)")
$ a = b $ <eq:one>                                       → (1)
#math.equation(block: true, numbering: none)[$ c = d $]  → no number
$ e = f \
  g = h $                                                → (2), one number for both lines
#[#set math.equation(numbering: none)
$ i = j $]                                               → no number
$ k = l $ <eq:last>                                      → (3)
```

- Each numbered display equation gets one number, whatever its number of
  lines. Typst has no `align` rows, `\nonumber` or `\tag`, which are why the
  LaTeX path needs the `.eld` ground truth.
- An unnumbered equation does not advance the counter.
- Whether an equation is numbered depends on the `set` rules in force at
  that point: a document-wide rule, a scoped `#[#set … ]` block, or an
  explicit `numbering: none`. Reading that from the source means
  understanding Typst's scoping.

So the adaptor can count by itself, as for RaTeX, once it knows which
equations are numbered.

### The ground truth: `typst eval`

`typst eval` compiles the document in memory, evaluates an expression and
prints the result as JSON. It writes no file and changes nothing:

```sh
typst eval 'query(math.equation.where(block: true))
  .map(it => (it.numbering, counter(math.equation).at(it.location()).first()))' --in d.typ
```

gives, for every display equation in document order, its numbering and its
counter:

```
[["(1)",1],[null,1],["(1)",2],[null,2],["(1)",3]]
```

(`typst query` does the same but is deprecated in 0.15.1.)

This is the counterpart of the `.aux` file for LaTeX, with one difference:
the information cannot come from the user's own compile. A Typst document
cannot write files, and `typst compile` writes only its output (PDF, PNG,
SVG, HTML) and, with `--deps`, the list of files it read. So the adaptor runs
the query itself, and the user installs nothing and changes nothing.

It costs about what the user's compile costs, because it is the same compile
without writing the PDF. On a generated document with 1,000 sections and
1,000 numbered equations:

| Run | Time |
|---|---|
| `typst eval` with the query, counter of all 1,000 equations | 0.43 s |
| `typst compile` to PDF | 0.45 s |

**When to run it:** once when the adaptor turns on, before the first
previews, and again after each save, as a background process, as the
backend's compiles are. Between runs, the adaptor counts by itself.

**Open points:**

- `--in d.typ` reads the file on disk: the query sees the last save, not
  unsaved edits. Whether `--in` can read the buffer's text from stdin: not
  checked.
- The query lists every display equation Typst sees, including those from
  `#include`d files or generated by code; the buffer scan sees only the
  `$ … $` in this file. Matching the two by order fails when they differ.
- In a document split with `#include`, the query runs on the main file,
  which the adaptor has to find, as AUCTeX's `TeX-master` does for LaTeX.
- The numbering format is not always `"(1)"`: a document can number per
  heading or with a numbering function. The prefix has to use the document's
  own format, which the query can also return.
