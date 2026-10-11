;;; m68k-asm-panel.el --- Extended documentation for 680x0 operations in a side panel  -*- lexical-binding: t -*-

;;; Commentary:
;; For `m68k-asm-mode': a panel on the right of the frame with the full
;; documentation page of the operation on the current line: syntax, operation,
;; condition codes, addressing modes, processors and description.  While it is
;; open it follows point.  C-c C-p opens and closes it.
;;
;; The pages come from the documentation of grahambates' m68k-tools (MIT),
;; which is a git submodule of this repository:
;;   git submodule update --init
;; That text is adapted from Motorola's M68000 Family Programmer's Reference
;; Manual (copyright Motorola Inc./NXP).
;;
;; m68k-tools covers the 68000 thoroughly; many 020+ pages carry only a title
;; and the processors, and some names have no page.  The panel always starts
;; with this mode's own one-line description, so there is something to read.

;;; Code:

(require 'm68k-asm-doc)

(defgroup m68k-asm-panel nil
  "Extended documentation panel for 680x0 assembly."
  :group 'm68k-asm)

(defconst m68k-asm-panel--root (file-name-directory (or load-file-name buffer-file-name)))

(defcustom m68k-asm-panel-docs-directory
  (expand-file-name "m68k-tools/packages/m68k-lsp-server/src/docs" m68k-asm-panel--root)
  "Directory holding m68k-tools' instructions.json and directives.json."
  :type 'directory
  :group 'm68k-asm-panel)

(defcustom m68k-asm-panel-width 0.33
  "Width of the panel, as a fraction of the frame."
  :type 'number
  :group 'm68k-asm-panel)

(defconst m68k-asm-panel--buffer-name "*m68k-asm doc*")

(defconst m68k-asm-panel--aliases
  '(("dbra" . "dbf") ("bhs" . "bcc") ("blo" . "bcs") ("dbhs" . "dbcc") ("dblo" . "dbcs")
    ("shs" . "scc") ("slo" . "scs") ("traphs" . "trapcc") ("traplo" . "trapcs")
    ("cinva" . "cinv") ("cinvl" . "cinv") ("cinvp" . "cinv")
    ("ptestr" . "ptest") ("ptestw" . "ptest") ("pflushn" . "pflush") ("pflushan" . "pflush")
    ("pmovefd" . "pmove")
    ("dseg" . "data") ("entry" . "public") ("extrn" . "public") ("global" . "public")
    ("import" . "xref") ("export" . "xdef") ("module" . "idnt") ("image" . "incbin")
    ("ifmi" . "iflt") ("ifpl" . "ifge") ("equrl" . "reg"))
  "Names without a page of their own, and the page that covers them.")

(defconst m68k-asm-panel--addressing-modes
  '(("dn" . "Dn") ("an" . "An") ("anIndirect" . "(An)") ("anPostInc" . "(An)+")
    ("anPreDec" . "-(An)") ("anOffset" . "(d16,An)") ("anIdx" . "(d8,An,Xn)")
    ("absW" . "abs.w") ("absL" . "abs.l") ("pcOffset" . "(d16,PC)") ("pcIdx" . "(d8,PC,Xn)")
    ("imm" . "#imm"))
  "m68k-tools' addressing-mode keys, in display order.")

(defconst m68k-asm-panel--processors
  '(("mc68000" . "68000") ("mc68010" . "68010") ("mc68020" . "68020") ("mc68030" . "68030")
    ("mc68040" . "68040") ("mc68060" . "68060") ("cpu32" . "CPU32")
    ("mc68881" . "68881/2 FPU") ("mc68851" . "68851 MMU"))
  "m68k-tools' processor keys, in display order.")

(defvar m68k-asm-panel--instructions nil)
(defvar m68k-asm-panel--directives nil)
(defvar m68k-asm-panel--timer nil)
(defvar m68k-asm-panel--shown nil
  "The one-line description of what the panel shows, to skip needless redraws.")

(defface m68k-asm-panel-heading-face
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for section headings in the panel."
  :group 'm68k-asm-panel)

(defface m68k-asm-panel-title-face
  '((t :weight bold :height 1.3))
  "Face for the title in the panel."
  :group 'm68k-asm-panel)

(defun m68k-asm-panel--read-json (name)
  (let ((file (expand-file-name name m68k-asm-panel-docs-directory)))
    (unless (file-readable-p file)
      (user-error "No %s; run `git submodule update --init' in %s" file m68k-asm-panel--root))
    (with-temp-buffer
      (insert-file-contents file)
      (json-parse-buffer :object-type 'hash-table :array-type 'list))))

(defun m68k-asm-panel--load ()
  (unless m68k-asm-panel--instructions
    (setq m68k-asm-panel--instructions (m68k-asm-panel--read-json "instructions.json")
          m68k-asm-panel--directives (m68k-asm-panel--read-json "directives.json"))))

(defun m68k-asm-panel--page (mnemonic)
  "The page for MNEMONIC, as (PAGE . NAME), NAME being the name it is under."
  (let* ((name (or (cdr (assoc mnemonic m68k-asm-panel--aliases)) mnemonic))
         (directive (eq (car (gethash mnemonic m68k-asm-doc--table)) 'directive))
         (page (gethash name (if directive m68k-asm-panel--directives m68k-asm-panel--instructions))))
    (and page (cons page name))))

(defun m68k-asm-panel--clean (text)
  "TEXT with m68k-tools' bits of HTML and Markdown made plain.
Code, bold and italic spans keep their meaning as faces."
  (with-temp-buffer
    (insert text)
    (dolist (rule '(("<br/>\n?" . "\n") ("&nbsp;" . " ")))
      (goto-char (point-min))
      (while (re-search-forward (car rule) nil t)
        (replace-match (cdr rule) t t)))
    (goto-char (point-min))
    (while (re-search-forward "&#x\\([[:xdigit:]]+\\);" nil t)
      (replace-match (string (string-to-number (match-string 1) 16)) t t))
    (dolist (rule '(("`\\([^`\n]+\\)`" . font-lock-constant-face)
                    ("\\*\\*\\([^*\n]+\\)\\*\\*" . bold)
                    ("\\*\\([^*\n]+\\)\\*" . italic)))
      (goto-char (point-min))
      (while (re-search-forward (car rule) nil t)
        (replace-match (propertize (match-string 1) 'face (cdr rule)) t t)))
    ;; Markdown escapes, last so that \* is not taken for emphasis
    (goto-char (point-min))
    (while (re-search-forward "\\\\\\([][<>*_`#|\\\\]\\)" nil t)
      (replace-match "\\1" t))
    (buffer-string)))

(defun m68k-asm-panel--paragraphs (text)
  "TEXT with the line breaks inside paragraphs removed, for `visual-line-mode'."
  (replace-regexp-in-string "\\([^\n]\\)\n\\([^\n|-]\\)" "\\1 \\2" text))

(defun m68k-asm-panel--section (heading)
  (insert "\n" (propertize heading 'face 'm68k-asm-panel-heading-face) "\n"))

(defun m68k-asm-panel--modes (modes)
  (mapconcat #'cdr (seq-filter (lambda (mode) (eq (gethash (car mode) modes) t))
                               m68k-asm-panel--addressing-modes)
             "  "))

(defun m68k-asm-panel--insert-page (page name mnemonic)
  (let ((title (gethash "title" page))
        (summary (gethash "summary" page))
        (syntax (gethash "syntax" page))
        (operation (gethash "operation" page))
        (ccr (gethash "ccr" page))
        (src (gethash "src" page))
        (dest (gethash "dest" page))
        (procs (gethash "procs" page))
        (description (gethash "description" page)))
    (insert (propertize (or title (upcase name)) 'face 'm68k-asm-panel-title-face))
    (when summary (insert "  " summary))
    (insert "\n")
    (unless (equal name mnemonic)
      (insert (propertize (format "%s has no page of its own; this is %s.\n"
                                  (upcase mnemonic) (upcase name))
                          'face 'shadow)))
    (when syntax
      (m68k-asm-panel--section "Syntax")
      (dolist (line syntax)
        (insert "  " (m68k-asm-panel--clean line) "\n")))
    (when operation
      (m68k-asm-panel--section "Operation")
      (dolist (line (split-string (m68k-asm-panel--clean operation) "\n" t))
        (insert "  " line "\n")))
    (when ccr
      (m68k-asm-panel--section "Condition codes")
      (insert "  X N Z V C\n  "
              (mapconcat (lambda (flag) (or (gethash flag ccr) "?")) '("x" "n" "z" "v" "c") " ")
              "\n"
              (propertize "  * set by the result, - unchanged, 0 cleared, 1 set, U undefined\n"
                          'face 'shadow)))
    (when (or src dest)
      (m68k-asm-panel--section "Addressing modes")
      (when src (insert "  Source: " (m68k-asm-panel--modes src) "\n"))
      (when dest (insert "  Destination: " (m68k-asm-panel--modes dest) "\n")))
    (when procs
      (m68k-asm-panel--section "Processors")
      (insert "  "
              (mapconcat #'cdr (seq-filter (lambda (proc) (eq (gethash (car proc) procs) t))
                                           m68k-asm-panel--processors)
                         "  ")
              "\n"))
    (when description
      (m68k-asm-panel--section "Description")
      (insert (m68k-asm-panel--paragraphs (m68k-asm-panel--clean description)) "\n"))))

(defun m68k-asm-panel--render (line mnemonic)
  "Fill the panel for the one-line description LINE of MNEMONIC (nil for a macro)."
  (with-current-buffer (get-buffer-create m68k-asm-panel--buffer-name)
    (let ((inhibit-read-only t)
          (page (and mnemonic (m68k-asm-panel--page mnemonic))))
      (erase-buffer)
      (insert line "\n")
      (if page
          (progn
            (insert "\n")
            (m68k-asm-panel--insert-page (car page) (cdr page) mnemonic)
            (insert "\n" (propertize (if (eq (car (gethash mnemonic m68k-asm-doc--table)) 'directive)
                                          "From m68k-tools (Graham Bates)."
                                        "From m68k-tools (Graham Bates), adapted from Motorola's \
M68000 Family Programmer's Reference Manual.")
                                      'face 'shadow)
                    "\n"))
        (when mnemonic
          (insert "\n" (propertize "m68k-tools has no page for this one." 'face 'shadow) "\n")))
      (goto-char (point-min)))))

(defun m68k-asm-panel--update ()
  "Show the current line's operation in the panel, if it is open."
  (if (not (get-buffer-window m68k-asm-panel--buffer-name t))
      (m68k-asm-panel--stop)
    (when (derived-mode-p 'm68k-asm-mode)
      (let ((line (m68k-asm-doc--describe-line)))
        (when (and line (not (equal line m68k-asm-panel--shown)))
          (setq m68k-asm-panel--shown line)
          (let ((mnemonic (downcase (nth 1 (m68k-asm-doc--line-operation)))))
            (m68k-asm-panel--render line (and (gethash mnemonic m68k-asm-doc--table) mnemonic))))))))

(defun m68k-asm-panel--stop ()
  (when (timerp m68k-asm-panel--timer)
    (cancel-timer m68k-asm-panel--timer))
  (setq m68k-asm-panel--timer nil
        m68k-asm-panel--shown nil))

(define-derived-mode m68k-asm-panel-mode special-mode "m68k-doc"
  "Mode of the documentation panel."
  (visual-line-mode 1)
  (setq-local truncate-lines nil))

;;;###autoload
(defun m68k-asm-panel ()
  "Open or close the documentation panel on the right of the frame.
While open, it shows the page of the operation on the current line."
  (interactive)
  (let ((window (get-buffer-window m68k-asm-panel--buffer-name t)))
    (if window
        (progn
          (delete-window window)
          (m68k-asm-panel--stop))
      (m68k-asm-panel--load)
      (let ((buffer (get-buffer-create m68k-asm-panel--buffer-name)))
        (with-current-buffer buffer
          (unless (derived-mode-p 'm68k-asm-panel-mode)
            (m68k-asm-panel-mode))
          (let ((inhibit-read-only t))
            (erase-buffer)
            (insert (propertize "Move to an instruction or directive." 'face 'shadow))))
        (display-buffer-in-side-window
         buffer `((side . right) (slot . 0) (window-width . ,m68k-asm-panel-width)
                  (preserve-size . (t . nil)))))
      (setq m68k-asm-panel--shown nil)
      (m68k-asm-panel--update)
      (setq m68k-asm-panel--timer (run-with-idle-timer 0.2 t #'m68k-asm-panel--update)))))

(provide 'm68k-asm-panel)
;;; m68k-asm-panel.el ends here
