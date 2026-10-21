;;; Up to 15 restarts in 10 seconds: lenient enough that the gateway's
;;; crash loop, about one restart a second, never makes it give up.

(defmodule payments-sup
  (behaviour supervisor)
  (export (start_link 0) (init 1)))

(defun start_link ()
  (supervisor:start_link #(local payments-sup) (MODULE) '()))

(defun init (_args)
  (let ((flags (map 'strategy 'one_for_one 'intensity 15 'period 10))
        (children
         (list (map 'id 'payments-ledger 'start #(payments-ledger start_link ()))
               (map 'id 'payments-gateway 'start #(payments-gateway start_link ())))))
    (tuple 'ok (tuple flags children))))
