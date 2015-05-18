;;server
(use tcp-server)
(use openssl)

(define (make-http-server-handler handler)
  ;; todo - run each request handler as a seperate thread (use mutexes on write-response)
  (lambda (conn id req)
	     (http-connection-write-response
	      conn
	      id
	      (handler req))))

(define (make-http-server handler)
  (lambda (ignore)
    (let* ((l (ssl-listen* hostname: "127.0.0.1"
			   port: 8000
			   protocol: 'tlsv12
			   certificate: "server.pem"
			   private-key: "server.key"
			   private-key-type: 'ec)))
      (let lp ()
	(receive (in out)
	    (ssl-accept l)
	  (thread-start!
	   (make-thread
	    (lambda ()
	      (current-input-port in)
	      (current-output-port out)
	      (http-connection-listen (make-http-server-connection)
				      (make-http-server-handler handler))))))
	
	(lp)))))
