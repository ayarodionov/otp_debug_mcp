(defmodule payments-app
  (behaviour application)
  (export (start 2) (stop 1)))

(defun start (_type _args)
  (payments-sup:start_link))

(defun stop (_state)
  'ok)
