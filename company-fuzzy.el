;;; company-fuzzy.el --- Fuzzy matching for `company-mode'  -*- lexical-binding: t; -*-

;; Copyright (C) 2019  Shen, Jen-Chieh
;; Created date 2019-08-01 16:54:34

;; Author: Shen, Jen-Chieh <jcs090218@gmail.com>
;; Description: Fuzzy matching for `company-mode'.
;; Keyword: auto auto-complete complete fuzzy matching
;; Version: 0.9.2
;; Package-Requires: ((emacs "24.4") (company "0.8.12") (s "1.12.0"))
;; URL: https://github.com/jcs-elpa/company-fuzzy

;; This file is NOT part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; Fuzzy matching for `company-mode'.
;;

;;; Code:

(require 'company)
(require 'cl-lib)
(require 'ffap)
(require 's)
(require 'subr-x)

(defgroup company-fuzzy nil
  "Fuzzy matching for `company-mode'."
  :prefix "company-fuzzy-"
  :group 'company
  :link '(url-link :tag "Repository" "https://github.com/jcs-elpa/company-fuzzy"))

(defcustom company-fuzzy-sorting-backend 'alphabetic
  "Type for sorting/scoring backend."
  :type '(choice (const :tag "none" none)
                 (const :tag "alphabetic" alphabetic)
                 (const :tag "flx" flx))
  :group 'company-fuzzy)

(defcustom company-fuzzy-prefix-on-top t
  "Have the matching prefix on top."
  :type 'boolean
  :group 'company-fuzzy)

(defcustom company-fuzzy-sorting-function nil
  "Function that gives all candidates and let you do your own sorting."
  :type '(choice (const :tag "None" nil)
                 function)
  :group 'company-fuzzy)

(defcustom company-fuzzy-sorting-score-function nil
  "Function that gives candidates with same score and let you do your own sorting."
  :type '(choice (const :tag "None" nil)
                 function)
  :group 'company-fuzzy)

(defcustom company-fuzzy-show-annotation t
  "Show annotation from source."
  :type 'boolean
  :group 'company-fuzzy)

(defcustom company-fuzzy-annotation-format " <%s>"
  "Annotation string format."
  :type 'string
  :group 'company-fuzzy)

(defcustom company-fuzzy-history-backends '(company-yasnippet)
  "List of backends that kept the history to do fuzzy sorting."
  :type 'list
  :group 'company-fuzzy)

(defcustom company-fuzzy-trigger-symbols '("." "->")
  "List of symbols that allow trigger company when there is no prefix."
  :type 'list
  :group 'company-fuzzy)

(defcustom company-fuzzy-completion-separator "[ \t\r\n]\\|\\_<\\|\\_>"
  "Use to identify the completion unit."
  :type 'string
  :group 'company-fuzzy)

(defvar-local company-fuzzy--prefix ""
  "Record down the company current search reg/characters.")

(defvar-local company-fuzzy--backends nil
  "Company fuzzy backends we are going to use.")

(defvar-local company-fuzzy--recorded-backends nil
  "Record down company local backends in current buffer.")

(defvar-local company-fuzzy--no-valid-prefix-p nil
  "Flag to see if currently completion having a valid prefix.")

(defvar-local company-fuzzy--alist-backends-candidates nil
  "Store list data of '(backend . candidates)'.")

(defvar-local company-fuzzy--plist-history '()
  "Store list data of history data '(backend . candidates)'.")

;;
;; (@* "External" )
;;

(declare-function flx-score "ext:flx.el")

;;
;; (@* "Mode" )
;;

(defun company-fuzzy--enable ()
  "Record down all other backend to `company-fuzzy--backends'."
  (unless company-fuzzy--recorded-backends
    (setq company-fuzzy--recorded-backends company-backends)
    (setq company-fuzzy--backends (company-fuzzy--normalize-backend-list company-fuzzy--recorded-backends))
    (setq-local company-backends '(company-fuzzy-all-other-backends))
    (setq-local company-transformers (append company-transformers '(company-fuzzy--sort-candidates)))
    (advice-add 'company-fill-propertize :around #'company-fuzzy--company-fill-propertize)
    (advice-add 'company--insert-candidate :before #'company-fuzzy--insert-candidate)))

(defun company-fuzzy--disable ()
  "Revert all other backend back to `company-backends'."
  (when company-fuzzy--recorded-backends
    (setq-local company-backends company-fuzzy--recorded-backends)
    (setq company-fuzzy--recorded-backends nil)
    (setq company-fuzzy--backends nil)
    (setq-local company-transformers (delq 'company-fuzzy--sort-candidates company-transformers))
    (advice-remove 'company-fill-propertize #'company-fuzzy--company-fill-propertize)
    (advice-remove 'company--insert-candidate #'company-fuzzy--insert-candidate)))

;;;###autoload
(define-minor-mode company-fuzzy-mode
  "Minor mode 'company-fuzzy-mode'."
  :lighter " ComFuz"
  :group company-fuzzy
  (if company-fuzzy-mode (company-fuzzy--enable) (company-fuzzy--disable)))

(defun company-fuzzy-turn-on-company-fuzzy-mode ()
  "Turn on the 'company-fuzzy-mode'."
  (company-fuzzy-mode 1))

;;;###autoload
(define-globalized-minor-mode global-company-fuzzy-mode
  company-fuzzy-mode company-fuzzy-turn-on-company-fuzzy-mode
  :group 'company-fuzzy
  :require 'company-fuzzy)

;;
;; (@* "Utilies" )
;;

(defun company-fuzzy--valid-candidates-p (candidates)
  "Return non-nil if CANDIDATES is list of valid candidates."
  (ignore-errors (stringp (nth 0 candidates))))

(defun company-fuzzy--symbol-start ()
  "Return symbol start point from current cursor position."
  (ignore-errors
    (save-excursion
      (forward-char -1)
      (re-search-backward company-fuzzy-completion-separator)
      (point))))

(defun company-fuzzy--generic-prefix ()
  "Return the most generic prefix."
  (let ((start (company-fuzzy--symbol-start)))
    (ignore-errors
      (string-trim (substring (buffer-string) (1- start) (1- (point)))))))

(defun company-fuzzy--trigger-prefix-p ()
  "Check if current prefix a trigger prefix."
  (company-fuzzy--is-contain-list-string company-fuzzy-trigger-symbols
                                         company-fuzzy--prefix))

(defun company-fuzzy--string-match-p (regexp string &optional start)
  "Safe way to execute function `string-match-p'.
See function `string-match-p' for arguments REGEXP, STRING and START."
  (or (ignore-errors (string-match-p regexp string start))
      (ignore-errors (string-match-p (regexp-quote regexp) string start))))

(defun company-fuzzy--is-contain-list-string (in-list in-str)
  "Check if a string IN-STR contain in any string in the string list IN-LIST."
  (cl-some #'(lambda (lb-sub-str) (string= lb-sub-str in-str)) in-list))

(defun company-fuzzy--is-contain-list-symbol (in-list in-symbol)
  "Check if a symbol IN-SYMBOL contain in any symbol in the symbol list IN-LIST."
  (cl-some #'(lambda (lb-sub-symbol) (equal lb-sub-symbol in-symbol)) in-list))

(defun company-fuzzy--normalize-backend-list (backends)
  "Normalize all BACKENDS as list."
  (let ((result-lst '()))
    (dolist (backend backends)
      (if (listp backend)
          (let ((index 0))
            (dolist (back backend)
              (when (company-fuzzy--string-match-p "company-" (symbol-name back))
                (push (nth index backend) result-lst))
              (setq index (1+ index))))
        (push backend result-lst)))
    (setq result-lst (reverse result-lst))
    (cl-remove-duplicates result-lst)))

(defun company-fuzzy--call-backend (backend command key)
  "Safely call BACKEND by COMMAND and KEY."
  (ignore-errors (funcall backend command key)))

(defun company-fuzzy--get-backend-by-candidate (candidate)
  "Return the backend symbol by using CANDIDATE as search index."
  (let ((index 0) break-it result-backend)
    (while (and (not break-it) (< index (length company-fuzzy--alist-backends-candidates)))
      (let* ((backend-data (nth index company-fuzzy--alist-backends-candidates))
             (backend (car backend-data))
             (candidates (cdr backend-data)))
        (when (company-fuzzy--is-contain-list-string candidates candidate)
          (setq result-backend backend)
          (setq break-it t)))
      (setq index (1+ index)))
    result-backend))

;;
;; (@* "Documentation" )
;;

(defun company-fuzzy--doc-as-buffer (candidate)
  "Provide doc by CANDIDATE."
  (let ((backend (company-fuzzy--get-backend-by-candidate candidate)))
    (if (or (string-empty-p candidate) (not backend))
        nil
      (company-fuzzy--call-backend backend 'doc-buffer candidate))))

;;
;; (@* "Annotation" )
;;

(defun company-fuzzy--get-backend-string (backend)
  "Get BACKEND's as a string."
  (if backend (s-replace "company-" "" (symbol-name backend)) ""))

(defun company-fuzzy--backend-string (candidate backend)
  "Form the BACKEND string by CANDIDATE."
  (if (and company-fuzzy-show-annotation candidate)
      (let ((backend-str (company-fuzzy--get-backend-string backend)))
        (when (string-empty-p backend-str) (setq backend-str "unknown"))
        (format company-fuzzy-annotation-format backend-str))
    ""))

(defun company-fuzzy--source-anno-string (candidate backend)
  "Return the source annotation string by CANDIDATE and BACKEND."
  (if (and candidate backend)
      (company-fuzzy--call-backend backend 'annotation candidate)
    ""))

(defun company-fuzzy--extract-annotation (candidate)
  "Extract annotation from CANDIDATE."
  (let* ((backend (company-fuzzy--get-backend-by-candidate candidate))
         (backend-str (company-fuzzy--backend-string candidate backend))
         (orig-anno (company-fuzzy--source-anno-string candidate backend)))
    (concat orig-anno backend-str)))

;;
;; (@* "Highlighting" )
;;

(defun company-fuzzy--company-fill-propertize (fnc &rest args)
  "Highlight the matching characters with original function FNC, and rest ARGS."
  (if company-fuzzy-mode
      (let* ((line (apply fnc args))
             (cur-selection (nth company-selection company-candidates))
             (splitted-section (remove "" (split-string line " ")))
             (process-selection (nth 0 splitted-section))
             (selected (string= cur-selection process-selection))
             (selected-face (if selected
                                'company-tooltip-common-selection
                              'company-tooltip-common))
             (selected-common-face (if selected
                                       'company-tooltip-selection
                                     'company-tooltip))
             (splitted-c (remove "" (split-string company-fuzzy--prefix "")))
             (right-pt (+ (length process-selection) company-tooltip-margin)))
        (font-lock-prepend-text-property 0 right-pt 'face selected-common-face line)
        (dolist (c splitted-c)
          (let ((pos (company-fuzzy--string-match-p (regexp-quote c) line)))
            (while (and (numberp pos) (< pos right-pt))
              (font-lock-prepend-text-property pos (1+ pos) 'face selected-face line)
              (setq pos (company-fuzzy--string-match-p (regexp-quote c) line (1+ pos))))))
        line)
    (apply fnc args)))

;;
;; (@* "Sorting / Scoring" )
;;

(defun company-fuzzy--sort-by-length (candidates)
  "Sort CANDIDATES by length."
  (sort candidates (lambda (str1 str2) (< (length str1) (length str2)))))

(defun company-fuzzy--sort-prefix-on-top (candidates)
  "Sort CANDIDATES that match prefix on top of all other selection."
  (let ((prefix-matches '())
        (check-match-str company-fuzzy--prefix))
    (while (and (= (length prefix-matches) 0) (not (= (length check-match-str) 1)))
      (dolist (cand candidates)
        (when (string-prefix-p check-match-str cand)
          (push cand prefix-matches)
          (setq candidates (remove cand candidates))))
      (setq check-match-str (substring check-match-str 0 (1- (length check-match-str)))))
    (setq prefix-matches (sort prefix-matches #'string-lessp))
    (setq candidates (append prefix-matches candidates)))
  candidates)

(defun company-fuzzy--sort-candidates (candidates)
  "Sort all CANDIDATES base on type of sorting backend."
  (setq candidates (company-fuzzy--alist-all-candidates))  ; Get all candidates here.
  (unless company-fuzzy--no-valid-prefix-p
    (cl-case company-fuzzy-sorting-backend
      (none candidates)
      (alphabetic (setq candidates (sort candidates #'string-lessp)))
      (flx
       (require 'flx)
       (let ((scoring-table (make-hash-table)) (scoring-keys '())
             (plst-data (company-fuzzy--alist-map)))
         (dolist (cand candidates)
           (let* ((backend (plist-get plst-data cand))
                  (prefix (company-fuzzy--backend-prefix-match backend))
                  (scoring (flx-score cand prefix))
                  (score (if scoring (nth 0 scoring) 0)))
             (when scoring
               ;; For first time access score with hash-table.
               (unless (gethash score scoring-table) (setf (gethash score scoring-table) '()))
               ;; Push the candidate with the target score to hash-table.
               (push cand (gethash score scoring-table)))))
         ;; Get all keys, and turn into a list.
         (maphash (lambda (score-key _cand-lst) (push score-key scoring-keys)) scoring-table)
         (setq scoring-keys (sort scoring-keys #'>))  ; Sort keys in order.
         (setq candidates '())  ; Clean up, and ready for final output.
         (dolist (key scoring-keys)
           (let ((cands (gethash key scoring-table)))
             (setq cands (company-fuzzy--sort-by-length cands))  ; sort by length once.
             (when (functionp company-fuzzy-sorting-score-function)
               (setq cands (funcall company-fuzzy-sorting-score-function cands)))
             (setq candidates (append candidates cands)))))))
    (when company-fuzzy-prefix-on-top
      (setq candidates (company-fuzzy--sort-prefix-on-top candidates)))
    (when (functionp company-fuzzy-sorting-function)
      (setq candidates (funcall company-fuzzy-sorting-function candidates))))
  candidates)

;;
;; (@* "Completion" )
;;

(defun company-fuzzy--insert-candidate (candidate)
  "Insertion for CANDIDATE."
  ;; NOTE: Here we force to change `company-prefix' so the completion
  ;; will do what we expected.
  (let ((backend (company-fuzzy--get-backend-by-candidate candidate)))
    (setq company-prefix (company-fuzzy--backend-prefix-complete backend))))

;;
;; (@* "Prefix" )
;;

(defun company-fuzzy--backend-prefix-complete (backend)
  "Return prefix for each BACKEND while doing completion.

This function is use when function `company-fuzzy--insert-candidate' is
called.  It returns the current selection prefix to prevent completion
completes in an odd way."
  (cl-case backend
    (company-files (company-files 'prefix))
    (t (company-fuzzy--backend-prefix-match backend))))

(defun company-fuzzy--backend-prefix-match (backend)
  "Return prefix for each BACKEND while matching candidates.

This function is use for scoring and matching algorithm.  It returns a prefix
that best describe the current possible candidate.

For instance, if there is a candidate function `buffer-file-name' and with
current prefix `bfn'.  It will just return `bfn' because the current prefix
does best describe the for this candidate."
  (cl-case backend
    (company-capf (thing-at-point 'symbol))
    (company-files
     ;; NOTE: For `company-files', we will return the last section of the path
     ;; for the best match.
     ;;
     ;; Example, if I have path `/path/to/dir'; then it shall return `dir'.
     (let ((prefix (company-files 'prefix)))
       (when prefix
         (let* ((splitted (split-string prefix "/" t))
                (len-splitted (length splitted))
                (last (nth (1- len-splitted) splitted)))
           last))))
    (t company-fuzzy--prefix)))

(defun company-fuzzy--backend-prefix-get (backend)
  "Return prefix for each BACKEND while getting candidates.

This function is use for simplify prefix, in order to get as much candidates
as possible for fuzzy work.

For instance, if I have prefix `bfn'; then most BACKEND will not return
function `buffer-file-name' as candidate.  But with this function will use a
letter `b' instead of full prefix `bfn'.  So the BACKEND will return something
that may be relavent to the first character `b'.

P.S. Not all backend work this way."
  (cl-case backend
    (company-files
     (let ((prefix (company-files 'prefix)))
       (when prefix
         (let* ((splitted (split-string prefix "/" t))
                (len-splitted (length splitted))
                (last (nth (1- len-splitted) splitted))
                (new-prefix prefix))
           (when (< 1 len-splitted)
             (setq new-prefix
                   (substring prefix 0 (- (length prefix) (length last)))))
           new-prefix))))
    (company-yasnippet "")
    (t (ignore-errors (substring company-fuzzy--prefix 0 1)))))

;;
;; (@* "Fuzzy Matching" )
;;

(defun company-fuzzy--trim-trailing-re (regex)
  "Trim incomplete REGEX.
If REGEX ends with \\|, trim it, since then it matches an empty string."
  (if (string-match "\\`\\(.*\\)[\\]|\\'" regex) (match-string 1 regex) regex))

(defun company-fuzzy--regex-fuzzy (str)
  "Build a regex sequence from STR.
Insert .* between each char."
  (setq str (company-fuzzy--trim-trailing-re str))
  (if (string-match "\\`\\(\\^?\\)\\(.*?\\)\\(\\$?\\)\\'" str)
      (concat (match-string 1 str)
              (let ((lst (string-to-list (match-string 2 str))))
                (apply #'concat
                       (cl-mapcar
                        #'concat
                        (cons "" (cdr (mapcar (lambda (c) (format "[^%c\n]*" c))
                                              lst)))
                        (mapcar (lambda (x) (format "\\(%s\\)" (regexp-quote (char-to-string x))))
                                lst))))
              (match-string 3 str))
    str))

(defun company-fuzzy--match-string (prefix candidates)
  "Return new CANDIDATES that match PREFIX."
  (let ((new-cands '()) (fuz-str (company-fuzzy--regex-fuzzy prefix)))
    (dolist (cand candidates)
      (when (string-match-p fuz-str cand)
        (push cand new-cands)))
    new-cands))

;;
;; (@* "Core" )
;;

(defun company-fuzzy--alist-all-candidates ()
  "Return all candidates from a list."
  (let ((all-candidates '()) cands)
    (dolist (backend-data company-fuzzy--alist-backends-candidates)
      (setq cands (cdr backend-data) all-candidates (append all-candidates cands)))
    (delete-dups all-candidates)))

(defun company-fuzzy--alist-map ()
  "Map `company-fuzzy--alist-backends-candidates'; and return property list \
of (candidate . backend) data with no duplication."
  (let ((plst '()) backend cands)
    (dolist (backend-data company-fuzzy--alist-backends-candidates)
      (setq backend (car backend-data) cands (cdr backend-data))
      (dolist (cand cands) (setq plst (plist-put plst cand backend))))
    plst))

(defun company-fuzzy-all-candidates ()
  "Return the list of all candidates."
  (setq company-fuzzy--alist-backends-candidates '()  ; Clean up.
        company-fuzzy--no-valid-prefix-p (company-fuzzy--trigger-prefix-p))
  (let (temp-candidates prefix-get prefix-com)
    (dolist (backend company-fuzzy--backends)
      (setq prefix-get (company-fuzzy--backend-prefix-get backend)
            prefix-com (company-fuzzy--backend-prefix-complete backend))
      (when prefix-get
        (setq temp-candidates (company-fuzzy--call-backend backend 'candidates prefix-get))
        ;; NOTE: Do the very basic filtering for speed up.
        ;;
        ;; The function `company-fuzzy--match-string' does the very first
        ;; basic filtering in order to lower the performance before sending
        ;; to function `flx-score'.
        (when (and (not company-fuzzy--no-valid-prefix-p) prefix-com)
          (setq temp-candidates (company-fuzzy--match-string prefix-com temp-candidates))))
      ;; NOTE: History work.
      ;;
      ;; Here we check if BACKEND a history type of backend. And if it does; then
      ;; it will ensure considering the history candidates to the new candidates.
      (when (company-fuzzy--is-contain-list-symbol company-fuzzy-history-backends backend)
        (let ((cands-history (plist-get company-fuzzy--plist-history backend)))
          (setq temp-candidates (append cands-history temp-candidates))
          (delete-dups temp-candidates)
          (setq company-fuzzy--plist-history
                (plist-put company-fuzzy--plist-history backend temp-candidates))))
      ;; NOTE: Made the final completion.
      ;;
      ;; This is the final ensure step before processing it to scoring phase.
      ;; We confirm candidates by adding it to `company-fuzzy--alist-backends-candidates'.
      ;; The function `company-fuzzy--valid-candidates-p' is use to ensure the
      ;; candidates returns a list of strings, which this is the current only valid
      ;; type to this package.
      (when (company-fuzzy--valid-candidates-p temp-candidates)
        (delete-dups temp-candidates)
        (push (cons backend (copy-sequence temp-candidates))
              company-fuzzy--alist-backends-candidates)))
    (setq company-fuzzy--alist-backends-candidates (reverse company-fuzzy--alist-backends-candidates))
    nil))

(defun company-fuzzy--get-prefix ()
  "Set the prefix just right before completion."
  (setq company-fuzzy--no-valid-prefix-p nil
        company-fuzzy--prefix (or (ignore-errors (company-fuzzy--generic-prefix))
                                  (ffap-file-at-point))))

(defun company-fuzzy-all-other-backends (command &optional arg &rest ignored)
  "Backend source for all other backend except this backend, COMMAND, ARG, IGNORED."
  (interactive (list 'interactive))
  (cl-case command
    (interactive (company-begin-backend 'company-fuzzy-all-other-backends))
    (prefix (company-fuzzy--get-prefix))
    (annotation (company-fuzzy--extract-annotation arg))
    (candidates (company-fuzzy-all-candidates))
    (doc-buffer (company-fuzzy--doc-as-buffer arg))))

(provide 'company-fuzzy)
;;; company-fuzzy.el ends here
