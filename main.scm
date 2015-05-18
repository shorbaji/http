;; driver
(define (handler req)
  (make-response status: 200
		 body: (with-output-to-string
			 (lambda ()
			   (display (request-pseudo-headers req))))))

((make-http-server handler) #t)
