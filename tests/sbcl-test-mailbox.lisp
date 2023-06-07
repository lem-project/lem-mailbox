(defpackage :lem-tests/lem-mailbox
  (:use :cl :rove :lem-mailbox))

(in-package :lem-tests/lem-mailbox)
;;TODO: Fix the prefix of mailbox for tests

(deftest mailbox-trivia.1
  (ok (lem-mailbox::mailboxp (lem-mailbox::make-mailbox)))
  (ok (not (lem-mailbox::mailboxp 42))))


(deftest mailbox-trivia.2
  (let ((mbox1 (lem-mailbox::make-mailbox :name "foof"))
	(mbox2 (lem-mailbox::make-mailbox)))
    (ok (string= "foof" (lem-mailbox::mailbox-name mbox1)))
    (ok (not (lem-mailbox::mailbox-name mbox2)))))


(deftest mailbox-trivia.3
  (flet ((test (initial-contents)
	   (let ((mbox (lem-mailbox::make-mailbox :initial-contents initial-contents)))
	     (list (lem-mailbox::mailbox-count mbox)
		   (lem-mailbox::mailbox-empty-p mbox)
		   (lem-mailbox::list-mailbox-messages mbox)
		   (eq (lem-mailbox::list-mailbox-messages mbox) initial-contents)))))
    (ok (equal '(3 nil (1 2 3) nil) (test '(1 2 3))))
    (ok (equal '(3 nil (1 2 3) nil) (test #(1 2 3))))
    (ok (equal '(3 nil (#\1 #\2 #\3) nil) (test "123")))
    (ok '(0 t nil t) (test nil))))


#+bordeaux-threads
(deftest mailbox-timeouts
  (let* ((mbox (lem-mailbox::make-mailbox))
	 (writers (loop for i from 1 upto 20
			collect (bt:make-thread
				 (lambda ()
				   (loop repeat 50
					 do (lem-mailbox::send-message mbox i)
					    (sleep 0))))))
	 (readers (loop repeat 10
			collect (bt:make-thread
				 (lambda ()
				   (loop while (lem-mailbox::receive-message mbox :timeout 0.5)
					 count t))))))
    (mapc #'bt:join-thread writers)
    (ok (= 1000
	   (apply #'+ (mapcar #'bt:join-thread readers))))))


(defparameter +timeout+ 3000.0)

(defun make-threads (n name fn)
  (loop for i from 1 to n
        collect (bt:make-thread fn :name (format nil "~A-~D" name i))))

(defun test-join-thread (thread)
  (ignore-errors (bt:join-thread thread)))

(defun kill-thread (thread)
  (when (bt:thread-alive-p thread)
    (ignore-errors
     (bt:destroy-thread thread))))

(defun receiver-distribution (n-receivers)
  (let* ((aux              (floor n-receivers 2))
	 (n-recv-msg       (- n-receivers aux))
	 (n-recv-pend-msgs (floor aux 3))
	 (n-recv-msg-n-h   (- aux n-recv-pend-msgs)))
    (values n-recv-msg
	    n-recv-msg-n-h
	    n-recv-pend-msgs)))

(defstruct counter
  (ref 0 :type sb-vm:word))

(defun test-mailbox-producers-consumers
    (&key n-senders n-receivers n-messages interruptor)
  (let ((mbox    (make-mailbox))
	(counter (make-counter))
	(+sleep+  0.0001)
	(+fin-token+ :finish) ; end token for receivers to stop
	(+blksize+ 5))        ; "block size" for RECEIVE-PENDING-MESSAGES
    (multiple-value-bind (n-recv-msg
			  n-recv-msg-n-h
			  n-recv-pend-msgs)
	;; We have three groups of receivers, one using
	;; RECEIVE-MESSAGE, one RECEIVE-MESSAGE-NO-HANG, and
	;; another one RECEIVE-PENDING-MESSAGES.
	(receiver-distribution n-receivers)
      (let ((senders
	      (make-threads n-senders "SENDER"
			    #'(lambda ()
				(dotimes (i n-messages t)
				  (send-message mbox i)
				  (sleep (random +sleep+))))))
	    (receivers
	      (flet ((process-msg (msg out)
		       (cond
			 ((eq msg +fin-token+)
			  (funcall out t))
			 ((not (< -1 msg n-messages))
			  (funcall out nil))
			 (t
			  (sb-ext:atomic-incf (counter-ref counter))))))
		(append
		 (make-threads n-recv-msg "RECV-MSG"
			       #'(lambda ()
				   (sleep (random +sleep+))
				   (loop (process-msg (receive-message mbox)
						      #'(lambda (x) (return x))))))
		 (make-threads n-recv-pend-msgs "RECV-PEND-MSGS"
			       #'(lambda ()
				   (loop
				     (sleep (random +sleep+))
				     (mapc #'(lambda (msg)
					       (process-msg msg #'(lambda (x) (return x))))
					   (receive-pending-messages mbox +blksize+)))))
		 (make-threads n-recv-msg-n-h "RECV-MSG-NO-HANG"
			       #'(lambda ()
				   (loop
				     (sleep (random +sleep+))
				     (multiple-value-bind (msg ok)
					 (receive-message-no-hang mbox)
				       (when ok
					 (process-msg msg #'(lambda (x)
							      (return x))))))))))))

	(when interruptor
	  (funcall interruptor (append receivers senders)))
	(let ((garbage  0))
	  (flet ((wait-for (threads)
		   (mapc #'(lambda (thread)
			     (test-join-thread thread))
			 threads)))
	    ;; First wait until all messages are propagating.
	    (wait-for senders)
	    ;; Senders are finished, inform and wait for the
	    ;; receivers.
	    (loop repeat (+ n-recv-msg
			    n-recv-msg-n-h
			    (* n-recv-pend-msgs +blksize+))
		  ;; The number computed above is an upper bound; if
		  ;; we send as many FINs as that, we can be sure that
		  ;; every receiver must have got at least one FIN.
		  do (send-message mbox +fin-token+))
	    (wait-for receivers)
	    ;; We may in fact have sent too many FINs, so make sure
	    ;; it's only FINs in the mailbox now.
	    (mapc #'(lambda (msg) (unless (eq msg +fin-token+)
				    (incf garbage)))
		  (list-mailbox-messages mbox))
	    `(:received . ,(counter-ref counter))))))))

(defparameter *cpus* 2)

(deftest mailbox.single-producer-single-consumer
  (ok (equal '(:received . 1000)
	     (test-mailbox-producers-consumers :n-senders 1
					       :n-receivers 1
					       :n-messages 1000))))

(deftest mailbox.single-producer-multiple-consumers
  (ok (equal '(:received . 1000)
	     (test-mailbox-producers-consumers :n-senders 1
					       :n-receivers (if (> *cpus* 1) 100 50)
					       :n-messages 1000))))

(deftest mailbox.multiple-producers-single-consumer
  (ok (equal '(:received . 1000)
	     (test-mailbox-producers-consumers :n-senders 10
					       :n-receivers 1
					       :n-messages 100))))

(deftest mailbox.multiple-producers-multiple-consumers
  (ok (equal '(:received . 50000)
	     (test-mailbox-producers-consumers :n-senders 50
					       :n-receivers 50
					       :n-messages 1000))))

(deftest mailbox.interrupts-safety.1
  (let ((received (test-mailbox-producers-consumers
		   :n-senders 50
		   :n-receivers 50
		   :n-messages 1000
		   :interruptor #'(lambda (threads &aux (n (length threads)))
				    ;; 99 so even in the unlikely case that only
				    ;; receivers (or only senders) are shot
				    ;; dead, there's still one that survives to
				    ;; properly end the test.
				    (loop for victim = (nth (random n) threads)
					  repeat 99
					  do (kill-thread victim)
					     (sleep (random 0.0001)))))))
    ;; We may have killed a receiver before it got to incrementing
    ;; the counter.
    (if (<= (cdr received) 1000000)
	(setf received '(:received . :ok))
	received)
    (ok (equal '(:received . :ok)
	       received))))
