;;; sample.el --- An example.

(defvar sample-count 0
  "How many times it ran.")

(defun sample-greet (name)
  "Say hello to NAME."
  (interactive "sName: ")
  (setq sample-count (1+ sample-count))
  (message "Hello, %s" name))

(provide 'sample)
