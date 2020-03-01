;; -*- lisp -*-

;; this file is part of stmx.
;; copyright (c) 2013-2016 Massimiliano Ghilardi
;;
;; this library is free software: you can redistribute it and/or
;; modify it under the terms of the lisp lesser general public license
;; (http://opensource.franz.com/preamble.html), known as the llgpl.
;;
;; this library is distributed in the hope that it will be useful,
;; but without any warranty; without even the implied warranty
;; of merchantability or fitness for a particular purpose.
;; see the lisp lesser general public license for more details.


(in-package :stmx)


(enable-#?-syntax)

;;;; ** global clock - exact, atomic counter for transaction validation:
;;;; used to ensure transactional read consistency.

(eval-always

(defconstant +global-clock-delta+ 2
  "+global-clock+ VERSION is incremented by 2 each time: the lowest bit
is reserved as \"locked\" flag in TVARs versioning - used if TVAR-LOCK
feature is equal to :BIT.")


(defconstant +global-clock-nohw-delta+ 2
  "+global-clock+ NOHW-COUNTER incremented by 2 each time: the lowest bit
is reserved as \"prevent HW transactions\"")


;;;; ** definitions common to more than one global-clock implementation

(deftype gv156/version-type () 'atomic-counter-num)

(defstruct (gv156 (:include atomic-counter))
  (nohw-counter 0 :type atomic-counter-slot-type)
  (nohw-flag    0 :type bit)
  ;; padding to put {hw,sw}-{commits,aborts} in a different cache line.
  ;; Assumes cache line size = 64 bytes, i.e. 8 slots on 64-bit archs
  (pad1 0) (pad2 0) (pad3 0)
  (pad4 0) (pad5 0) (pad6 0)
  (pad7 0)
  (commits 0 :type fixnum)
  (aborts  0 :type fixnum))

(defstruct lv156
  (commits 0 :type fixnum)
  (aborts  0 :type fixnum))

(defmethod make-load-form ((obj gv156) &optional environment)
  (declare (ignore environment))
  `(make-gv156))




(declaim (type fixnum +gv-max-stat+))
(defconstant +gv-max-stat+ 512)



(declaim (type gv156 +gv+))
(define-constant-once +gv+ (make-gv156))


(declaim (type lv156 *lv*))
(defparameter *lv* (make-lv156))
(eval-always
 (ensure-thread-initial-binding '*lv* '(make-lv156)))

(defmacro %gv-nohw-flag  () `(gv156-nohw-flag  +gv+))


(eval-always
  (let1 stmx-package (find-package 'stmx)
    (defun %gvx-expand0-f (prefix suffix)
      (declare (type symbol prefix suffix))
      (intern (concatenate 'string
                           (symbol-name prefix)
                           "/"
                           (symbol-name suffix))
              stmx-package)))

  (defun %gv-expand0-f (name)
    (declare (type symbol name))
    (%gvx-expand0-f (stmx.lang::get-feature 'global-clock) name)))


(defmacro %gvx-expand (gvx name &rest args)
  (declare (type symbol gvx name))
  (let ((full-name (%gvx-expand0-f gvx name)))
    `(,full-name ,@args)))

(defmacro %gv-expand (name &rest args)
  (declare (type symbol name))
  (let ((full-name (%gv-expand0-f name)))
    `(,full-name ,@args)))


(defmacro gvx-add-missing (gvx)
  (let1 newline (make-string 1 :initial-element (code-char 10))
    `(progn
       ,@(loop for suffix in '(get-nohw-counter incf-nohw-counter decf-nohw-counter
                               stat-committed stat-aborted)
            for name = (%gvx-expand0-f gvx suffix)
            unless (fboundp name)
            collect
              `(defmacro ,name ()
                 ,(concatenate 'string "This is " (symbol-name gvx) " implementation of "
                               (symbol-name name) "." newline "It does nothing and returns zero.")
                 '0))


       ;; if any macro GV<X>/{HW,SW}/{START-READ,START-WRITE,WRITE,AFTER-ABORT,
       ;; STAT-COMMITTED,STAT-ABORTED} is missing, define it from the generic version
       ;; without {HW,SW}/
       ,@(let ((macros nil))
           (loop for infix in '(hw sw) do
                (loop for (suffix . args) in '((start-read) (start-write write-version)
                                               (write write-version) (after-abort)
                                               (stat-committed) (stat-aborted))
                   for infix+suffix = (%gvx-expand0-f infix suffix)
                   for name = (%gvx-expand0-f gvx infix+suffix)
                   for fallback-name = (%gvx-expand0-f gvx suffix)
                   unless (fboundp name)
                   do
                     (push
                      `(defmacro ,name (,@args)
                         ,(concatenate 'string "This is " (symbol-name gvx)
                                       " implementation of GLOBAL-CLOCK/" (symbol-name infix+suffix)
                                       "." newline "Calls " (symbol-name fallback-name) ".")
                         (list ',fallback-name ,@args))
                      macros)))
           macros))))







;;;; ** This is global-clock version GV1

(deftype gv1/version-type () 'gv156/version-type)

(defmacro gv1/features ()
  "This is GV1 implementation of GLOBAL-CLOCK/FEATURES.

Return nil, i.e. not '(:suitable-for-hw-transactions) because
\(GV1/START-WRITE ...) increments the global clock, which causes conflicts
and aborts when multiple hardware transactions are running simultaneously."
  'nil)


(defmacro gv1/start-read ()
  "This is GV1 implementation of GLOBAL-CLOCK/START-READ.
Return the current +gv+ value."
  `(get-atomic-counter +gv+))


(defmacro gv1/valid-read? (tvar-version read-version)
  "This is GV1 implementation of GLOBAL-CLOCK/VALID-READ?
Return (<= tvar-version read-version)"
  `(<= (the gv1/version-type ,tvar-version)
       (the gv1/version-type ,read-version)))


(defmacro gv1/start-write (read-version)
  "This is GV1 implementation of GLOBAL-CLOCK/START-WRITE.
Atomically increment +gv+ and return its new value."
  (declare (ignore read-version))

  `(incf-atomic-counter +gv+ +global-clock-delta+))


(defmacro gv1/write (write-version)
  "This is GV1 implementation of GLOBAL-CLOCK/WRITE.
Return WRITE-VERSION."
  write-version)


(defmacro gv1/after-abort ()
  "This is GV1 implementation of GLOBAL-CLOCK/AFTER-ABORT.
Return the current +gv+ value."
  `(gv1/start-read))


;; define stub macros (GV5/STAT-COMMITTED) (GV5/STAT-ABORTED)
;; (GV1/GET-NOHW-COUNTER) (GV1/INCF-NOHW-COUNTER) and (GV1/DECF-NOHW-COUNTER)
(eval-always
  (gvx-add-missing gv1))






;;;; ** This is global-clock version GV5

(deftype gv5/version-type () 'gv156/version-type)

(defmacro gv5/features ()
  "This is GV5 implementation of GLOBAL-CLOCK/FEATURES.

Return '(:SUITABLE-FOR-HW-TRANSACTIONS :SPURIOUS-FAILURES-IN-SINGLE-THREAD)
because the global clock is incremented only by GV5/AFTER-ABORT, which avoids
incrementing it in GV5/START-WRITE (it would cause hardware transactions
to conflict with each other and abort) but also causes a 50% abort rate (!) even
in a single, isolated thread reading and writing its own transactional memory."

 ''(:suitable-for-hw-transactions :spurious-failures-in-single-thread))


(defmacro gv5/start-read ()
  "This is GV5 implementation of GLOBAL-CLOCK/START-READ.
Return the current +gv+ value."
  `(get-atomic-counter +gv+))


(defmacro gv5/valid-read? (tvar-version read-version)
  "This is GV5 implementation of GLOBAL-CLOCK/VALID-READ?
Return (<= tvar-version read-version)"
  `(<= (the gv5/version-type ,tvar-version)
       (the gv5/version-type ,read-version)))


(defmacro gv5/start-write (read-version)
  "This is GV5 implementation of GLOBAL-CLOCK/START-WRITE.
Return (1+ +gv+) without incrementing it."
  (declare (ignore read-version))

  `(get-atomic-counter-plus-delta +gv+ +global-clock-delta+))


(defmacro gv5/write (write-version)
  "This is GV5 implementation of GLOBAL-CLOCK/{HW,SW}/WRITE.
Return WRITE-VERSION."
  write-version)

(defmacro gv5/after-abort ()
  "This is GV5 implementation of GLOBAL-CLOCK/AFTER-ABORT.
Increment +gv+ and return its new value."
  `(incf-atomic-counter +gv+ +global-clock-delta+))


(defmacro gv5/get-nohw-counter ()
  "This is GV5 implementation of GLOBAL-CLOCK/GET-NOHW-COUNTER.
Return the number of software-only transaction commits currently running."
  `(get-atomic-place (gv156-nohw-counter +gv+)
                      #?-fast-atomic-counter (atomic-counter-mutex +gv+)))


(defmacro gv5/incf-nohw-counter (&optional (delta +global-clock-nohw-delta+))
  "This is GV5 implementation of GLOBAL-CLOCK/INCF-NOHW-COUNTER.
Increment by DELTA the slot NOHW-COUNTER of +gv+ and return its new value."
  `(incf-atomic-place (gv156-nohw-counter +gv+) ,delta
                      #?-fast-atomic-counter (atomic-counter-mutex +gv+)))


(defmacro gv5/decf-nohw-counter (&optional (delta +global-clock-nohw-delta+))
  "This is GV5 implementation of GLOBAL-CLOCK/DECF-NOHW-COUNTER.
Decrement by DELTA the slot NOHW-COUNTER of +gv+ and return its new value."
  `(incf-atomic-place (gv156-nohw-counter +gv+) (- ,delta)
                      #?-fast-atomic-counter (atomic-counter-mutex +gv+)))


;; define stub macros (GV5/{HW,SW}/STAT-COMMITTED)
;; and (GV5/{HW,SW}/STAT-ABORTED)
(eval-always
  (gvx-add-missing gv5))







;;;; ** This is global-clock version GV6

(deftype gv6/version-type () 'gv156/version-type)

(defmacro gv6/features ()
  "This is GV6 implementation of GLOBAL-CLOCK/FEATURES.

Return '(:SUITABLE-FOR-HW-TRANSACTIONS :SPURIOUS-FAILURES-IN-SINGLE-THREAD)
just like GV5 because the global clock is based on GV5: it is usually not
incremented by GV6/START-WRITE, to prevent hardware transactions from
conflicting with each other.
This can cause very high abort rates of software transactions, so
GV6 adaptively switches to GV1 algorithm in the following cases:
a) software-only commits are in progress
b) abort rate is very high
in order to try to reduce the abort rates."

  `(gv5/features))


(defmacro gv6/%is-gv5-mode? ()
  "Return T if GV6 is currently in GV5 mode, i.e. it allows HW transactions.
Return NIL if GV6 is currently in GV1 mode, i.e. it forbids HW transactions."
  `(zerop (gv6/get-nohw-counter)))


(defmacro gv6/hw/start-read ()
  "This is GV6 implementation of GLOBAL-CLOCK/HW/START-READ.
Calls (GV5/HW/START-READ), since GV1 mode forbids hardware transactions."
  `(gv5/hw/start-read))


(defmacro gv6/sw/start-read ()
  "This is GV6 implementation of GLOBAL-CLOCK/SW/START-READ.
Calls either (GV5/SW/START-READ) or (GV1/SW/START-READ), depending on the current mode."
  (if (equalp (macroexpand '(gv5/sw/start-read))
              (macroexpand '(gv1/sw/start-read)))
      `(gv5/sw/start-read)
      `(if (gv6/%is-gv5-mode?)
           (gv5/sw/start-read)
           (gv1/sw/start-read))))


(defmacro gv6/valid-read? (tvar-version read-version)
  "This is GV6 implementation of GLOBAL-CLOCK/VALID-READ?
Return (<= tvar-version read-version)"
  `(<= (the gv6/version-type ,tvar-version)
       (the gv6/version-type ,read-version)))


(defmacro gv6/hw/start-write (read-version)
  "This is GV6 implementation of GLOBAL-CLOCK/HW/START-WRITE.
Calls (GV5/HW/START-WRITE), since GV1 mode forbids hardware transactions."
  `(gv5/hw/start-write ,read-version))


(defmacro gv6/sw/start-write (read-version)
  "This is GV6 implementation of GLOBAL-CLOCK/SW/START-WRITE.
Calls either (GV5/START-WRITE) or (GV1/START-WRITE), depending on the current mode."
  (if (equalp (macroexpand `(gv5/sw/start-write ,read-version))
              (macroexpand `(gv1/sw/start-write ,read-version)))
      `(gv5/sw/start-write ,read-version)
      `(if (gv6/%is-gv5-mode?)
           (gv5/sw/start-write ,read-version)
           (gv1/sw/start-write ,read-version))))


(defmacro gv6/hw/write (write-version)
  "This is GV6 implementation of GLOBAL-CLOCK/SW/WRITE.
Calls (GV5/HW/START-WRITE), since GV1 mode forbids hardware transactions."
  (declare (ignorable write-version))
  `(gv5/hw/write ,write-version))


(defmacro gv6/sw/write (write-version)
  "This is GV6 implementation of GLOBAL-CLOCK/HW/WRITE.
Calls either (GV5/SW/WRITE) or (GV1/WRITE), depending on the current mode."
  (if (equalp (macroexpand `(gv5/sw/write ,write-version))
              (macroexpand `(gv1/sw/write ,write-version)))
      `(gv5/sw/write ,write-version)
      `(if (gv6/%is-gv5-mode?)
           (gv5/sw/write ,write-version)
           (gv1/sw/write ,write-version))))


(defmacro gv6/hw/after-abort ()
  "This is GV6 implementation of GLOBAL-CLOCK/HW/AFTER-ABORT.
Calls (GV5/AFTER-ABORT), since GV1 mode forbids hardware transactions."
  `(gv5/hw/after-abort))


(defmacro gv6/sw/after-abort ()
  "This is GV6 implementation of GLOBAL-CLOCK/SW/AFTER-ABORT.
Calls either (GV5/AFTER-ABORT) or (GV1/AFTER-ABORT), depending on the current mode."
  (if (equalp (macroexpand `(gv5/sw/after-abort))
              (macroexpand `(gv1/sw/after-abort)))
      `(gv5/sw/after-abort)
      `(if (gv6/%is-gv5-mode?)
           (gv5/sw/after-abort)
           (gv1/sw/after-abort))))


(defmacro gv6/get-nohw-counter ()
  "This is GV6 implementation of GLOBAL-CLOCK/GET-NOHW-COUNTER.
Return LOGIOR of two quantities:
1. (GV5/GET-NOHW-COUNTER)
2. the global-clock slot NOHW-FLAG"
  `(logior
    (gv5/get-nohw-counter)
    (%gv-nohw-flag)))


(defmacro gv6/incf-nohw-counter (&optional (delta +global-clock-nohw-delta+))
  "This is GV6 implementation of GLOBAL-CLOCK/INCF-NOHW-COUNTER.
Calls (GV5/INCF-NOHW-COUNTER)."
  `(gv5/incf-nohw-counter ,delta))


(defmacro gv6/decf-nohw-counter (&optional (delta +global-clock-nohw-delta+))
  "This is GV6 implementation of GLOBAL-CLOCK/DECF-NOHW-COUNTER.
Calls (GV5/DECF-NOHW-COUNTER)."
  `(gv5/decf-nohw-counter ,delta))


(declaim (inline gv6/%set-gv1-mode gv6/%set-gv5-mode))

(defun gv6/%set-gv1-mode ()
  (setf (%gv-nohw-flag) 1)
  ;; we just switched to GV1 mode, where aborts no longer increase
  ;; GLOBAL-CLOCK version.
  ;; Manually increase GLOBAL-CLOCK version once, otherwise transactions
  ;; may livelock due to some TVAR version > GLOBAL-CLOCK version
  (gv5/sw/after-abort))

(defun gv6/%set-gv5-mode ()
  (setf (%gv-nohw-flag) 0))


(defun gv6/%update-gv-stat (lv)
  (declare (type lv156 lv))

  (let* ((lv-commits  (ash (lv156-commits lv) -6))
         (lv-aborts   (ash (lv156-aborts  lv) -6))

         (gv +gv+)
         (gv-commits (the fixnum (incf (gv156-commits gv) lv-commits)))
         (gv-aborts  (the fixnum (incf (gv156-aborts  gv) lv-aborts))))

    (setf (lv156-commits lv) 0
          (lv156-aborts  lv) 0)

    (when (or (>= gv-commits +gv-max-stat+)
              (>= gv-aborts  +gv-max-stat+))

      (setf (gv156-commits gv) 0
            (gv156-aborts  gv) 0)

      (if (zerop (gv156-nohw-flag gv))
          ;; GV6 is currently allowing HW transactions (GV5 mode).
          ;; If HW commits + SW commits are less than
          ;; (HW aborts / 4) + (5 / 4 * SW aborts),
          ;; then disable HW transactions by switching to GV1 mode.
          (when (< (ash gv-commits -2) gv-aborts)
            (return-from gv6/%update-gv-stat (gv6/%set-gv1-mode)))

          ;; GV6 is currently forbidding HW transactions (GV1 mode)
          ;; due to high abort rates. Always re-enable HW transactions
          ;; after a while, no matter what's the SW success rate.
          (return-from gv6/%update-gv-stat (gv6/%set-gv5-mode))))))




(defmacro gv6/%update-lv-stat (which &optional (delta 1))
  (declare (type symbol which))
  (with-gensyms (lv stat)
    `(let* ((,lv *lv*)
            (,stat (the fixnum (incf (the fixnum (,which ,lv)) ,delta))))
       (when (>= ,stat +gv-max-stat+)
         (gv6/%update-gv-stat ,lv)))))


(defmacro gv6/hw/stat-committed ()
  "This is GV6 implementation of GLOBAL-CLOCK/HW/STAT-COMMITTED.
It increases local-clock slot COMMITS and may decide to switch between GV1 and GV5 modes."
  `(gv6/%update-lv-stat lv156-commits))


(defmacro gv6/hw/stat-aborted ()
  "This is GV5 implementation of GLOBAL-CLOCK/HW/STAT-ABORTED.
It increases local-clock slot ABORTS and may decide to switch between GV1 and GV5 modes."
  `(gv6/%update-lv-stat lv156-aborts))


(defmacro gv6/sw/stat-committed ()
  "This is GV6 implementation of GLOBAL-CLOCK/SW/STAT-COMMITTED.
It increases local-clock slot COMMITS and may decide to switch between GV1 and GV5 modes."
  `(gv6/%update-lv-stat lv156-commits))

(defmacro gv6/sw/stat-aborted ()
  "This is GV5 implementation of GLOBAL-CLOCK/SW/STAT-ABORTED.
It increases local-clock slot ABORTS and may decide to switch between GV1 and GV5 modes."
  `(gv6/%update-lv-stat lv156-aborts 5))



(gvx-add-missing gv6)












;;;; ** choose which global-clock implementation to use


(deftype global-clock/version-type () (%gv-expand0-f 'version-type))
(deftype              version-type () (%gv-expand0-f 'version-type))


(defmacro global-clock/features ()
  "Return the features of the GLOBAL-CLOCK algorithm, i.e. a list
containing zero or more of :SUITABLE-FOR-HW-TRANSACTIONS and
:SPURIOUS-FAILURES-IN-SINGLE-THREAD. The list of possible features
will be expanded as more GLOBAL-CLOCK algorithms are implemented."
  `(%gv-expand features))


(defmacro global-clock/hw/start-read ()
  "Return the value to use as hardware transaction \"read version\".

This function must be invoked once upon starting a hardware transaction for the first time.
In case the transaction just aborted and is being re-executed, invoke instead
\(GLOBAL-CLOCK/HW/AFTER-ABORT)."
  `(%gv-expand hw/start-read))


(defmacro global-clock/sw/start-read ()
  "Return the value to use as software transaction \"read version\".

This function must be invoked once upon starting a software transaction for the first time.
In case the transaction just aborted and is being re-executed, invoke instead
\(GLOBAL-CLOCK/SW/AFTER-ABORT)."
  `(%gv-expand sw/start-read))


(defmacro global-clock/valid-read? (tvar-version read-version)
  "Return T if TVAR-VERSION is compatible with transaction \"read version\".
If this function returns NIL, the transaction must be aborted.

During software transactions, this function must be invoked after every
TVAR read and before returning the TVAR value to the application code.
During hardware transactions, this function is not used."
  `(%gv-expand valid-read? ,tvar-version ,read-version))


(defmacro global-clock/hw/start-write (read-version)
  "Return the value to use as hardware transaction \"write version\",
given the transaction current READ-VERSION that was assigned at transaction start.

During hardware transactions - and also during hardware-based commits of software
transactions - this function must be called once before writing the first TVAR."
  `(%gv-expand hw/start-write ,read-version))


(defmacro global-clock/sw/start-write (read-version)
  "Return the value to use as softarw transaction \"write version\", given the
software transaction current READ-VERSION that was assigned at transaction start.

During software-only commits, this function must be called once before
committing the first TVAR write."
  `(%gv-expand sw/start-write ,read-version))


(defmacro global-clock/hw/write (write-version)
  "Return the value to use as TVAR \"write version\", given the hardware
transaction current WRITE-VERSION that was assigned by GLOBAL-CLOCK/HW/START-WRITE
before the transaction started writing to TVARs.

This function must be called for **each** TVAR being written during
hardware-assisted commit phase of software transactions
and during pure hardware transactions."
  `(%gv-expand hw/write ,write-version))


(defmacro global-clock/sw/write (write-version)
  "Return the value to use as TVAR \"write version\", given the software
transaction current WRITE-VERSION that was assigned by GLOBAL-CLOCK/SW/START-WRITE
before the transaction started writing to TVARs.

Fhis function must be called for **each** TVAR being written
during software-only commit phase of software transactions."
  `(%gv-expand sw/write ,write-version))


(defmacro global-clock/hw/after-abort ()
  "Return the value to use as new transaction \"read version\",

This function must be called after a hardware transaction failed/aborted
and before rerunning it."
  `(%gv-expand hw/after-abort))


(defmacro global-clock/sw/after-abort ()
  "Return the value to use as new transaction \"read version\",

This function must be called after a software transaction failed/aborted
and before rerunning it."
  `(%gv-expand sw/after-abort))


(defmacro global-clock/get-nohw-counter ()
  "Return the number of operations currently running that are incompatible with
hardware transactions. Example of operations that AT THE MOMENT are incompatible with
hardware transactions include:
1) software-only transaction commits
2) (retry)

This function must be called at the beginning of each hardware transaction
in order to detect if an incompatible operation is started during the hardware
transaction, and abort the transaction in such case."
  `(%gv-expand get-nohw-counter))


(defmacro global-clock/incf-nohw-counter ()
  "Increment by one the number of operations currently running that are incompatible with
hardware transactions.

This function must be called at the beginning of each software-only transaction commit,
\(retry), or any other operation incompatible with hardware transactions, in order
to abort the latter, since their current implementations are mutually incompatible."
  `(%gv-expand incf-nohw-counter))


(defmacro global-clock/decf-nohw-counter ()
  "Decrement by one the number of software-only transaction commits currently running.

This function must be called at the end of each software-only transaction commit,
\(retry), or any other operation incompatible with hardware transactions, in order
to let the latter run, since their current implementations are mutually incompatible."
  `(%gv-expand decf-nohw-counter))


(defmacro global-clock/hw/stat-committed ()
  `(%gv-expand hw/stat-committed))

(defmacro global-clock/hw/stat-aborted ()
  `(%gv-expand hw/stat-aborted))

(defmacro global-clock/sw/stat-committed ()
  `(%gv-expand sw/stat-committed))

(defmacro global-clock/sw/stat-aborted ()
  `(%gv-expand sw/stat-aborted))






(defun global-clock/publish-features ()
  "Publish (GLOBAL-CLOCK/FEATURES) to stmx.lang::*feature-list*
so they can be tested with #?+ and #?- reader macros."
  (loop for pair in (global-clock/features) do
        (let* ((feature (if (consp pair) (first  pair) pair))
               (value   (if (consp pair) (second pair) t))
               (gv-feature (%gvx-expand0-f 'global-clock feature)))

          (stmx.lang::set-feature gv-feature value))))

(global-clock/publish-features)


) ;; eval-always

