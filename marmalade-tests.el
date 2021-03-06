;;; tests for marmalade  -*- lexical-binding: t -*-

(require 'ert)
(require 'marmalade-service)
(require 'fakir)
(require 's)

(ert-deftest marmalade-package-explode ()
  "Make sure the regex works."
  (let ((file "ascii-3.1.el"))
    (destructuring-bind (name version type)
        (marmalade/explode-package-string file)
      (should (equal name "ascii"))
      (should (equal version "3.1"))
      (should (equal type "el")))))

(ert-deftest marmalade/package-name->filename ()
  "Convert package name to a filename."
  (let ((file "ascii-3.1.el")
        (marmalade-package-store-dir "/packages"))
    (should
     (equal
      (marmalade/package-name->filename file)
      "ascii/3.1/ascii-3.1.el"))))

(ert-deftest marmalade-cache-test ()
  "Test the cache test."
  ;; When the index is not specified
  (let ((marmalade-archive-index-filename nil))
    (flet ((marmalade/package-store-modtime () (current-time)))
      (should (marmalade-cache-test))))
  ;; When they are the same
  (let ((test-time (current-time)))
    (flet ((marmalade/archive-index-exists-p () t)
           (marmalade/archive-index-modtime () test-time)
           (marmalade/package-store-modtime () test-time))
      (should-not (marmalade-cache-test))))
  ;; Store time is earlier
  (let ((test-time (current-time)))
    (flet ((marmalade/archive-index-exists-p () t)
           (marmalade/archive-index-modtime () test-time)
           (marmalade/package-store-modtime ()
             (time-subtract
              test-time
              (seconds-to-time 60))))
      (should-not (marmalade-cache-test))))
  ;; Store time is more recent than archive
  (let ((test-time (current-time)))
    (flet ((marmalade/archive-index-exists-p () t)
           (marmalade/package-store-modtime () test-time)
           (marmalade/archive-index-modtime ()
             (time-subtract
              test-time
              (seconds-to-time 60))))
      (should (marmalade-cache-test)))))

(defun marmalade/make-requires (depends)
  "Make a requires string."
  (if depends
      (let ((s-lex-value-as-lisp t))
        (s-lex-format ";; Package-Requires: ${depends}"))
      ""))

(defun marmalade/make-header (depends version)
  "Make a package header."
  ;; Expects the lex-val and lisp-val functions to have been fletted.
  (let ((requires (marmalade/make-requires depends)))
    (s-lex-format ";; Author: Some Person <person@example.com>
;; Maintainer: Other Person <other@example.com>
;; Version: ${version}
;; URL: http://git.example.com/place
${requires}
;; Keywords: lisp, tools
")))

(defun marmalade/make-test-pkg (name depends desc version commentary)
  "Make contents of a test pakage."
  (let* ((decl (marmalade/make-header depends version))
         (copy ";; Copyright (C) 2013 Some Person")
         (defn
          '(defun dummy-package ()
            (interactive)
            (message "ha")))
         (defn-code (s-lex-format "${defn}\n\n"))
         (prvide '(provide (quote dummy-package)))
         (prvide-code (s-lex-format "${prvide}\n\n")))
    (s-lex-format ";;; ${name}.el --- ${desc}

${copy}

${decl}

;;; Commentary:

${commentary}

;;; Code:

${defn-code}

${prvide-code}
;;; ${name}.el ends here
")))

(defun marmalade/package-requirify (src-list)
  "Transform package depends.

From: ((package-name \"0.1\"))
To ((package-name (0 1))).

This is code that is in `package-buffer-info'."
  (mapcar
   (lambda (elt)
     (list (car elt)
           (version-to-list (car (cdr elt)))))
   src-list))

(defmacro* marmalade/package-file
    (&key (pkg-name "dummy-package")
          pkg-file-name ; can override the filename
          (pkg-desc "a fake package for the marmalade test suite")
          (pkg-depends '((timeclock "2.6.1")))
          (pkg-version "0.0.1")
          (pkg-commentary ";; This doesn't do anything.
;; it's just a fake package for Marmalade.")
          code)
  "Make a fake package file.

Executes the CODE parameter as a body of lisp."
  `(let* ((package-name ,pkg-name)
          (package-desc ,pkg-desc)
          (package-depends (quote ,pkg-depends))
          (package-version ,pkg-version)
          (package-commentary ,pkg-commentary)
          (package-file-name (or ,pkg-file-name package-name))
          (package-content-string
           (marmalade/make-test-pkg
            package-name 
            package-depends
            package-desc
            package-version
            package-commentary))
          (package-file
           (make-fakir-file
            :filename (concat package-file-name ".el")
            :directory "/tmp/"
            :content package-content-string)))
     (fakir-mock-file package-file
       ,code)))

(ert-deftest marmalade/package-info ()
  "Tests for the file handling stuff."
  (marmalade/package-file
   :code
   (should
    (equal
     (marmalade/package-info "/tmp/dummy-package.el")
     (vector
      package-name
      (marmalade/package-requirify package-depends)
      package-desc
      package-version
      (concat ";;; Commentary:\n\n" package-commentary "\n\n")))))
  ;; A tar package
  (should
   (equal
    (marmalade/package-info
     (expand-file-name
      (concat marmalade-dir "elnode-0.9.9.6.9.tar")))
    ["elnode"
     ((web (0 1 4))
      (creole (0 8 14))
      (fakir (0 0 14))
      (db (0 0 5))
      (kv (0 0 15)))
     "The Emacs webserver."
     "0.9.9.6.9" nil])))

(ert-deftest marmalade/package-path ()
  (marmalade/package-file
   :pkg-file-name "test546.el"
   :code
   (should
    (equal
     (let ((marmalade-package-store-dir "/tmp"))
       (marmalade/package-path "/tmp/test546.el"))
     "/tmp/dummy-package/0.0.1/dummy-package-0.0.1.el"))))

(ert-deftest marmalade/temp-file ()
  "Test that we make the temp file in the right way."
  (unwind-protect 
       (flet ((make-temp-name (prefix)
                (concat prefix "2345")))
         (should
          (equal
           (marmalade/temp-file "blah.el")
           "/tmp/marmalade-upload2345.el")))
    (delete-file "/tmp/marmalade-upload2345.el")))

(ert-deftest marmalade/save-package ()
  "Test the save package stuff."
  (let ((marmalade-package-store-dir "/tmp/test-marmalade-dir"))
    (marmalade/package-file
     :code
     (let ((expected
            "/tmp/test-marmalade-dir/dummy-package/0.0.1/dummy-package-0.0.1.el"))
       (should
        (equal
         (marmalade/save-package
          package-content-string
          "dummy-package.el")
         expected))
       (should
        (equal
         (fakir-file-path package-file)
         expected))))))

(ert-deftest marmalade/relativize ()
  (should
   (equal
    (marmalade/relativize "/tmp/blah/blah" "/tmp/")
    "blah/blah"))
  (should
   (equal
    (marmalade/relativize "/tmp/blah/blah/more" "/tmp/")
    "blah/blah/more"))
  (should
   (equal
    (marmalade/relativize "/tmp/blah/blah/more" "/var/")
    nil)))

(ert-deftest marmalade/commentary->about ()
  (should
   (equal
    (marmalade/commentary->about ";;; Commentary:

;; this is a test of the function.

;; It should result in something without colons.")
    "this is a test of the function.

It should result in something without colons.")))

(provide 'marmalade-tests)

;;; marmalade-tests.el ends here
