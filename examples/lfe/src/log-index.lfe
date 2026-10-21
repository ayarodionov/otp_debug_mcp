;;; Indexes log records, keeping each 16 KB record's 256-byte header as a
;;; preview. The header is a sub-binary of the record, and a sub-binary
;;; keeps the whole binary it points into alive: the index pins every
;;; record it has seen, about 800 KB a second. (On OTP 28 the runtime copies
;;; slices of 64 bytes or less when it collects garbage, so a short id
;;; wouldn't leak; anything longer does.)

(defmodule log-index
  (behaviour gen_server)
  (export (start 0) (start_link 0) (add 1) (size 0))
  (export (init 1) (handle_call 3) (handle_cast 2)))

;; Start the index and a log source feeding it 50 records a second.
(defun start ()
  (let (((tuple 'ok _) (start_link)))
    (spawn (lambda () (feed 0)))
    'ok))

(defun start_link ()
  (gen_server:start_link #(local log-index) (MODULE) '() '()))

(defun add (record)
  (gen_server:cast (MODULE) (tuple 'record record)))

(defun size ()
  (gen_server:call (MODULE) 'size))

(defun init (headers)
  (tuple 'ok headers))

(defun handle_call (('size _from headers)
  (tuple 'reply (length headers) headers)))

(defun handle_cast
  (((tuple 'record record) headers)
   (let (((binary (header binary (size 256)) (_body binary)) record))
     ;; The bug: `header` points into `record`, so all 16 KB stay in
     ;; memory. (binary:copy header) would keep only the 256 bytes.
     (tuple 'noreply (cons header headers)))))

(defun feed (n)
  (add (binary:copy (binary (n (size 32))) 4096))
  (timer:sleep 20)
  (feed (+ n 1)))
