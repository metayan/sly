(defpackage :slynk-stickers
  (:use :cl)
  (:import-from :slynk-backend :slynk-compile-string)
  (:import-from :slynk :defslyfun :with-buffer-syntax :compile-string-for-emacs)
  (:export #:record
           #:compile-for-stickers
           #:kill-stickers
           #:inspect-sticker-values
           #:fetch-and-forget))
(in-package :slynk-stickers)

(defclass recording ()
  ((ctime :initform (common-lisp:get-universal-time) :accessor ctime-of)
   (sticker :initform (error "required") :initarg :sticker :accessor sticker-of)
   (values :initform (error "required") :initarg :values :accessor values-of)
   (condition :initarg :condition :accessor condition-of)))

(defmethod initialize-instance :after ((x recording) &key sticker)
  (push x (new-recordings-of sticker))
  (vector-push-extend x *recordings*))

(defun describe-recording (recording &optional stream print-first-value)
  (let ((values (values-of recording))
        (condition (condition-of recording)))
    (cond (condition
           (format stream "exited non-locally with: ~a" (slynk::to-line condition)))
          ((eq values 'exited-non-locally)
           (format stream "exited non-locally"))
          ((listp values)
           (if (and print-first-value
                    (car values))
               (format stream "~a" (slynk::to-line (car values)))
               (format stream "~a values" (length values))))
          (t
           (format stream "corrupt recording")))))

(defmethod print-object ((r recording) s)
  (print-unreadable-object (r s :type t)
    (describe-recording r s)))

(defclass sticker ()
  ((id :initform (error "required")  :initarg :id :accessor id-of)
   (new-recordings :initform nil :accessor new-recordings-of)))

(defmethod print-object ((sticker sticker) s)
  (print-unreadable-object (sticker s :type t)
    (format s "~a new recordings" (length (new-recordings-of sticker)))))

(defun exited-non-locally-p (recording)
  (when (or (condition-of recording)
            (eq (values-of recording) 'exited-non-locally))
    t))


;; FIXME: This won't work for multiple-connections. A channel, or some
;; connection specific structure, is needed for that.
;;
(defvar *stickers* (make-hash-table))
(defvar *recordings* (make-array 40 :fill-pointer 0 :adjustable t))
(defvar *visitor* nil)

(defslyfun compile-for-stickers (new-stickers
                                 dead-stickers
                                 instrumented-string
                                 original-string
                                 buffer
                                 position
                                 filename
                                 policy)
  "Considering NEW-STICKERS, compile INSTRUMENTED-STRING.
INSTRUMENTED-STRING is exerpted from BUFFER at POSITION. BUFFER may be
associated with FILENAME. DEAD-STICKERS if any, are killed. If
compilation succeeds, return a list (NOTES T).

If ORIGINAL-STRING, if non-nil, is compiled as a fallback if the
previous compilation. In this case a list (NOTES NIL) is returned or
an error is signalled.

If ORIGINAL-STRING is not supplied and compilation of
INSTRUMENTED-STRING fails, return NIL."
  ;; Dead stickers are unconditionally removed from *stickers*
  ;; 
  (kill-stickers dead-stickers)
  (let ((probe
          (handler-case
              (compile-string-for-emacs instrumented-string
                                        buffer
                                        position
                                        filename
                                        policy)
            (error () nil))))
    (cond (;; a non-nil and successful compilation result
           (and probe
                (third probe))
           (loop for id in new-stickers
                 do (setf (gethash id *stickers*)
                          (make-instance 'sticker :id id)))
           (list probe t))
          (original-string
           (list (compile-string-for-emacs original-string buffer position filename policy)
                 nil)))))

(defslyfun kill-stickers (ids)
  (loop for id in ids
        do (remhash id *stickers*)))

(defun call-with-sticker-recording (id fn)
  (let* ((sticker (gethash id *stickers*))
         (values 'exited-non-locally)
         (last-condition))
    (unwind-protect
         (handler-bind ((condition (lambda (condition)
                                     (setq last-condition condition))))
           (setq values (multiple-value-list (funcall fn)))
           (values-list values))
      (when sticker
        (make-instance 'recording
          :sticker sticker
          :values values
          :condition (and (eq values 'exited-non-locally) last-condition))))))

(defmacro record (id &rest body)
  `(call-with-sticker-recording ,id (lambda () ,@body)))

(defun next-index-and-recording (ignore-list)
  (loop for candidate-index = (incf (cdr *visitor*))
        for recording = (and (< candidate-index (length *recordings*))
                             (aref *recordings* candidate-index))
        while recording
        unless (member (id-of (sticker-of recording))
                       ignore-list)
          return (values candidate-index recording)))

(defslyfun visit-next (key ignore-list)
  (unless (and *visitor*
               (eq key (car *visitor*)))
    (setf *visitor* (cons key -1)))
  (multiple-value-bind (index recording)
      (next-index-and-recording ignore-list)
    (setf (cdr *visitor*) index)
    (cond (recording
           (list index
                 (id-of (sticker-of recording))
                 (length *recordings*)
                 (describe-recording recording nil 'print-first-value)))
          (t
           nil))))

(defslyfun fetch-and-forget ()
  (prog1 (fetch) (forget)))

(defslyfun fetch ()
  (loop for k being the hash-keys of *stickers*
        for sticker being the hash-values of *stickers*
        for new-recordings = (new-recordings-of sticker)
        for most-recent-recording = (car (last new-recordings))
        collect (list k
                      (length new-recordings)
                      (and most-recent-recording
                           (describe-recording most-recent-recording nil 'print-first-value))
                      (and most-recent-recording
                           (exited-non-locally-p most-recent-recording)))))

(defslyfun forget ()
  (maphash (lambda (id sticker)
             (declare (ignore id))
             (setf (new-recordings-of sticker) nil))
           *stickers*)
  (setf (fill-pointer *recordings*) 0))


(defun find-sticker-or-lose (id)
  (let ((probe (gethash id *stickers* :unknown)))
    (if (eq probe :unknown)
        (error "Cannot find sticker ~a" id)
        probe)))

(defslyfun inspect-sticker-values (id)
  (let ((sticker (find-sticker-or-lose id)))
    (slynk::inspect-object sticker)))

(provide 'slynk-stickers)