#| compiler-utils.jl -- 

   $Id$

   Copyright (C) 2000 John Harper <john@dcs.warwick.ac.uk>

   This file is part of librep.

   librep is free software; you can redistribute it and/or modify it
   under the terms of the GNU General Public License as published by
   the Free Software Foundation; either version 2, or (at your option)
   any later version.

   librep is distributed in the hope that it will be useful, but
   WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU General Public License for more details.

   You should have received a copy of the GNU General Public License
   along with librep; see the file COPYING.  If not, write to
   the Free Software Foundation, 675 Mass Ave, Cambridge, MA 02139, USA.
|#

(define-structure compiler-utils (export current-stack max-stack
					 current-b-stack max-b-stack
					 const-env inline-env
					 defuns defvars defines
					 output-stream
					 compiler-message
					 compiler-error
					 compiler-warning
					 remember-function
					 remember-variable
					 remember-lexical-variable
					 test-variable-ref
					 test-variable-bind
					 test-function-call
					 increment-stack
					 decrement-stack
					 increment-b-stack
					 decrement-b-stack
					 get-lambda-vars
					 compiler-constant-p
					 compiler-constant-value
					 constant-function-p
					 constant-function-value
					 note-declaration)
  (open rep
	compiler
	compiler-modules
	compiler-bindings
	compiler-basic
	bytecodes)

  (define current-stack (make-fluid 0))		;current stack requirement
  (define max-stack (make-fluid 0))		;highest possible stack
  (define current-b-stack (make-fluid 0))	;current binding stack req.
  (define max-b-stack (make-fluid 0))		;highest possible binding stack

  (define const-env (make-fluid '()))		;alist of (NAME . CONST-DEF)
  (define inline-env (make-fluid '()))		;alist of (NAME . FUN-VALUE)
  (define defuns (make-fluid '()))		;alist of (NAME REQ OPT RESTP)
					; for all functions/macros in the file
  (define defvars (make-fluid '()))		;all vars declared at top-level
  (define defines (make-fluid '()))		;all lex. vars. at top-level

  (defvar output-stream (make-fluid))	;stream for compiler output


;;; Message output

  (defun compiler-message (fmt &rest args)
    (when (null (fluid output-stream))
      (if (or batch-mode (not (featurep 'jade)))
	  (fluid-set output-stream (stdout-file))
	(fluid-set output-stream (open-buffer "*compilation-output*"))))
    (when (and (featurep 'jade)
	       (bufferp (fluid output-stream))
	       (not (eq (current-buffer) (fluid output-stream))))
      (goto-buffer (fluid output-stream))
      (goto (end-of-buffer)))
    (when (fluid current-fun)
      (format (fluid output-stream) "%s: " (fluid current-fun)))
    (apply format (fluid output-stream) fmt args))

  (put 'compile-error 'error-message "Compilation mishap")
  (defun compiler-error (text &rest data)
    (signal 'compile-error (cons (format nil "%s: %s" (fluid current-fun) text)
				 data)))

  (defun compiler-warning (fmt &rest args)
    (apply compiler-message fmt args)
    (write (fluid output-stream) "\n"))


;;; Code to handle warning tests

  ;; Note that there's a function or macro NAME with lambda-list ARGS
  ;; in the current file
  (defun remember-function (name args)
    (if (assq name (fluid defuns))
	(compiler-warning "Multiply defined function or macro: %s" name)
      (let
	  ((required 0)
	   (optional nil)
	   (rest nil)
	   (state 'required))
	;; Scan the lambda-list for the number of required and optional
	;; arguments, and whether there's a &rest clause
	(while args
	  (if (symbolp args)
	      ;; (foo . bar)
	      (setq rest t)
	    (if (memq (car args) '(&optional &rest &aux))
		(cond
		 ((eq (car args) '&optional)
		  (setq state 'optional)
		  (setq optional 0))
		 ((eq (car args) '&rest)
		  (setq args nil)
		  (setq rest t))
		 ((eq (car args) '&aux)
		  (setq args nil)))
	      (set state (1+ (symbol-value state)))))
	  (setq args (cdr args)))
	(fluid-set defuns (cons (list name required optional rest)
				(fluid defuns))))))

  ;; Similar for variables
  (defun remember-variable (name)
    (cond ((memq name (fluid defines))
	   (compiler-error
	    "Variable %s was previously declared lexically" name))
	  ((memq name (fluid defvars))
	   (compiler-warning "Multiply defined variable: %s" name))
	  (t
	   (fluid-set defvars (cons name (fluid defvars))))))

  (defun remember-lexical-variable (name)
    (cond ((memq name (fluid defvars))
	   (compiler-error "Variable %s was previously declared special" name))
	  ((memq name (fluid defines))
	   (compiler-warning "Multiply defined lexical variable: %s" name))
	  (t
	   (fluid-set defines (cons name (fluid defines))))))

  ;; Test that a reference to variable NAME appears valid
  (defun test-variable-ref (name)
    (when (and (symbolp name)
	       (null (memq name (fluid defvars)))
	       (null (memq name (fluid defines)))
	       (null (memq name (fluid spec-bindings)))
	       (null (assq name (fluid lex-bindings)))
	       (null (assq name (fluid defuns)))
	       (not (special-variable-p name))
	       (not (boundp name))
	       (not (locate-variable name)))
      (compiler-warning "Reference to undeclared free variable: %s" name)))

  ;; Test that binding to variable NAME appears valid
  (defun test-variable-bind (name)
    (cond ((assq name (fluid defuns))
	   (compiler-warning "Binding to %s shadows function" name))
	  ;((memq name (fluid defvars))
	  ; (compiler-warning "Binding to %s shadows special variable" name))
	  ((or (memq name (fluid spec-bindings))
	       (assq name (fluid lex-bindings)))
	   (compiler-warning "Binding to %s shadows earlier binding" name))
	  ((and (boundp name) (functionp (symbol-value name)))
	   (compiler-warning "Binding to %s shadows pre-defined value" name))))

  ;; Test a call to NAME with NARGS arguments
  ;; XXX functions in comp-fun-bindings aren't type-checked
  (defun test-function-call (name nargs)
    (when (symbolp name)
      (catch 'return
	(let
	    ((decl (assq name (fluid defuns))))
	  (when (and (null decl) (or (boundp name)
				     (assq name (fluid inline-env))))
	    (setq decl (or (cdr (assq name (fluid inline-env)))
			   (symbol-value name)))
	    (when (or (subrp decl)
		      (and (closurep decl)
			   (eq (car (closure-function decl)) 'autoload)))
	      (throw 'return))
	    (when (eq (car decl) 'macro)
	      (setq decl (cdr decl)))
	    (when (closurep decl)
	      (setq decl (closure-function decl)))
	    (if (bytecodep decl)
		(remember-function name (aref decl 0))
	      (remember-function name (nth 1 decl)))
	    (setq decl (assq name (fluid defuns))))
	  (if (null decl)
	      (unless (or (memq name (fluid spec-bindings))
			  (assq name (fluid lex-bindings))
			  (memq name (fluid defvars))
			  (memq name (fluid defines))
			  (locate-variable name))
		(compiler-warning "Call to undeclared function: %s" name))
	    (let
		((required (nth 1 decl))
		 (optional (nth 2 decl))
		 (rest (nth 3 decl)))
	      (if (< nargs required)
		  (compiler-warning
		   "%d arguments required by %s; %d supplied"
		   required name nargs)
		(when (and (null rest) (> nargs (+ required (or optional 0))))
		  (compiler-warning
		   "Too many arguments to %s (%d given, %d used)"
		   name nargs (+ required (or optional 0)))))))))))


;;; stack handling

  ;; Increment the current stack size, setting the maximum stack size if
  ;; necessary
  (defmacro increment-stack (&optional n)
    (list 'when (list '> (list 'fluid-set 'current-stack
			       (if n
				   (list '+ '(fluid current-stack) n)
				 (list '1+ '(fluid current-stack))))
			 '(fluid max-stack))
	  '(fluid-set max-stack (fluid current-stack))))

  ;; Decrement the current stack usage
  (defmacro decrement-stack (&optional n)
    (list 'fluid-set 'current-stack 
	  (if n
	      (list '- '(fluid current-stack) n)
	    (list '1- '(fluid current-stack)))))

  (defun increment-b-stack ()
    (fluid-set current-b-stack (1+ (fluid current-b-stack)))
    (when (> (fluid current-b-stack) (fluid max-b-stack))
      (fluid-set max-b-stack (fluid current-b-stack))))

  (defun decrement-b-stack ()
    (fluid-set current-b-stack (1- (fluid current-b-stack))))



  ;; Remove all keywords from a lambda list ARGS, returning the list of
  ;; variables that would be bound (in the order they would be bound)
  (defun get-lambda-vars (args)
    (let
	(vars)
      (while args
	(if (symbolp args)
	    (setq vars (cons args vars))
	  (unless (memq (car args) '(&optional &rest &aux))
	    (setq vars (cons (car args) vars))))
	(setq args (cdr args)))
      (nreverse vars)))


;;; constant forms

;; Return t if FORM is a constant
(defun compiler-constant-p (form)
  (cond
   ((or (integerp form) (stringp form)
	(vectorp form) (bytecodep form)
	(eq form t) (eq form nil)))
   ((consp form)
    (and (eq (car form) 'quote) (compiler-binding-from-rep-p 'quote)))
   ((symbolp form)
    (or (assq form (fluid const-env))
	(compiler-binding-immutable-p form)))
   ;; What other constant forms have I missed..?
   (t
    nil)))

;; If FORM is a constant, return its value
(defun compiler-constant-value (form)
  (cond
   ((or (integerp form) (stringp form)
	(vectorp form) (bytecodep form)
	(eq form t) (eq form nil))
    ;; Self-evaluating types
    form)
   ((consp form)
    ;; only quote
    (nth 1 form))
   ((symbolp form)
    (if (compiler-binding-immutable-p form)
	(compiler-symbol-value form)
      (cdr (assq form (fluid const-env)))))))

(defun constant-function-p (form)
  (setq form (compiler-macroexpand form))
  (and (memq (car form) '(lambda function))
       ;; XXX this is broken
       (compiler-binding-from-rep-p (car form))))

(defun constant-function-value (form)
  (setq form (compiler-macroexpand form))
  (cond ((eq (car form) 'lambda)
	 form)
	((eq (car form) 'function)
	 (nth 1 form))))


;;; declarations

(defun note-declaration (form)
  (mapc (lambda (clause)
	  (let ((handler (get (or (car clause) clause) 'compiler-decl-fun)))
	    (if handler
		(handler clause)
	      (compiler-warning "unknown declaration" clause)))) form))

)