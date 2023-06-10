(defsystem "lem-mailbox"
  :depends-on (:bordeaux-threads :bt-semaphore
	       :queues :queues.simple-cqueue)
  :serial t
  :components ((:file "package")
	       #+abcl
	       (:file "atomic")
	       (:file "lem-mailbox")))
