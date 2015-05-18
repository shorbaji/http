(module http-request
    (make-request request-authority request-pseudo-headers request-all-headers request-headers
		  make-request-with-headers-and-body)

  (import chicken scheme)
  (use srfi-1 data-structures defstruct)

  (defstruct request
    method host port path
    (scheme "http")
    (headers '())
    (body ""))

  (define (request-authority req)
    (conc (request-host req)
	  (if (request-port req)
	      (conc ":" (request-port req))
	      "")))
  
  (define (request-pseudo-headers req)
    `((:method . ,(conc (request-method req)))
      (:scheme . ,(request-scheme req))
      (:path . ,(request-path req))
      (:authority . ,(request-authority req))))

  (define (request-all-headers req)
    (append (request-pseudo-headers req)
	    (request-headers req)))

  (define (make-request-with-headers-and-body h b)
    (let* ((m (alist-ref ':method h))
	   (p (alist-ref ':path h))
	   (a (alist-ref ':authority h))
	   (s (alist-ref ':scheme h))
	   (h (fold alist-delete h '(:method :path :authority :scheme))))
      (make-request method: m
		    scheme: s
		    authority: a
		    path: p
		    headers: h
		    body: b))))
