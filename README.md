# m68k-asm-mode

An Emacs major mode for Motorola 680x0 assembly in vasm's Motorola syntax, the Devpac-style syntax most Amiga sources use. It highlights and indents code, can show clock-cycle costs in the left margin, shows the name of the operation on the current line in the echo area, and can open its full documentation page in a side panel. There is no LSP.

Some inspiration from [themkat/emacs-m68k](https://github.com/themkat/emacs-m68k).

## Install

You need Emacs 29.1 or later. I use it on Aquamacs 4 (Emacs 29.4).

The documentation panel reads its pages from a git submodule, so clone with `--recursive`, or fetch it afterwards:

```sh
git submodule update --init
```

```elisp
(add-to-list 'load-path "~/Projects/troelskn-m68k-asm-mode")
(autoload 'm68k-asm-mode "m68k-asm-mode" "Major mode for Motorola 68k assembly." t)
(add-to-list 'auto-mode-alist '("\\.\\(s\\|asm\\|i\\)\\'" . m68k-asm-mode))
```

The `.i` pattern also catches preprocessed C and SWIG interface files. Drop it if you have those around.

The cycle counts run [68kcounter](https://www.npmjs.com/package/68kcounter), which needs Node:

```sh
npm install -g 68kcounter
```

Everything else works without it.

## Keys

| Key | Command |
|---|---|
| `C-c C-c` | Toggle cycle counts in the margin |
| `C-c C-t` | Pick the target CPU for cycle counts (68000, 68020, 68030) |
| `C-c C-d` | Toggle operation names in the echo area |
| `C-c C-p` | Open or close the documentation panel |

## Highlighting

A name in column 0 is a label, a constant or a macro, and each gets its own colour where it is defined and wherever it is used. Constants are names defined with `equ`, `=`, `set`, `equr`, `reg`, `rs`, `so`, `fo` and their relatives. Macros are names defined with `macro`. Every other name in column 0 is a label. Anything in the instruction column that isn't an instruction or directive is taken to be a macro call.

Only the current buffer is scanned. A label or constant defined in an included file stays plain where you use it.

Instructions cover the 68000 to 68060, the MMU and cache instructions, the FPU and every condition-code variant. The directive list is exactly the 145 names vasm 2.0f accepts (see below).

The colours are set for a dark theme (Twilight). Change them with `M-x customize-face` on `m68k-asm-label-face`, `m68k-asm-constant-face` or `m68k-asm-macro-face`.

## Indentation

The rules follow vasm, where anything starting in column 0 is a label.

- `label:` goes to column 0.
- A line already in column 0 stays there, unless it starts with an instruction or directive. Then it is code that lost its indentation and moves to the code column.
- Everything else goes to `m68k-asm-indent-column` (8).
- Lines holding only a comment are left alone.

Typing `:` re-indents the line, so a label jumps to column 0. TAB indents only when point is in the leading whitespace. Elsewhere it inserts a tab, for lining up operands and comments.

The mode sets 8-column hard tabs in its buffers, the vasm convention. Override `tab-width` and `indent-tabs-mode` in `m68k-asm-mode-hook` if you want something else.

## Cycle counts

`C-c C-c` sends the buffer to 68kcounter in the background and writes each instruction's cost in the left margin. It recounts half a second after you stop typing. An instruction with several outcomes shows all of them, so `bne` shows taken/not taken and `dbf` shows taken/not taken/expired.

The target CPU is global. `C-c C-t` changes it for every buffer showing counts. The target you pick wins over `machine` and `mc680x0` directives in the source, which 68kcounter would otherwise follow. Set the default in your init file:

```elisp
(setq m68k-asm-cycles-target "68030")
```

On the 68020 and 68030 the numbers assume the instruction is in the cache, the same convention as Motorola's best-case tables. Set `m68k-asm-cycles-cache` to nil for 68kcounter's no-cache figures.

Treat the numbers as per-instruction costs in isolation. They ignore pipeline overlap on the 020/030, chip RAM wait states and the data cache. Lines 68kcounter can't time stay blank. That covers FPU and MMU instructions, macro calls, and operands built from constants defined in another file.

A full count of a 13,700-line file takes about 2.4 seconds, so numbers can sit on the wrong lines for that long after an edit.

## Operation names

With `C-c C-d` on, the echo area describes the operation on the current line:

```
moveq     Move Quick: load a sign-extended 8-bit immediate (-128..127) into Dn
bne.s     Branch if Not Equal, short, 8-bit displacement: branch if Z = 0
fmove.x   FP Move, extended precision, 96 bits: copy floating-point data, converting format
BLT_WAIT  macro, defined on line 1
```

The size suffix is spelled out according to the instruction. On a branch it is the displacement size, on an FPU instruction the number format, and elsewhere the data size.

The directive descriptions come from the vasm manual. The instruction descriptions are my own summaries of the Motorola mnemonics, written as a learning aid. Check the Programmer's Reference Manual before relying on one for flag behaviour.

`m68k-asm-describe-operations` toggles whether it starts on (it does by default).

## Documentation panel

`C-c C-p` opens a panel on the right of the frame with the full documentation for the operation on the current line. The page has syntax, operation, condition codes, addressing modes, processors and a description. `C-c C-p` again, or `q` in the panel, closes it.

The pages come from [m68k-tools](https://github.com/grahambates/m68k-tools) by Graham Bates (MIT), which is a submodule here. The instruction pages are adapted from Motorola's M68000 Family Programmer's Reference Manual (copyright Motorola Inc./NXP). `git submodule update --remote` pulls upstream fixes.

They cover the 68000 thoroughly. Many 020+ pages have only a title and the processor list, and some names have no page at all, mostly the rarer FPU condition variants and the directives vasm has but m68k-tools doesn't document. The panel always starts with this mode's own one-line description, so there is something to read either way. Aliases such as `dbra`, `bhs` and `global` open the page of the name they stand for (`dbf`, `bcc`, `public`). Of the 517 names the mode knows, 402 have a page.

## The directive list

The manual and the assembler disagree, so the list in `m68k-asm-mode.el` comes from the assembler. I gathered every candidate name from the vasm manual (chapter 4.5 and the M68k backend's directives), the directive table in the `vasmm68k_mot` binary and the earlier list. Then I assembled each one with `vasmm68k_mot` 2.0f and kept the ones it accepted.

Seventeen accepted directives aren't in the manual. `endc`, `global`, `import`, `export`, `ifmi`, `ifpl` and `auto` are among them. Their descriptions come from vasm's directive table in `syntax/mot/syntax.c`. `irp` and `irpc` are rejected, even though other assemblers have them.

Redo this when you move to a new vasm version.

## Settings

| Variable | Default | Meaning |
|---|---|---|
| `m68k-asm-indent-column` | 8 | Column for instructions and directives |
| `m68k-asm-describe-operations` | t | Start with operation names on |
| `m68k-asm-cycles-target` | "68000" | CPU for cycle counts |
| `m68k-asm-cycles-cache` | t | 020/030: assume instruction-cache hits |
| `m68k-asm-cycles-program` | "68kcounter" | Path to 68kcounter, if it isn't on `exec-path` |
| `m68k-asm-cycles-delay` | 0.5 | Seconds idle before recounting |
| `m68k-asm-panel-width` | 0.33 | Width of the documentation panel, as a fraction of the frame |
| `m68k-asm-panel-docs-directory` | the submodule | Where `instructions.json` and `directives.json` are |

## Files

- `m68k-asm-mode.el` is the major mode, with highlighting, indentation and keys.
- `m68k-asm-cycles.el` is the cycle-count minor mode.
- `m68k-asm-doc.el` holds the operation names and the eldoc backend.
- `m68k-asm-panel.el` is the documentation panel.
- `m68k-tools/` is the submodule the panel reads its pages from.
