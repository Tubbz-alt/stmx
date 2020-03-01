;; -*- lisp -*-

;; This file is part of STMX.
;; Copyright (c) 2013-2016 Massimiliano Ghilardi
;;
;; This library is free software: you can redistribute it and/or
;; modify it under the terms of the Lisp Lesser General Public License
;; (http://opensource.franz.com/preamble.html), known as the LLGPL.
;;
;; This library is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty
;; of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
;; See the Lisp Lesser General Public License for more details.


(in-package :cl-user)

(defpackage #:stmx.example.dining-philosophers.lock
  (:use #:cl)

  (:import-from #:stmx.lang
                #:eval-always
                #:start-thread #:wait4-thread))


(in-package :stmx.example.dining-philosophers.lock)


;; standard bordeaux-threads lock. for this simple example,
;; they are up to 3 times faster than STMX transactions
#-(and)
(eval-always
 (deftype lock () 't)

 (defmacro make-lock (&optional name)
   `(bt:make-lock ,name))

 (defmacro acquire-lock (lock)
   `(bt:acquire-lock ,lock nil))

 (defmacro release-lock (lock)
   `(bt:release-lock ,lock)))


;; fast locks using atomic compare-and-swap if available.
;; for this simple example, they are up to 10 times faster than STMX transactions
#+(and)
(eval-always
 (deftype lock () 'stmx::mutex)

 (defmacro make-lock (&optional name)
   (declare (ignore name))
   `(stmx.lang::make-mutex))

 (defmacro acquire-lock (lock)
   `(stmx.lang::try-acquire-mutex ,lock))

 (defmacro release-lock (lock)
   `(stmx.lang::release-mutex ,lock)))


(declaim (ftype (function (cons) fixnum) eat-from-plate)
         (inline eat-from-plate))
(defun eat-from-plate (plate)
  "Decrease by one TVAR in plate."
  (declare (type cons plate))
  (decf (the fixnum (car plate))))


(declaim (ftype (function (lock lock cons) fixnum) philosopher-eats)
         (inline philosopher-eats))

(defun philosopher-eats (fork1 fork2 plate)
  "Try to eat once. return remaining hunger"
  (declare (type lock fork1 fork2)
           (type cons plate))

  ;; also keep track of failed lock attempts for demonstration purposes.
  (decf (the fixnum (cdr plate)))

  (let ((hunger -1)) ;; unknown
    (when (acquire-lock fork1)
      (when (acquire-lock fork2)
        (setf hunger (eat-from-plate plate))
        (release-lock fork2))
      (release-lock fork1))

    (when (= -1 hunger)
      (bt:thread-yield))

    hunger))





(defun dining-philosopher (i fork1 fork2 plate)
  "Eat until not hungry anymore."
  (declare (type lock fork1 fork2)
           (type cons plate)
           (type fixnum i))
  ;;(with-output-to-string (out)
  ;;  (let ((*standard-output* out))
  (log:trace "philosopher ~A: fork1=~A fork2=~A plate=~A~%"
             i fork1 fork2 (car plate))
  ;;(sb-sprof:with-profiling
  ;;  (:max-samples 1000 :sample-interval 0.001 :report :graph
  ;;   :loop nil :show-progress t :mode :alloc)

  (loop until (zerop (philosopher-eats fork1 fork2 plate))))


(defun dining-philosophers (philosophers-count &optional (philosophers-initial-hunger 20000000))
  "Prepare the table, sit the philosophers, let them eat.
Note: the default initial hunger is 10 millions,
      i.e. ten times more than the STMX version."
  (declare (type fixnum philosophers-count philosophers-initial-hunger))

  (when (< philosophers-count 1)
    (error "philosophers-count is ~A, expecting at least 1" philosophers-count))

  (let* ((n philosophers-count)
         (nforks (max n 2))
         (forks (loop for i from 1 to nforks collect (make-lock (format nil "~A" i))))
         (plates (loop for i from 1 to n collect
                      (cons philosophers-initial-hunger
                            philosophers-initial-hunger)))
         (philosophers
          (loop for i from 1 to n collect
               (let ((fork1 (nth (1- i)         forks))
                     (fork2 (nth (mod i nforks) forks))
                     (plate (nth (1- i)         plates))
                     (j i))

                 ;; make the last philospher left-handed
                 (when (= i n)
                   (rotatef fork1 fork2))

                 (lambda ()
                   (dining-philosopher j fork1 fork2 plate))))))

    (let* ((start (get-internal-real-time))
           (threads (loop for philosopher in philosophers
                       for i from 1
                       collect (start-thread philosopher
                                             :name (format nil "philosopher ~A" i)))))

      (loop for thread in threads do
           (let ((result (wait4-thread thread)))
             (when result
               (print result))))

      (let* ((end (get-internal-real-time))
             (elapsed-secs (/ (- end start) (float internal-time-units-per-second)))
             (tx-count (/ (* n philosophers-initial-hunger) elapsed-secs))
	     (tx-unit ""))
	(when (>= tx-count 100000)
	  (setf tx-count (/ tx-count 1000000)
		tx-unit " millions"))
        (log:info "~3$~A iterations per second, elapsed time: ~3$ seconds"
		  tx-count tx-unit elapsed-secs))

      (loop for (plate . fails) in plates
	 for i from 1 do
	   (log:debug "philosopher ~A: ~A successful attempts, ~A failed"
		     i (- philosophers-initial-hunger plate) (- fails))))))
