;;; m68k-asm-cycles.el --- Clock-cycle costs in the left margin for 680x0 assembly  -*- lexical-binding: t -*-

;;; Commentary:
;; A minor mode for `m68k-asm-mode' that shows each instruction's clock-cycle
;; cost in the left margin, for a chosen target CPU (68000, 68020, 68030).
;;
;; The timings come from grahambates' 68kcounter (MIT; tables transcribed from
;; the Motorola user's manuals), run on the whole buffer in the background:
;;   npm install -g 68kcounter
;; It reruns `m68k-asm-cycles-delay' seconds after the last edit.  An
;; instruction with several outcomes shows them all, e.g. a branch's
;; "taken/not taken" or DBcc's "taken/not taken/expired".  Lines it cannot time
;; (FPU, MMU, macro calls, operands built from constants defined in another
;; file) are left blank.
;;
;; The target chosen here wins over `machine' / `mc680x0' directives in the
;; source, which 68kcounter would otherwise follow.
;;
;; Figures are per instruction in isolation: on the 020/030 they ignore pipeline
;; overlap, and nothing models chip-RAM wait states or the data cache.

;;; Code:

(defgroup m68k-asm-cycles nil
  "Clock-cycle costs in the margin for 680x0 assembly."
  :group 'm68k-asm)

(defcustom m68k-asm-cycles-target "68000"
  "CPU whose clock-cycle costs are shown.
`m68k-asm-cycles-set-target' (C-c C-t) changes it."
  :type '(choice (const "68000") (const "68020") (const "68030"))
  :group 'm68k-asm-cycles)

(defcustom m68k-asm-cycles-cache t
  "Non-nil: on the 68020/68030, assume the instruction is in the cache.
nil gives 68kcounter's no-cache case instead (68020 worst case, 68030 average).
No effect on the 68000, which has no cache."
  :type 'boolean
  :group 'm68k-asm-cycles)

(defcustom m68k-asm-cycles-program "68kcounter"
  "The 68kcounter executable."
  :type 'string
  :group 'm68k-asm-cycles)

(defcustom m68k-asm-cycles-delay 0.5
  "Seconds of idle time after an edit before the costs are recounted."
  :type 'number
  :group 'm68k-asm-cycles)

(defface m68k-asm-cycles-face
  '((t :inherit shadow))
  "Face of the cycle counts in the margin."
  :group 'm68k-asm-cycles)

(defvar m68k-asm-cycles-mode)

(defvar-local m68k-asm-cycles--overlays nil)
(defvar-local m68k-asm-cycles--timer nil)
(defvar-local m68k-asm-cycles--process nil)
(defvar-local m68k-asm-cycles--saved-margin nil)

;; A `machine' or `mc680x0' directive, optionally after a label.
(defconst m68k-asm-cycles--machine-regexp
  "^\\(?:[^ \t\n;*][^ \t\n;]*\\)?[ \t]+\\(?:machine\\|mc680[0-6]0\\)\\_>.*$")

(defun m68k-asm-cycles--clear ()
  (mapc #'delete-overlay m68k-asm-cycles--overlays)
  (setq m68k-asm-cycles--overlays nil))

(defun m68k-asm-cycles--set-margin (width)
  (setq left-margin-width width)
  (dolist (window (get-buffer-window-list nil nil t))
    (set-window-margins window left-margin-width right-margin-width)))

(defun m68k-asm-cycles--stop-process ()
  (when (process-live-p m68k-asm-cycles--process)
    (delete-process m68k-asm-cycles--process))
  (setq m68k-asm-cycles--process nil))

(defun m68k-asm-cycles--label (line)
  "Margin text for one line of 68kcounter's JSON, or nil if it has no timing."
  (let ((values (alist-get 'values (alist-get 'timing line))))
    (when values
      (mapconcat (lambda (value) (number-to-string (car value))) values "/"))))

(defun m68k-asm-cycles--apply (lines)
  "Put the timings of LINES, 68kcounter's per-line JSON, into the margin."
  (m68k-asm-cycles--clear)
  (let ((labels nil)
        (width 3))
    (save-excursion
      (save-restriction
        (widen)
        (goto-char (point-min))
        (dolist (line lines)
          (let ((label (m68k-asm-cycles--label line)))
            (when label
              (push (cons (point) label) labels)
              (setq width (max width (length label)))))
          (forward-line 1))))
    (dolist (entry labels)
      (let ((overlay (make-overlay (car entry) (car entry) nil t nil))
            (text (propertize (string-pad (cdr entry) width nil t) 'face 'm68k-asm-cycles-face)))
        (overlay-put overlay 'm68k-asm-cycles t)
        (overlay-put overlay 'before-string
                     (propertize " " 'display `((margin left-margin) ,text)))
        (push overlay m68k-asm-cycles--overlays)))
    (m68k-asm-cycles--set-margin (1+ width))))

(defun m68k-asm-cycles--sentinel (process _event)
  (unless (process-live-p process)
    (let ((source (process-get process 'source))
          (output (process-buffer process))
          (errors (process-get process 'errors)))
      (when (and (eq (process-status process) 'exit)
                 (buffer-live-p source)
                 (eq process (buffer-local-value 'm68k-asm-cycles--process source)))
        (with-current-buffer source
          (setq m68k-asm-cycles--process nil)
          (cond
           ((/= (process-exit-status process) 0)
            (message "68kcounter failed: %s"
                     (with-current-buffer errors (string-trim (buffer-string)))))
           ;; edited while it ran: the rerun is already scheduled
           ((= (process-get process 'tick) (buffer-chars-modified-tick))
            (m68k-asm-cycles--apply
             (alist-get 'lines (with-current-buffer output
                                 (goto-char (point-min))
                                 (json-parse-buffer :object-type 'alist :array-type 'list))))))))
      (kill-buffer output)
      (kill-buffer errors))))

(defun m68k-asm-cycles--run (&optional buffer)
  "Recount the cycle costs of BUFFER (default the current one)."
  (with-current-buffer (or buffer (current-buffer))
    (when m68k-asm-cycles-mode
      (m68k-asm-cycles--stop-process)
      (let* ((source (current-buffer))
             (text (save-restriction
                     (widen)
                     (let ((case-fold-search t))
                       (replace-regexp-in-string m68k-asm-cycles--machine-regexp ""
                                                 (buffer-substring-no-properties
                                                  (point-min) (point-max))))))
             (errors (generate-new-buffer " *m68k-asm-cycles errors*"))
             (process (make-process
                       :name "68kcounter"
                       :buffer (generate-new-buffer " *m68k-asm-cycles*")
                       :command (append (list m68k-asm-cycles-program
                                              "--cpu" m68k-asm-cycles-target
                                              "-f" "json" "--prettyPrint" "false"
                                              "-i" "timings")
                                        (and m68k-asm-cycles-cache '("--cache")))
                       :connection-type 'pipe
                       :noquery t
                       :stderr errors
                       :sentinel #'m68k-asm-cycles--sentinel)))
        (process-put process 'source source)
        (process-put process 'errors errors)
        (process-put process 'tick (buffer-chars-modified-tick))
        (setq m68k-asm-cycles--process process)
        (process-send-string process text)
        (process-send-eof process)))))

(defun m68k-asm-cycles--schedule (&rest _)
  (when (timerp m68k-asm-cycles--timer)
    (cancel-timer m68k-asm-cycles--timer))
  (setq m68k-asm-cycles--timer
        (run-with-idle-timer m68k-asm-cycles-delay nil
                             #'m68k-asm-cycles--run (current-buffer))))

;;;###autoload
(define-minor-mode m68k-asm-cycles-mode
  "Show each instruction's clock-cycle cost in the left margin.
The target CPU is `m68k-asm-cycles-target'; change it with
`m68k-asm-cycles-set-target'."
  :lighter (:eval (format " Cyc%s" (substring m68k-asm-cycles-target 2)))
  (if m68k-asm-cycles-mode
      (if (not (executable-find m68k-asm-cycles-program))
          (progn
            (setq m68k-asm-cycles-mode nil)
            (user-error "%s not found; npm install -g 68kcounter" m68k-asm-cycles-program))
        (setq m68k-asm-cycles--saved-margin left-margin-width)
        (add-hook 'after-change-functions #'m68k-asm-cycles--schedule nil t)
        (m68k-asm-cycles--run))
    (remove-hook 'after-change-functions #'m68k-asm-cycles--schedule t)
    (when (timerp m68k-asm-cycles--timer)
      (cancel-timer m68k-asm-cycles--timer))
    (m68k-asm-cycles--stop-process)
    (m68k-asm-cycles--clear)
    (m68k-asm-cycles--set-margin m68k-asm-cycles--saved-margin)))

;;;###autoload
(defun m68k-asm-cycles-set-target (target)
  "Show clock-cycle costs for TARGET CPU, in every buffer.
Sets `m68k-asm-cycles-target' globally, recounts the buffers that show
costs, and turns on `m68k-asm-cycles-mode' here if it is off."
  (interactive
   (let ((targets '("68000" "68020" "68030")))
     (list (completing-read (format-prompt "Target CPU [%s]" m68k-asm-cycles-target
                                           (string-join targets ", "))
                            targets nil t nil nil m68k-asm-cycles-target))))
  (setq m68k-asm-cycles-target target)
  (dolist (buffer (buffer-list))
    (when (buffer-local-value 'm68k-asm-cycles-mode buffer)
      (m68k-asm-cycles--run buffer)))
  (unless m68k-asm-cycles-mode
    (m68k-asm-cycles-mode 1))
  (force-mode-line-update t))

(provide 'm68k-asm-cycles)
;;; m68k-asm-cycles.el ends here
