;;; A healthy sibling of the gateway.

(defmodule payments-ledger
  (behaviour gen_server)
  (export (start_link 0))
  (export (init 1) (handle_call 3) (handle_cast 2)))

(defun start_link ()
  (gen_server:start_link #(local payments-ledger) (MODULE) (map) '()))

(defun init (entries)
  (tuple 'ok entries))

(defun handle_call (('entries _from entries)
  (tuple 'reply entries entries)))

(defun handle_cast ((_message entries)
  (tuple 'noreply entries)))
