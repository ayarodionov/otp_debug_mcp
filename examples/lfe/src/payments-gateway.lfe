;;; Connects to the payment provider a second after it starts, parsing the
;;; port from its URL. The URL is malformed, so it crashes every time, and
;;; its supervisor restarts it, about once a second.

(defmodule payments-gateway
  (behaviour gen_server)
  (export (start_link 0))
  (export (init 1) (handle_call 3) (handle_cast 2) (handle_info 2)))

(defun start_link ()
  (gen_server:start_link #(local payments-gateway) (MODULE) '() '()))

(defun init (_args)
  (erlang:send_after 1000 (self) 'connect)
  (tuple 'ok (map 'url (os:getenv "GATEWAY_URL" "https://pay.example.com:443x/v2"))))

(defun handle_call ((_request _from state)
  (tuple 'reply 'ok state)))

(defun handle_cast ((_message state)
  (tuple 'noreply state)))

(defun handle_info
  (('connect (= (map 'url url) state))
   (let* ((after-colon (lists:last (string:split url ":" 'all)))
          ((list port _path) (string:split after-colon "/")))
     ;; The bug: "443x" isn't a port, so list_to_integer/1 raises badarg.
     (tuple 'noreply (maps:put 'port (list_to_integer port) state)))))
