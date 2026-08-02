# latex-to-svg — Markdown demo

Open this file and turn the previews on with `M-x
latex-to-svg-for-markdown-mode` (or add `(add-hook 'markdown-ts-mode-hook
#'latex-to-svg-for-markdown-mode)` to your init). It needs the
[latex-to-svg-backend](https://github.com/alberti42/latex-to-svg-backend) engine
on your `load-path`, plus `latex` and `dvisvgm`.

While the mode is on, `C-c C-x C-l` (`latex-to-svg-frontend`) toggles the
fragment at point, renders the region, or — failing both — the whole buffer.
`C-u C-c C-x C-l` re-renders from cache; `C-u C-u C-c C-x C-l` regenerates
(recompiles). `M-x latex-to-svg-frontend-refresh` re-tints / re-scales for the
current theme and font size straight from cache (no LaTeX).

Three things to try as you read:

- **Move point into any preview** — it reveals the LaTeX source for editing;
  move out and it re-shows the image (or re-renders if you changed the text).
- **Click a reference** like the `(1)` below (`mouse-1` or `RET`) — it jumps to
  the equation that defines the label.
- **Edit a numbered equation** (e.g. delete one, or turn `equation` into
  `equation*`) — every number below, and every reference, updates a moment
  later on its own.

## Inline math

The mass–energy relation is $E = mc^2$, and Euler's identity $e^{i\pi} + 1 = 0$
is often called the most beautiful equation in mathematics. A quadratic
$ax^2 + bx + c = 0$ has roots \( x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a} \).

Inline previews scale with the surrounding font, so a text-zoom (`C-x C-+`)
rescales them from cache with no recompile.

Math inside code is left alone — `$not math$` in an inline span, and:

```
also $not math$ in a fenced block
```

## Unnumbered display math

A centered display equation with `\[ … \]` consumes no equation number:

\[ \int_{-\infty}^{\infty} e^{-x^2}\, dx = \sqrt{\pi} \]

The `$$ … $$` form works too:

$$ \sum_{n=1}^{\infty} \frac{1}{n^2} = \frac{\pi^2}{6} $$

## Automatic equation numbering

Numbering is on by default (`latex-to-svg-frontend-number-equations`). The
number is computed from the equations that precede each block, so these come out
as `(1)`, `(2)`, … in document order:

\begin{equation}
\label{eq:newton}
\mathbf{F} = m\mathbf{a}
\end{equation}

Maxwell's equations number *per row* — each line gets its own number:

\begin{align}
\label{eq:gauss-e}
\nabla \cdot \mathbf{E} &= \frac{\rho}{\varepsilon_0} \\
\nabla \cdot \mathbf{B} &= 0 \\
\nabla \times \mathbf{E} &= -\frac{\partial \mathbf{B}}{\partial t} \\
\nabla \times \mathbf{B} &= \mu_0 \mathbf{J} + \mu_0 \varepsilon_0 \frac{\partial \mathbf{E}}{\partial t}
\end{align}

\begin{equation}
\label{eq:schrodinger}
i\hbar \frac{\partial}{\partial t}\,\Psi(\mathbf{r}, t) = \hat{H}\,\Psi(\mathbf{r}, t)
\end{equation}

## Cross-references

Newton's second law is equation \eqref{eq:newton}; Gauss's law for $\mathbf{E}$
is \eqref{eq:gauss-e}; the Schrödinger equation is \eqref{eq:schrodinger}. A
bare `\ref` gives just the number: see \ref{eq:newton}. References work wrapped
in math too, e.g. $\eqref{eq:schrodinger}$.

Click any of those numbers (or press `RET` on one) to jump to the equation it
names. Then try turning `\begin{equation}` at `eq:newton` into `equation*` and
watch the later numbers — and these references — renumber on their own.
