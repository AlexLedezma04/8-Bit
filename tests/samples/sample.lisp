#| A block
comment. |#
(defpackage :sample (:use :cl))
(in-package :sample)

;; Factorial.
(defun fact (n)
  (if (<= n 1)
      1
      (* n (fact (- n 1)))))

(format t "~a~%" (list (fact 5) t nil))
