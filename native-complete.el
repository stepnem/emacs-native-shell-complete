;;; native-complete.el --- Shell completion using native complete mechanisms -*- lexical-binding: t; -*-

;; Copyright (C) 2019 by Troy Hinckley

;; Author: Troy Hinckley <troy.hinckley@gmail.com>
;; URL: https://github.com/CeleritasCelery/emacs-native-shell-complete
;; Version: 0.1.0
;; Package-Requires: ((emacs "25.1"))


;;; Commentary:
;; This package interacts with a shell's native completion functionality to
;; provide the same completions in Emacs that you would get from the shell
;; itself.

;;; Code:

(require 'subr-x)

(defvar native-complete--command "")
(defvar native-complete--prefix "")
(defvar native-complete--common "")
(defvar native-complete--redirection-command "")
(defvar native-complete--buffer " *native-complete redirect*")

(defgroup native-complete nil
  "Native completion in a shell buffer."
  :group 'shell)

(defcustom native-complete-major-modes '(shell-mode)
  "Major modes for which native completion is enabled."
  :type '(repeat function))

(defcustom native-complete-exclude-regex (rx (not (in alnum "-_~()/*.,+$")))
  "Regex of elements to ignore when generating candidates.
Any candidates matching this regex will not be included in final
  list of candidates."
  :type 'regexp)

(defcustom native-complete-style-regex-alist nil
  "An alist of prompt regex and their completion mechanisms.
the car of each alist element is a regex matching the prompt for
a particular shell type. The cdr is one of the following symbols
`bash', `zsh', or `tab'.

- `bash' style uses `M-*' and `echo'
- `zsh' style uses `C-D'
- `tab' style uses `TAB'

You may need to test this on an line editing enabled shell to see
which of these options a particular shell supports. Most shells
support basic TAB completion, but some will not echo the
candidate to output when it is the sole completion. Hence the
need for the other methods as well."
  :type '(alist :key-type regexp :value-type '(options bash zsh csh tab)))

(defvar explicit-bash-args)

;;;###autoload
(defun native-complete-setup-bash ()
  "Setup support for native-complete enabled bash shells.
This involves not sending the `--noediting' argument as well as
setting `TERM' to a value other then dumb."
  (interactive)
  (with-eval-after-load 'shell
    (when (equal comint-terminfo-terminal "dumb")
      (setq comint-terminfo-terminal "vt50"))
    (setq explicit-bash-args
          (delete "--noediting" explicit-bash-args))))

(defun native-complete-get-completion-style ()
  "Get the completion style based on current prompt."
  (or (cl-loop for (regex . style) in native-complete-style-regex-alist
               if (looking-back regex (line-beginning-position 0))
               return style)
      (cl-loop for style in '(bash zsh csh)
               if (string-match-p (symbol-name style) shell-file-name)
               return style)
      'tab))

(defun native-complete--redirection-active-p ()
  "Indicate whether redirection is currently active."
  (string-match-p "Redirection"
                  (cond
                   ((stringp mode-line-process)
                    mode-line-process)
                   ((consp mode-line-process)
                    (car mode-line-process))
                   (t
                    ""))))

(defun native-complete--usable-p ()
  "Return non-nil if native-complete can be used at point."
  (and (memq major-mode native-complete-major-modes)
       (not (native-complete--redirection-active-p))))

(defun native-complete-abort (&rest _)
  "Abort completion and cleanup redirect if needed."
  (when (native-complete--redirection-active-p)
    (comint-redirect-cleanup)))

(advice-add 'comint-send-input :before 'native-complete-abort)

(defun native-complete--get-prefix ()
  "Setup output redirection to query the source shell."
  (let* ((redirect-buffer (get-buffer-create native-complete--buffer))
         (proc (get-buffer-process (current-buffer)))
         (beg (process-mark proc))
         (end (point))
         (str (buffer-substring-no-properties beg end))
         (word-start (or (cl-search " " str :from-end t) -1))
         (env-start (or (cl-search "$" str :from-end t) -1))
         (path-start (or (cl-search "/" str :from-end t) -1))
         (prefix-start (1+ (max word-start env-start path-start)))
         (style (cl-letf (((point) beg)) (native-complete-get-completion-style)))
         ;; sanity check makes sure the input line is empty, which is
         ;; not useful when doing input completion
         (comint-redirect-perform-sanity-check nil))
    (unless (cl-letf (((point) beg))
              (looking-back comint-prompt-regexp (line-beginning-position 0)))
      (user-error "`comint-prompt-regexp' does not match prompt"))
    (with-current-buffer redirect-buffer (erase-buffer))
    (setq native-complete--common (substring str (1+ word-start) prefix-start)
          native-complete--command str
          native-complete--prefix (substring str prefix-start)
          ;; When the number of candidates is larger then a certain threshold
          ;; most shells will query the user before displaying them all. We
          ;; always send a "y" character to auto-answer these queries so that we
          ;; get all candidates. We do some special handling in
          ;; `native-complete--get-completions' to make sure this "y" character
          ;; never shows up in the completion list.
          native-complete--redirection-command
          (concat str (pcase style
                        (`bash "\e*' echo '")
                        ((or `zsh `csh) "y")
                        (_ "\ty"))))))

(defun native-complete--get-completions ()
  "Using the redirection output get all completion candidates."
  (let* ((cmd (string-remove-suffix
               native-complete--prefix
               native-complete--command))
         ;; when the sole completion is something like a directory it does not
         ;; append a space. We need to seperate this candidate from the "y"
         ;; character so it will be consumed properly.
         (continued-cmd
          (rx-to-string `(: bos (group ,native-complete--command (+ graph)) "y" (in ""))))
         ;; the current command may be echoed multiple times in the output. We
         ;; only want to leave it when it ends with a space since that means it
         ;; is the sole completion
         (echo-cmd
          (rx-to-string `(: bol ,native-complete--command (* graph) (in ""))))
         ;; Remove the "display all possibilities" query so that it does not get
         ;; picked up as a completion.
         (query-text (rx bol (1+ nonl) "? "
                         (or "[y/n]" "[n/y]" "(y or n)" "(n or y)")
                         (* nonl) eol))
         (ansi-color-context nil)
         (buffer (with-current-buffer native-complete--buffer
                   (when (re-search-backward continued-cmd nil t)
                     (goto-char (match-end 1))
                     (insert " "))
                   (buffer-string))))
    (thread-last (split-string buffer "\n\n")
      (car)
      (ansi-color-filter-apply)
      (replace-regexp-in-string echo-cmd "")
      (replace-regexp-in-string "echo '.+'" "")
      (replace-regexp-in-string query-text "")
      (replace-regexp-in-string (concat "^" (regexp-quote cmd)) "")
      (split-string)
      (cl-remove-if (lambda (x) (string-match-p native-complete-exclude-regex x)))
      (mapcar (lambda (x) (string-remove-prefix native-complete--common x)))
      (mapcar (lambda (x) (string-remove-suffix "*" x)))
      (cl-remove-if-not (lambda (x) (string-prefix-p native-complete--prefix x)))
      (delete-dups))))

;;;###autoload
(defun native-complete-at-point ()
  "Get the candidates from the underlying shell.
This should behave the same as sending TAB in an terminal
emulator."
  (when (native-complete--usable-p)
    (native-complete--get-prefix)
    (comint-redirect-send-command
     native-complete--redirection-command
     native-complete--buffer nil t)
    (unwind-protect
        (while (or quit-flag (null comint-redirect-completed))
          (accept-process-output nil 0.1))
      (unless comint-redirect-completed
        (comint-redirect-cleanup)))
    (list (- (point) (length native-complete--prefix))
          (point)
          (native-complete--get-completions))))

(provide 'native-complete)

;;; native-complete.el ends here
