;;; elforth.el --- Do you have what it takes to hack Emacs Lisp in Forth? -*- lexical-binding: t -*-

;; Copyright 2021 Lassi Kortela
;; SPDX-License-Identifier: ISC

;; Author: Lassi Kortela <lassi@lassi.io>
;; URL: https://github.com/lassik/elforth
;; Package-Requires: ((emacs "26.1"))
;; Version: 0.1.0
;; Keywords: games

;; This file is not part of GNU Emacs.

;;; Commentary:

;; It's well established that Real Programmers use Emacs, and equally
;; well known that the determined Real Programmer can write Forth in
;; any language.  This package is the logical conclusion.  Those who
;; know what is right and true are now liberated to program the One
;; True Editor in the One True Language.

;; "Party like it's " 1970 number-to-string concat "!" concat
;; M-x elforth-eval-region

;;; Code:

(require 'cl-lib)

(defvar elforth-read-expression-history '()
  "History of ElForth expressions read from the minibuffer.")

(defvar elforth-stack '()
  "Holds the ElForth data stack. First value is top of stack.")

(defvar elforth-dictionary '()
  "Holds the definitions of ElForth words.

A word is a 3-element list:
- a lambda taking iargs and returning a list of oargs.
- list of iarg names as symbols
- list of oarg names as symbols")

(defvar elforth-variables '()
  "Values of the one-letter variables a..z for ElForth.")

(defun elforth--show-list (interactive-p list repr)
  (prog1 list
    (when interactive-p
      (message "%s"
               (if (null list) "Empty"
                 (with-temp-buffer
                   (let ((item (car list)))
                     (insert (funcall repr item)))
                   (dolist (item (cdr list))
                     (insert " " (funcall repr item)))
                   (buffer-string)))))))

(defun elforth-show-variables (interactive-p)
  "Show the contents of the ElForth variables a..z in the echo area."
  (interactive (list t))
  (elforth--show-list interactive-p elforth-variables
                      (lambda (pair)
                        (let ((variable (car pair)) (value (cdr pair)))
                          (format "%S=%S" variable value)))))

(defun elforth-show-stack (interactive-p)
  "Show the contents of the ElForth stack in the echo area."
  (interactive (list t))
  (elforth--show-list interactive-p (reverse elforth-stack)
                      (lambda (obj) (format "%S" obj))))

(defun elforth-clear-stack ()
  (interactive)
  (setq elforth-stack '())
  (elforth-show-stack (called-interactively-p 'interactive)))

(defun elforth-push (value)
  (setq elforth-stack (cons value elforth-stack)))

(defun elforth-push-many (values)
  (setq elforth-stack (append (reverse values) elforth-stack)))

(defun elforth-pop-many (n)
  (let ((n (max 0 n)))
    (cond ((> n (length elforth-stack))
           (error "The stack does not have %d values" n))
          (t
           (let ((values (reverse (cl-subseq elforth-stack 0 n))))
             (setq elforth-stack (cl-subseq elforth-stack n))
             values)))))

(defun elforth--alist-upsert (alist name value)
  (cons (cons name value)
        (cl-remove-if (lambda (entry) (eq name (car entry)))
                      alist)))

(defun elforth-only-variable-p (variable)
  (and (symbolp variable)
       (let ((name (symbol-name variable)))
         (and (= 1 (length name))
              (<= ?a (elt name 0) ?z)))))

(defun elforth-fetch (variable)
  (cond ((not (symbolp variable))
         (error "Trying to fetch non-symbol: %S" variable))
        ((elforth-only-variable-p variable)
         (cdr (or (assq variable elforth-variables)
                  (error "No such variable: %S" variable))))
        ((not (boundp variable))
         (error "No such variable: %S" variable))
        (t
         (elforth-push (symbol-value variable)))))

(defun elforth-store (variable value)
  (if (elforth-only-variable-p variable)
      (setq elforth-variables
            (sort (elforth--alist-upsert elforth-variables variable value)
                  (lambda (a b) (string< (car a) (car b)))))
    (setf (symbol-value variable) value))
  value)

(defun elforth--resolve-function (func)
  (or (and (symbolp func)
           (cdr (assq func elforth-dictionary)))
      (and (functionp func)
           (let* ((arity (func-arity func))
                  (max-args (cdr arity)))
             (cond ((eq 'many max-args)
                    func)
                   ((and (integerp max-args) (>= max-args 0))
                    func)
                   (t
                    (error "Trying to apply special form: %S" func)))))
      (error "No such function: %S" func)))

(defun elforth--rfunc-min-args (func)
  (if (functionp func)
      (let* ((arity (func-arity func))
             (min-args (car arity))
             (max-args (cdr arity)))
        (if (and (= 0 min-args) (eq 'many max-args))
            2
          min-args))
    (let ((iargs (elt func 1)))
      (length iargs))))

(defun elforth--rfunc-too-many-args-p (func n)
  (if (functionp func)
      (let ((max-args (cdr (func-arity func))))
        (and (integerp max-args) (> n max-args)))))

(defun elforth--rfunc-apply (func args)
  (if (functionp func)
      (list (apply func args))
    (let ((lam (elt func 0)))
      (apply lam args))))

(defun elforth-apply (func args)
  (let ((func (elforth--resolve-function func))
        (n (length args)))
    (cond ((< n (elforth--rfunc-min-args func))
           (error "Too few arguments"))
          ((elforth--rfunc-too-many-args-p func n)
           (error "Too many arguments"))
          (t
           (elforth-push-many (elforth--rfunc-apply func args))))))

(defun elforth-execute (func)
  (let* ((func (elforth--resolve-function func))
         (args (elforth-pop-many (elforth--rfunc-min-args func))))
    (elforth-push-many (elforth--rfunc-apply func args))))

(defun elforth--define (name definition)
  (cl-assert (symbolp name))
  (setq elforth-dictionary
        (elforth--alist-upsert elforth-dictionary name definition))
  name)

(defmacro define-elforth-word (name stack-effect &rest body)
  (let ((iargs '())
        (oargs '()))
    (let ((tail stack-effect) (had-dashes-p nil))
      (while tail
        (let ((arg (car tail)))
          (cond ((and had-dashes-p (eq '-- arg))
                 (error "Bad stack effect: %S" stack-effect))
                ((eq '-- arg)
                 (setq had-dashes-p t))
                ((symbolp arg)
                 (if (not had-dashes-p)
                     (setq iargs (nconc iargs (list arg)))
                   (setq oargs (nconc oargs (list arg)))))
                (t (error "Bad argument: %S" arg))))
        (setq tail (cdr tail))))
    (let* ((io-args
            (cl-remove-if (lambda (arg) (not (member arg oargs)))
                          iargs))
           (o-only-args
            (cl-remove-if (lambda (arg) (member arg io-args))
                          oargs)))
      `(elforth--define
        ',name
        (list (lambda ,iargs
                (let ,o-only-args
                  (progn ,@body)
                  (list ,@oargs)))
              ',iargs
              ',oargs)))))

(define-elforth-word apply (list func --)
  (elforth-apply func list))

(define-elforth-word execute (func --)
  (elforth-execute func))

(define-elforth-word @ (variable -- value)
  (setq value (elforth-fetch variable)))

(define-elforth-word ! (value variable --)
  (elforth-store variable value))

(define-elforth-word dup (a -- a a))
(define-elforth-word drop (_a --))
(define-elforth-word swap (a b -- b a))
(define-elforth-word rot (x a b -- a b x))
(define-elforth-word clear (--) (elforth-clear-stack))
(define-elforth-word 2list (-- list) (setq list (elforth-pop-many 2)))
(define-elforth-word nlist (n -- list) (setq list (elforth-pop-many n)))
(define-elforth-word unlist (list --) (elforth-push-many list))

(defun elforth-read-from-string (string)
  "Read list of ElForth words from STRING."
  (with-temp-buffer
    (insert string)
    (goto-char (point-min))
    (let ((words '()))
      (condition-case _ (while t (push (read (current-buffer)) words))
        (end-of-file (nreverse words))))))

(defun elforth-read-expression (prompt)
  "Read list of ElForth words from the minibuffer using PROMPT."
  (let ((minibuffer-completing-symbol t))
    (minibuffer-with-setup-hook
        (lambda ()
          (add-hook 'completion-at-point-functions
                    #'elisp-completion-at-point nil t)
          (run-hooks 'eval-expression-minibuffer-setup-hook))
      (read-from-minibuffer prompt nil
                            read-expression-map
                            'elforth-read-from-string
                            'read-expression-history))))

;;;###autoload
(defun elforth-eval-expression (list)
  "Evaluate LIST as ElForth words."
  (interactive (list (elforth-read-expression "ElForth eval: ")))
  (dolist (word list)
    (cond ((and (consp word)
                (= 2 (length word))
                (eq 'quote (elt word 0)))
           (let ((word (elt word 1)))
             (unless (symbolp word)
               (error "Execution token is not a symbol: %S" word))
             (elforth-push word)))
          ((and (symbolp word) (not (elforth-only-variable-p word)))
           (elforth-execute word))
          (t
           (elforth-push word)))))

(defun elforth-eval-string (string)
  "Read STRING as ElForth code and evaluate it."
  (elforth-eval-expression (elforth-read-from-string string))
  (elforth-show-stack (called-interactively-p 'interactive)))

;;;###autoload
(defun elforth-eval-region (start end)
  "Read text between START and END as ElForth code and evaluate it."
  (interactive "r")
  (elforth-eval-string (buffer-substring-no-properties start end))
  (elforth-show-stack (called-interactively-p 'interactive)))

(provide 'elforth)

;;; elforth.el ends here
