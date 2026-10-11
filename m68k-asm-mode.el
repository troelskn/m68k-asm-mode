;;; m68k-asm-mode.el --- Motorola 680x0 assembly: highlighting and indentation only  -*- lexical-binding: t -*-

;;; Commentary:
;; A small major mode for 680x0 assembly in the vasm (Motorola syntax) / Devpac
;; style: syntax highlighting and indentation, nothing else -- no LSP, no
;; tree-sitter.  Replaces emacs-m68k's m68k-mode, which is asm-mode plus lsp-mode.
;; Clock-cycle costs in the margin are a separate minor mode, in m68k-asm-cycles.el:
;; C-c C-c toggles it, C-c C-t picks the target CPU.  Plain-language names of
;; operations in the echo area are in m68k-asm-doc.el: C-c C-d toggles them.
;;
;; Indentation follows the assembler's own rule that whatever starts in column 0
;; is a label:
;;   - a line starting with `label:' goes to column 0;
;;   - a line already in column 0 stays there, unless it starts with a known
;;     instruction or directive (then it is code that lost its indentation);
;;   - everything else goes to `m68k-asm-indent-column';
;;   - comment-only lines are left where they are.
;; TAB indents only when point is in the indentation; elsewhere on the line it
;; inserts a tab, for lining up operands and comments (as in asm-mode).

;;; Code:

(defgroup m68k-asm nil
  "Motorola 680x0 assembly."
  :group 'languages)

(defcustom m68k-asm-indent-column 8
  "Column that instructions and directives are indented to."
  :type 'integer
  :group 'm68k-asm)

(defcustom m68k-asm-describe-operations t
  "Non-nil: name the current line's operation in the echo area (via eldoc).
C-c C-d toggles it in one buffer."
  :type 'boolean
  :group 'm68k-asm)

(defface m68k-asm-label-face
  '((((class color) (background dark)) :foreground "#F9EE98" :weight bold)
    (t :inherit font-lock-function-name-face :weight bold))
  "Face for labels and their uses.
A label is a name in column 0 that does not define a constant or macro."
  :group 'm68k-asm)

(defface m68k-asm-macro-face
  '((((class color) (background dark)) :foreground "#9B859D")
    (t :inherit font-lock-function-name-face))
  "Face for macro names, where defined and where called."
  :group 'm68k-asm)

(defface m68k-asm-constant-face
  '((((class color) (background dark)) :foreground "#89BDFF")
    (t :inherit font-lock-constant-face))
  "Face for constants (EQU, =, SET, EQUR, RS...), where defined and where used."
  :group 'm68k-asm)

(defconst m68k-asm--conditions
  '("t" "f" "hi" "ls" "cc" "hs" "cs" "lo" "ne" "eq" "vc" "vs" "pl" "mi" "ge" "lt" "gt" "le")
  "Integer condition codes, as in Bcc, DBcc, Scc and TRAPcc.")

(defconst m68k-asm--fpu-conditions
  '("f" "eq" "ogt" "oge" "olt" "ole" "ogl" "or" "un" "ueq" "ugt" "uge" "ult" "ule" "ne" "t"
    "sf" "seq" "gt" "ge" "lt" "le" "gl" "gle" "ngle" "ngl" "nle" "nlt" "nge" "ngt" "sne" "st")
  "FPU condition codes, as in FBcc, FDBcc, FScc and FTRAPcc.")

(defconst m68k-asm--instructions
  (append
   '("abcd" "add" "adda" "addi" "addq" "addx" "and" "andi" "asl" "asr"
     "bchg" "bclr" "bset" "btst" "bra" "bsr" "dbra"
     "bfchg" "bfclr" "bfexts" "bfextu" "bfffo" "bfins" "bfset" "bftst" "bkpt"
     "callm" "cas" "cas2" "chk" "chk2" "clr" "cmp" "cmpa" "cmpi" "cmpm" "cmp2"
     "divs" "divsl" "divu" "divul" "eor" "eori" "exg" "ext" "extb" "illegal"
     "jmp" "jsr" "lea" "link" "lsl" "lsr" "move" "movea" "movec" "movem" "movep"
     "moveq" "moves" "move16" "muls" "mulu" "nbcd" "neg" "negx" "nop" "not" "or" "ori"
     "pack" "pea" "reset" "rol" "ror" "roxl" "roxr" "rtd" "rte" "rtm" "rtr" "rts"
     "sbcd" "stop" "sub" "suba" "subi" "subq" "subx" "swap" "tas" "trap" "trapv" "tst"
     "unlk" "unpk" "lpstop"
     ;; caches and MMU (68030-68060)
     "cinva" "cinvl" "cinvp" "cpusha" "cpushl" "cpushp" "pflush" "pflusha" "pflushan"
     "pflushn" "pload" "pmove" "pmovefd" "ptest" "ptestr" "ptestw" "plpar" "plpaw"
     ;; FPU
     "fabs" "facos" "fadd" "fasin" "fatan" "fatanh" "fcmp" "fcos" "fcosh" "fdiv" "fetox"
     "fetoxm1" "fgetexp" "fgetman" "fint" "fintrz" "flog10" "flog2" "flogn" "flognp1"
     "fmod" "fmove" "fmovecr" "fmovem" "fmul" "fneg" "fnop" "frem" "frestore" "fsave"
     "fscale" "fsgldiv" "fsglmul" "fsin" "fsincos" "fsinh" "fsqrt" "fsub" "ftan" "ftanh"
     "ftentox" "ftst" "ftwotox"
     "fsabs" "fdabs" "fsadd" "fdadd" "fsdiv" "fddiv" "fsmove" "fdmove" "fsmul" "fdmul"
     "fsneg" "fdneg" "fssqrt" "fdsqrt" "fssub" "fdsub")
   ;; no BT/BF: "branch always" is BRA
   (mapcar (lambda (cc) (concat "b" cc)) (remove "t" (remove "f" m68k-asm--conditions)))
   (mapcar (lambda (cc) (concat "db" cc)) m68k-asm--conditions)
   (mapcar (lambda (cc) (concat "s" cc)) m68k-asm--conditions)
   (mapcar (lambda (cc) (concat "trap" cc)) m68k-asm--conditions)
   (mapcar (lambda (cc) (concat "fb" cc)) m68k-asm--fpu-conditions)
   (mapcar (lambda (cc) (concat "fdb" cc)) m68k-asm--fpu-conditions)
   (mapcar (lambda (cc) (concat "fs" cc)) m68k-asm--fpu-conditions)
   (mapcar (lambda (cc) (concat "ftrap" cc)) m68k-asm--fpu-conditions))
  "680x0 instruction mnemonics, without size suffix.")

(defconst m68k-asm--directives
  '("org" "rorg" "section" "offset" "cseg" "dseg" "code_c" "code_f" "data_c" "data_f"
    "bss_c" "bss_f" "public" "xdef" "xref" "nref" "entry" "extrn" "import" "export" "comm"
    "jumperr" "jumpptr" "mask2" "cnop" "align" "odd" "db" "dw" "dl" "dc" "ds" "dx" "dcb"
    "blk" "dr" "end" "fail" "assert" "idnt" "ttl" "module" "nolist" "plen" "llen" "page"
    "nopage" "spc" "symdebug" "dsource" "msource" "vdebug" "comment" "incdir" "include"
    "incbin" "image" "rept" "endr" "macro" "endm" "mexit" "rem" "erem" "ifb" "ifnb" "ifc"
    "ifnc" "ifd" "ifnd" "ifmacrod" "ifmacrond" "ifeq" "ifne" "ifgt" "ifge" "iflt" "ifle"
    "ifmi" "ifpl" "if" "ifp1" "if1" "if2" "else" "elseif" "elif" "endif" "endc" "rsreset"
    "rsset" "rseven" "clrso" "setso" "clrfo" "setfo" "rs" "so" "fo" "cargs" "echo" "printt"
    "printv" "showoffset" "auto" "inline" "einline" "pushsection" "popsection" "equ" "fequ"
    "set" "bss" "code" "data" "even" "iif" "list" "local" "output" "text" "weak" "basereg"
    "cpu32" "endb" "far" "fpu" "initnear" "machine" "mc68000" "mc68010" "mc68020" "mc68030"
    "mc68040" "mc68060" "ac68080" "near" "opt" "equr" "equrl" "fequr" "fequrl" "freg" "reg"
    "global")
  "Directives vasm 2.0f (mot syntax, M68k backend) accepts, without size suffix.
Checked by assembling each name with vasmm68k_mot.")

(defconst m68k-asm--registers
  '("d0" "d1" "d2" "d3" "d4" "d5" "d6" "d7" "a0" "a1" "a2" "a3" "a4" "a5" "a6" "a7"
    "sp" "ssp" "usp" "msp" "isp" "pc" "zpc" "sr" "ccr" "vbr" "sfc" "dfc" "cacr" "caar"
    "fp0" "fp1" "fp2" "fp3" "fp4" "fp5" "fp6" "fp7" "fpcr" "fpsr" "fpiar")
  "680x0 register names.")

;; The optional label in column 0 before an operation.
(defconst m68k-asm--label-prefix "^\\(?:[^ \t\n;*][^ \t\n;]*\\)?[ \t]+")

(defconst m68k-asm--size-suffix "\\(\\.[[:alpha:]]\\)?\\_>")

(defconst m68k-asm--operation-regexp
  (concat "\\_<" (regexp-opt (append m68k-asm--instructions m68k-asm--directives) t)
          "\\(?:\\.[[:alpha:]]\\)?\\_>")
  "A known instruction or directive, with optional size suffix.")

(defconst m68k-asm--macro-definition-regexp
  "^\\([[:alpha:]_.][[:alnum:]_.$]*\\):?[ \t]+macro\\_>"
  "A macro definition in column 0.  Group 1 is the name.")

(defconst m68k-asm--constant-definition-regexp
  (concat "^\\([[:alpha:]_.][[:alnum:]_.$]*\\):?"
          "\\(?:[ \t]*=\\|[ \t]+"
          (regexp-opt '("equ" "equr" "equrl" "fequ" "fequr" "fequrl" "freg" "set" "reg" "rs" "so" "fo"))
          "\\(?:\\.[[:alpha:]]\\)?\\_>\\)")
  "A column-0 name defining a constant, register alias or structure offset.
Group 1 is the name.  Match case-insensitively.")

(defvar-local m68k-asm--symbols nil
  "Labels and constants defined in this buffer: a hash table of name to
`label' or `constant'.")
(defvar-local m68k-asm--symbols-tick nil
  "`buffer-chars-modified-tick' when `m68k-asm--symbols' was collected.")

(defun m68k-asm--collect-symbols ()
  "Hash table of the labels and constants defined in this buffer.
Every name in column 0 is one or the other, except macro names."
  (let ((symbols (make-hash-table :test #'equal))
        (case-fold-search t))
    (save-excursion
      (save-restriction
        (widen)
        (goto-char (point-min))
        (while (re-search-forward "^[[:alpha:]_.][[:alnum:]_.$]*" nil t)
          (let ((name (match-string-no-properties 0)))
            (save-excursion
              (beginning-of-line)
              (cond ((looking-at m68k-asm--macro-definition-regexp))
                    ((looking-at m68k-asm--constant-definition-regexp)
                     (puthash name 'constant symbols))
                    (t (puthash name 'label symbols))))))))
    symbols))

(defun m68k-asm--same-symbols-p (a b)
  (and (= (hash-table-count a) (hash-table-count b))
       (catch 'differ
         (maphash (lambda (key kind) (unless (eq (gethash key b) kind) (throw 'differ nil))) a)
         t)))

(defun m68k-asm--symbols ()
  "The buffer's labels and constants, recollected after an edit.
When they change, the buffer is refontified once Emacs is idle, so uses
elsewhere pick up a name just defined or removed."
  (unless (eql m68k-asm--symbols-tick (buffer-chars-modified-tick))
    (let ((symbols (m68k-asm--collect-symbols))
          (buffer (current-buffer)))
      (when (and m68k-asm--symbols (not (m68k-asm--same-symbols-p symbols m68k-asm--symbols)))
        (run-with-idle-timer 0.2 nil (lambda ()
                                       (when (buffer-live-p buffer)
                                         (with-current-buffer buffer (font-lock-flush))))))
      (setq m68k-asm--symbols symbols
            m68k-asm--symbols-tick (buffer-chars-modified-tick))))
  m68k-asm--symbols)

(defun m68k-asm--match-symbol-reference (limit)
  "Font-lock matcher: the next use of a label or constant before LIMIT.
A label is matched as group 1, a constant as group 2.  `foo.w' (absolute
short) matches `foo'."
  (let ((symbols (m68k-asm--symbols))
        (found nil))
    (while (and (not found)
                (re-search-forward "\\_<[[:alpha:]_.][[:alnum:]_.$]*\\_>" limit t))
      (let* ((start (match-beginning 0))
             (end (match-end 0))
             (name (match-string-no-properties 0))
             (kind (gethash name symbols)))
        (when (and (not kind) (string-match "\\`\\(.+\\)\\.[[:alpha:]]\\'" name))
          (setq kind (gethash (match-string 1 name) symbols)
                end (+ start (length (match-string 1 name)))))
        (when kind
          (set-match-data (if (eq kind 'label)
                              (list start end start end)
                            (list start end nil nil start end)))
          (setq found t))))
    found))

(defconst m68k-asm-font-lock-keywords
  `(;; macro parameters: \1, \@, \<name>
    ("\\\\\\(?:[0-9@]\\|<[^>\n]*>\\)" . font-lock-variable-name-face)
    ;; definitions in column 0: macros, constants, and labels (everything else)
    (,m68k-asm--macro-definition-regexp 1 'm68k-asm-macro-face)
    (,m68k-asm--constant-definition-regexp 1 'm68k-asm-constant-face)
    ("^\\([[:alpha:]_.][[:alnum:]_.$]*\\):?" 1 'm68k-asm-label-face)
    ;; uses of labels and constants
    (m68k-asm--match-symbol-reference (1 'm68k-asm-label-face nil t)
                                      (2 'm68k-asm-constant-face nil t))
    (,(concat m68k-asm--label-prefix "\\(" (regexp-opt m68k-asm--instructions) "\\)"
              m68k-asm--size-suffix)
     (1 font-lock-keyword-face) (2 font-lock-type-face nil t))
    (,(concat m68k-asm--label-prefix "\\(" (regexp-opt m68k-asm--directives) "\\)"
              m68k-asm--size-suffix)
     (1 font-lock-preprocessor-face) (2 font-lock-type-face nil t))
    ;; any other operation is a macro call
    (,(concat m68k-asm--label-prefix "\\([[:alpha:]_][[:alnum:]_$]*\\)" m68k-asm--size-suffix)
     (1 'm68k-asm-macro-face) (2 font-lock-type-face nil t))
    (,(concat "\\_<" (regexp-opt m68k-asm--registers t) "\\(?:\\.[wl]\\)?\\_>")
     . font-lock-builtin-face)
    ;; numbers: $hex, %binary, @octal, decimal
    ("\\(?:^\\|[^[:alnum:]_.$\\\\]\\)\\(\\$[[:xdigit:]]+\\|%[01]+\\|@[0-7]+\\|[0-9]+\\)\\_>"
     1 font-lock-constant-face))
  "Highlighting for `m68k-asm-mode'.")

(defvar m68k-asm-mode-syntax-table
  (let ((table (make-syntax-table)))
    (modify-syntax-entry ?\; "<" table)
    (modify-syntax-entry ?\n ">" table)
    (modify-syntax-entry ?\" "\"" table)
    (modify-syntax-entry ?' "\"" table)
    ;; `move.l', `.local', `loop$' are single symbols
    (dolist (char '(?_ ?. ?$))
      (modify-syntax-entry char "_" table))
    (dolist (char '(?% ?@ ?# ?* ?+ ?- ?/ ?& ?| ?^ ?~ ?< ?> ?= ?!))
      (modify-syntax-entry char "." table))
    table)
  "Syntax table for `m68k-asm-mode'.")

(defconst m68k-asm--syntax-propertize
  ;; `*' in column 0 starts a comment; elsewhere it is multiplication or the PC
  (syntax-propertize-rules ("^\\(\\*\\)" (1 "<"))))

(defun m68k-asm--calculate-indentation ()
  "Column for the current line, or nil to leave it alone.
Point is at the first non-blank character of the line."
  (cond
   ((eolp) m68k-asm-indent-column)
   ((nth 4 (save-excursion (syntax-ppss (1+ (point))))) nil) ; comment-only line
   ((looking-at "[^ \t\n;]+:") 0)
   ((and (zerop (current-column))
         (not (let ((case-fold-search t))
                (looking-at m68k-asm--operation-regexp))))
    0)
   (t m68k-asm-indent-column)))

(defun m68k-asm-indent-line ()
  "Indent the current line as 680x0 assembly."
  (interactive)
  (let ((column (save-excursion
                  (back-to-indentation)
                  (m68k-asm--calculate-indentation))))
    (when column
      (if (<= (current-column) (current-indentation))
          (indent-line-to column)
        (save-excursion (indent-line-to column))))))

(autoload 'm68k-asm-cycles-mode "m68k-asm-cycles" "Show clock-cycle costs in the left margin." t)
(autoload 'm68k-asm-cycles-set-target "m68k-asm-cycles" "Pick the CPU for clock-cycle costs." t)

(autoload 'm68k-asm-doc-eldoc "m68k-asm-doc")

(defun m68k-asm-toggle-describe-operations ()
  "Toggle naming the current line's operation in the echo area, in this buffer."
  (interactive)
  (setq-local m68k-asm-describe-operations (not m68k-asm-describe-operations))
  (when m68k-asm-describe-operations
    (eldoc-mode 1))
  (message "Operation descriptions %s" (if m68k-asm-describe-operations "on" "off")))

(defvar-keymap m68k-asm-mode-map
  :doc "Keymap for `m68k-asm-mode'."
  "C-c C-c" #'m68k-asm-cycles-mode
  "C-c C-t" #'m68k-asm-cycles-set-target
  "C-c C-d" #'m68k-asm-toggle-describe-operations)

;;;###autoload
(define-derived-mode m68k-asm-mode prog-mode "m68k"
  "Major mode for Motorola 680x0 assembly: highlighting and indentation."
  :syntax-table m68k-asm-mode-syntax-table
  (setq-local font-lock-defaults '(m68k-asm-font-lock-keywords nil t))
  (setq-local syntax-propertize-function m68k-asm--syntax-propertize)
  (setq-local comment-start ";")
  (setq-local comment-start-skip ";+[ \t]*")
  (setq-local comment-end "")
  (setq-local indent-line-function #'m68k-asm-indent-line)
  (setq-local tab-always-indent nil)
  ;; reindent as soon as a label's colon is typed
  (setq-local electric-indent-chars (cons ?: electric-indent-chars))
  ;; the sources are written for 8-column hard tabs (vasm convention)
  (setq-local tab-width 8)
  (setq-local indent-tabs-mode t)
  (add-hook 'eldoc-documentation-functions #'m68k-asm-doc-eldoc nil t)
  (when m68k-asm-describe-operations
    (eldoc-mode 1)))

(provide 'm68k-asm-mode)
;;; m68k-asm-mode.el ends here
