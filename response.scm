(module http-response
    (make-response response-status response-headers response-body make-response-with-headers-and-body response-all-headers)

  (import chicken scheme)
  (use srfi-1 defstruct data-structures)
  
  (defstruct response status (headers '()) body request)

  (define (response-all-headers res)
    (cons `(:status . ,(->string (response-status res)))
	  (response-headers res)))

  (define (make-response-with-headers-and-body headers body)
    (make-response status: (alist-ref ':status headers)
		   headers: (alist-delete ':status headers)
		   body: body)))
