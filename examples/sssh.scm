#!/usr/bin/guile \
--debug -e main
!#

;;; sssh.scm -- Scheme Secure Shell.

;; Copyright (C) 2013 Artyom V. Poptsov <poptsov.artyom@gmail.com>
;;
;; This program is free software: you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see
;; <http://www.gnu.org/licenses/>.


;;; Commentary:

;; This program is aimed to demonstrate some features of Guile-SSH
;; library.  See https://github.com/artyom-poptsov/libguile-ssh


;;; Code:

(use-modules (ice-9 getopt-long)
             (ice-9 rdelim)
             (ssh channel)
             (ssh session)
             (ssh auth)
             (ssh key)
             (ssh version))


;;; Variables and constants

(define *program-name* "sssh")
(define *default-identity-file*
  (string-append (getenv "HOME") "/.ssh/id_rsa"))

(define debug? #f)


;; Command line options
(define *option-spec*
  '((user          (single-char #\u) (value #t))
    (port          (single-char #\p) (value #t))
    (identity-file (single-char #\i) (value #t))
    (help          (single-char #\h) (value #f))
    (version       (single-char #\v) (value #f))
    (debug         (single-char #\d) (value #f))
    (ssh-debug                       (value #f))))


;;; Helper procedures

(define (handle-error session)
  "Handle a SSH error."
  (display (get-error session))
  (newline)
  (exit 1))

(define (print-debug msg)
  "Print debug information"
  (if debug?
      (display msg)))

(define (format-debug fmt . args)
  "Format a debug message."
  (if debug?
      (format #t fmt args)))

;;; Printing of various information


(define (print-version)
  "Print information about versions."
  (format #t "libssh version:       ~a~%" (get-libssh-version))
  (format #t "libguile-ssh version: ~a~%" (get-library-version)))


(define (print-help)
  "Print information about program usage."
  (display
   (string-append
    *program-name* " -- Scheme Secure Shell\n"
    "Copyright (C) Artyom Poptsov <poptsov.artyom@gmail.com>\n"
    "Licensed under GNU GPLv3+\n"
    "\n"
    "Usage: " *program-name* " [ -upidv ] <host> <command>\n"
    "\n"
    "Options:\n"
    "  --user=<user>, -u <user>                User name\n"
    "  --port=<port-number>, -p <port-number>  Port number\n"
    "  --identity-file=<file>, -i <file>       Path to private key\n"
    "  --debug, -d                             Debug mode\n"
    "  --ssh-debug                             Debug libssh\n"
    "  --version, -v                           Print version\n")))


;;; Entry point of the program

(define (main args)

  (if (null? (cdr args))
      (begin
        (print-help)
        (exit 0)))

  (let* ((options           (getopt-long args *option-spec*))
         (user              (option-ref options 'user (getenv "USER")))
         (port              (string->number (option-ref options 'port "22")))
         (identity-file     (option-ref options 'identity-file
                                        *default-identity-file*))
         (debug-needed?     (option-ref options 'debug #f))
         (ssh-debug-needed? (option-ref options 'ssh-debug #f))
         (help-needed?      (option-ref options 'help #f))
         (version-needed?   (option-ref options 'version #f))
         (args              (option-ref options '() #f)))

    (set! debug? debug-needed?)

    (if help-needed?
        (begin
          (print-help)
          (exit 0)))

    (if version-needed?
        (begin
          (print-version)
          (exit 0)))

    (if (or (null? args) (null? (cdr args)))
        (begin
          (print-help)
          (exit 0)))

    (let ((host (car args))
          (cmd  (cadr args)))

      (print-debug "1. make-session (ssh_new)\n")
      (let ((session (make-session #:user user
                                   #:host host
                                   #:port port
                                   #:log-verbosity (if ssh-debug-needed? 4 0))))

        (print-debug "3. connect! (ssh_connect_x)\n")
        (connect! session)

        (format-debug "   Available authentication methods: ~a~%"
                      (userauth-get-list session))

        (print-debug "4. authenticate-server (ssh_is_server_known)\n")
        (case (authenticate-server session)
          ((ok)        (print-debug "   ok\n"))
          ((not-known) (display "   The server is unknown.  Please check MD5.\n")))

        (format-debug "   MD5 hash: ~a~%" (get-public-key-hash session))

        (display
         (string-append
          "Enter a passphrase for the private key\n"
          "(left it blank if the key does not protected with passphrase):\n"))
        (display "> ")
        (let* ((passphrase (read-line))
               (private-key (private-key-from-file session identity-file passphrase)))

          (if (not private-key)
              (handle-error session))

          (let ((public-key (private-key->public-key private-key)))

            (format-debug "   Key: ~a~%" (public-key->string public-key))

            (if (not public-key)
                (handle-error session))

            (print-debug "5. userauth-pubkey! (ssh_userauth_pubkey)\n")
            (let ((res (userauth-pubkey! session #f public-key private-key)))
              (display res)
            (if (eqv? res 'error)
                (handle-error session)))))

        (print-debug "6. make-channel (ssh_channel_new)\n")
        (let ((channel (make-channel session)))

          (format-debug "   channel: ~a~%" channel)

          (if (not channel)
              (handle-error session))

          (print-debug "7. channel-open-session (ssh_channel_open_session)\n")
          (catch #t
            (lambda () (channel-open-session channel))
            (lambda (key . args)
              (display args)
              (newline)))

          (format-debug "   channel: ~a~%" channel)

          (print-debug "8. channel-request-exec (ssh_channel_request_exec)\n")
          (channel-request-exec channel cmd)

          (print-debug "9. channel-poll (ssh_channel_poll)\n")
          (let poll ((count #f))
            (if (or (not count) (zero? count))
                (poll (channel-poll channel #f))
                (begin
                  (print-debug "10. channel-read (ssh_channel_read)\n")
                  (let ((result (channel-read channel count #f)))
                    (if (not result)
                        (handle-error session)
                        (begin
                          (display result)
                          (newline))))))))))))

;;; sssh.scm ends here
