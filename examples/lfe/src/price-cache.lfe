;;; A price cache that can't keep up. Each update takes 5 ms, so it handles
;;; about 200 a second, while a producer casts 25,000 a second: the cache's
;;; mailbox grows without bound, and anything that calls it waits behind it.

(defmodule price-cache
  (behaviour gen_server)
  (export (start 0) (start_link 0) (update 2) (prices 0))
  (export (init 1) (handle_call 3) (handle_cast 2)))

;; Start the cache and its producer.
(defun start ()
  (let (((tuple 'ok _) (start_link)))
    (spawn (lambda () (produce 0)))
    'ok))

(defun start_link ()
  (gen_server:start_link #(local price-cache) (MODULE) (map) '()))

(defun update (sku price)
  (gen_server:cast (MODULE) (tuple 'update sku price)))

(defun prices ()
  (gen_server:call (MODULE) 'prices))

(defun init (prices)
  (tuple 'ok prices))

(defun handle_call (('prices _from prices)
  (tuple 'reply prices prices)))

(defun handle_cast
  (((tuple 'update sku price) prices)
   ;; The bug: slow work for every message, with nothing slowing the sender.
   (timer:sleep 5)
   (tuple 'noreply (maps:put sku price prices))))

;; Fire-and-forget casts, about 25,000 a second (a pause every 100).
(defun produce (n)
  (update (rem n 1000) n)
  (if (== (rem n 100) 0) (timer:sleep 4))
  (produce (+ n 1)))
