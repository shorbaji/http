(module http-stream
    (make-stream stream-recv stream-send stream-accepts?)
  (import chicken scheme)
  (use srfi-1 defstruct data-structures)
  (use http-frame)

  (defstruct stream
    (state 'idle)
    (hbls '())
    (db "")
    (local-ws 65535)
    (peer-ws 65535)
    (ec #f))

  (define recv-transition-table
    (map cons
	 '(idle open reserved-local reserved-remote half-closed-remote half-closed-local)
	 '(((push-promise . reserved-remote)  (headers . open))
	   ((end-stream . half-closed-remote)  (rst-stream . closed))
	   ((rst-stream . closed))
	   ((headers . half-closed-local)  (rst-stream . closed))
	   ((rst-stream . closed))
	   ((end-stream . closed)  (rst-stream . closed)))))

  (define send-transition-table
    (map cons
	 '(idle open reserved-local reserved-remote half-closed-remote half-closed-local)
	 '(((push-promise . reserved-local)  (headers . open))
	   ((end-stream . half-closed-local)  (rst-stream . closed))
	   ((headers . half-closed-remote)  (rst-stream . closed))
	   ((rst-stream . closed))
	   ((end-stream . closed)  (rst-stream . closed))
	   ((rst-stream . closed)))))
  
  (define (stream-transition state t table)
    (or (alist-ref t (alist-ref state table))
	state))

  (define (stream-accepts? s t)
    (let* ((state (stream-state s)))
      (member t (case state
		  ((idle)            '(headers push-promise priority))
		  ((reserved-local)  '(priority rst-stream window-update))
		  ((reserved-remote) '(headers rst-stream priority))
		  (else (list t))))))
  
;;; stream-recv
  ;; 
  (define (stream-recv s f handler)
    (let* ((state (stream-state s))
	   (hbls (stream-hbls s))
	   (db (stream-db s))
	   (local-ws (stream-local-ws s))
	   (peer-ws (stream-peer-ws s))
	   (ec (stream-ec s))
	   (t (car f))
	   (id (cadr f)))

      (define (continuation-hbfs)
	(let lp ((b ""))
	  (let* ((f (read-frame))
		 (t (car f))
		 (cid (cadr f)))
	    (if (and (eq? 'continuation t)
		     (eq? cid id))
		(let* ((chbf (caddr f))
		       (ceh (cadddr f)))
		  (if ceh
		      (lp (conc b chbf))
		      (conc b chbf)))))))

      (define (transition tr)
	(set! state (stream-transition state tr recv-transition-table)))
      
      (define (transition-on-es es)
	(if es (transition 'end-stream)))

      (define (stream-error ec)
	(stream-send s `(rst-stream ,id ,ec)))
      
;;;
      (if (or (and (eq? t 'data)
		   (not (member state '(open half-closed-local))))
	      (not (member t (case state
			       ((half-closed-remote) '(window-update priority rst-stream))
			       ((closed) '(priority))
			       (else (list t))))))
	  (stream-error 'stream-closed))
      
      
      (transition t)
      
      (let ((fn (case (car f)
		  ((data)           (lambda (data es)
				      (transition-on-es es)
				      (set! db (conc db data))))
		  ((headers)        (lambda (hbf eh es esdw)
				      (let* ((hb (if eh hbf (conc hbf (continuation-hbfs)))))
					(transition-on-es es)
					(set! hbls (cons hb hbls)))))
		  ((rst-stream)     (lambda (fec)
				      (set! ec fec)))
		  ((priority)       (lambda (e sd w)
				      '()))
		  ((window-update)  (lambda (wsi)
				      (if (zero? wsi) (stream-error 'protocol-error))
				      (set! peer-ws (+ wsi peer-ws))))
		  ((push-promise)   (lambda (-promise psid hbf eh)
				      '())))))
	(apply fn (cddr f)))

      (if (and (member state '(half-closed-remote closed))
	       (or (not ec)
		   (zero? ec)))
	  (handler id hbls db))

      (update-stream s state: state hbls: hbls db: db ec: ec)))

  
;;; stream send

  (define (stream-send s f)
    (let* ((t (car f))
	   (state (stream-state s)))

      (define (transition tr)
	(set! state (stream-transition state tr send-transition-table)))
      
      (define (transition-on-es es)
	(if es (transition 'end-stream)))


      (define (data d es)
	(transition-on-es es))

      (define (headers hbf eh es)
	(transition-on-es es))

      (define (rst-stream ls ec dd)
	'())

      (transition t)      
      (apply (alist-ref t
			`((data . ,data)
			  (headers . ,headers)
			  (rst-stream . ,rst-stream)))
	     (cddr f))
      (update-stream s state: state))))

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
;; TODO
;;
;; Section 3.2   starting HTTP/2 with https
;; logging
;; purchase certificate
;; LAUNCH web site
;; Solve the enforce-tls-profile problem
;; Section 3.1   starting HTTP/2 with HTTP/1.1 Upgrade
;; implement stream-level priority
;; stream clean-up
;; revisit stream errors
;; - decoding/encoding errors => connection error compression error
;;   optional - sender of settings frame does not receive an ack wihtin a reasonable amount of time
;;   connection error settings timeout
;; if connection error don't do window update
;; if stream error do window update
;; - implement change to SETTINGS_INITIAL_WINDOW_SIZE issuing a connection control error if that causes
;;   any flow control window to exceed the maximum size
;; detect and handle thread closure  
;;
;; Section 5.3   stream priority
;; Section 8.3   the CONNECT method
;; Section 10    security
;; Section 5.1.1 stream identifiers
;; Section 5.1.2 implement SETTINGS-MAX-CONCURRENT-STREAMS - section 5.1.2
;; Section 8.1.4 request reliability
;; Section 9     additional considerations
;; The rest of HTTP

;;; 
;;; conn
;;;

(module http2
    (make-http-server-connection http-connection-listen http-connection-write-response)

  (import chicken scheme)

  (use srfi-1 data-structures defstruct extras)
  (use hpack http-frame)
  (import http-response http-request http-stream)
  (reexport http-request http-response)
  (define client-initial-settings
    `((SETTINGS-HEADER-TABLE-SIZE       . 4096)
      (SETTINGS-ENABLE-PUSH             . 1)
      (SETTINGS-MAX-CONCURRENT-STREAMS  . 1024)
      (SETTINGS-INITIAL-WINDOW-SIZE     . 65535)
      (SETTINGS-MAX-FRAME-SIZE          . 16384)
      (SETTINGS-MAX-HEADER-LIST-SIZE    . ,(- (* 16 1024 1024) 1)))) 

  (define server-initial-settings
    `((SETTINGS-HEADER-TABLE-SIZE       . 4096)
      (SETTINGS-MAX-CONCURRENT-STREAMS  . 1024)
      (SETTINGS-INITIAL-WINDOW-SIZE     . 65535)
      (SETTINGS-MAX-FRAME-SIZE          . 16384)
      (SETTINGS-MAX-HEADER-LIST-SIZE    . ,(- (* 16 1024 1024) 1))))

  (defstruct conn mode lsid in out
    local-settings
    peer-settings
    (status 'ready)
    (flow-controller conn-default-flow-controller)
    (decoder (make-header-table)) 
    (encoder (make-header-table)) 
    (active '())
    (ready '())
    (streams '())
    (local-ws 65535)
    (peer-ws 65535))

  (define (conn-default-flow-controller c f)
    (and (eq? (car f) 'data)
	 (let* ((id (cadr f))
		(data (caddr f))
		(wsi (string-length data)))
	   (conn-send c `(window-update 0 ,(string-length (caddr f))))
	   (if (not (zero? id))
	       (let* ((streams (conn-streams c))
		      (stream (alist-ref id streams))
		      (stream (stream-send stream `(window-update ,id ,wsi))))
		 (update-conn c streams: (alist-update id stream streams)))))))
 
  (define (conn-connection-error c ls ec #!optional (dd ""))
    (conn-send c `(goaway ,ls ,ec ,dd)))
 
  ;; conn-send
  (define (conn-send c f)
    (let* ((streams (conn-streams c))
	   (local-ws (conn-local-ws c))
	   (t (car f)))
     
      (define (data id data es)
	(set! local-ws (- local-ws (string-length data))))

      (define (headers id hbf eh es esdw)
	(if esdw
	    (apply priority esdw)))
     
      (define (priority id e sd w)
	'())

      (define (rst-stream id ec)
	'())

      (define (settings ls ack)
	'())

      (define (push-promise id psid eh)
	'())

      (define (ping data ack)
	'())

      (define (goaway ls ec dd)
	'())
     
      (define (window-update id wsi)
	(if (zero? id)
	    (set! local-ws (+ local-ws wsi))))

      (define (continuation id hbf eh)
	'())
     
      (if (member t '(data headers rst-stream window-update priority))
	  (let* ((id (cadr f))
		 (stream (alist-ref id streams))
		 (stream (stream-send stream f)))
	    (set! streams (alist-update id stream streams))))
     
      (write-frame f)
      (update-conn c
		   streams: streams
		   local-ws: local-ws)))

  ;; conn-recv
  (define (conn-recv c f handler)
    (let* ((mode (conn-mode c))
	   (status (conn-status c))
	   (in (conn-in c))
	   (out (conn-out c))
	   (lsid (conn-lsid c))
	   (active (conn-active c))
	   (ready (conn-ready c))
	   (peer-settings (conn-peer-settings c))
	   (local-settings (conn-local-settings c))
	   (flow-controller (conn-flow-controller c))
	   (decoder (conn-decoder c))
	   (encoder (conn-encoder c))
	   (streams (conn-streams c))
	   (local-ws (conn-local-ws c))
	   (peer-ws (conn-peer-ws c))
	   (t (car f)))
      (define (connection-error ls ec #!optional (dd ""))
	(conn-connection-error c ls ec dd))
     
      (define (priority id e sd w)
	'())
     
      (define (data id data es)
	(set! local-ws (- (string-length data))))

      (define (headers id hbf eh es esdw)
	(set! streams (if (not (alist-ref id streams))
			  (alist-update id (make-stream) streams)
			  streams))
	(if esdw (apply priority (cons 5 esdw))))

      (define (rst-stream id ec)
	'())

      (define (settings-validate settings ack)
	(let* ((ep (alist-ref 'SETTINGS-ENABLE-PUSH settings))
	       (mfs (alist-ref 'SETTINGS-MAX-FRAME-SIZE settings))
	       (iws (alist-ref 'SETTINGS-INITIAL-WINDOW-SIZE settings)))
	  (if (or (and ack (not (null? settings)))
		  (and ep (eq? 'client mode))
		  (and ep (not (zero? ep)) (not (eq? 1 ep)))
		  (and mfs (< (- (expt 2 24) 1) mfs))
		  (and iws (< (- (expt 2 31) 1) iws)))
	      (connection-error 0 'protocol-error "bad settings frame"))))

      (define (settings-apply settings)
	(set! peer-settings (fold
			     (lambda (setting peer)
			       (let* ((identifier (car setting))
				      (value (cdr setting)))
				 (case identifier
				   ((SETTINGS-HEADER-TABLE-SIZE) (set-header-table! encoder size: value)))
				 (alist-update identifier value peer)))
			     peer-settings
			     settings)))

      (define (settings ls ack)
	(settings-validate ls ack)
	(if (not ack)
	    (begin
	      (settings-apply ls)
	      (conn-send c '(settings () #t)))))

      (define (push-promise-validate id psid)
	(if (or #f ;TODO - if client disabled push, was acknowledged and receives a push - error
		(not (alist-ref id streams))
		(alist-ref psid streams))
	    (connection-error id 'protocol-error "bad push_promise frame")))
     
      (define (push-promise id psid hbf eh)
	(push-promise-validate id psid)
	(set! streams (alist-update id (make-stream) streams)))

      (define (ping data ack)
	(if (not ack)
	    (conn-send c `(ping ,data #t))))

     
      (define (goaway ls ec dd)
	(set! status 'closed))
     
      (define (window-update id wsi)
	(if (zero? id) (set! peer-ws (+ wsi peer-ws))))

      (define (continuation hbf eh)
	'())

      (if (or (and (member t '(data headers priority rst-stream continuation))
		   (zero? (cadr f)))
	      (and (member t '(goaway ping))
		   (not (zero? (cadr f))))
	      (and (eq? 'server mode)
		   (eq? t 'push-promise))
	      (and (eq? 'client mode)
		   (not (zero? (cadr f)))
		   (not (alist-ref (cadr f) streams))))
	  (connection-error (cadr f) 'protocol-error "in conn")
	  (let* ((fn (alist-ref t `((data . ,data)
				    (headers . ,headers)
				    (priority . ,priority)
				    (rst-stream . ,rst-stream)
				    (settings . ,settings)
				    (push-promise . ,push-promise)
				    (ping . ,ping)
				    (goaway . ,goaway)
				    (window-update . ,window-update)
				    (continuation . ,continuation)
				    (connection-error . ,connection-error))))
		 (args (cdr f)))
	    (apply fn args)))
     
      (define (update)
	(update-conn c status: status
		     active: active ready: ready peer-settings: peer-settings local-settings: local-settings
		     decoder: decoder encoder: encoder streams: streams local-ws: local-ws peer-ws: peer-ws))

      ;; process frame within its stream    
      (if (or (member t '(data headers rst-stream continuation push-promise))
	      (and (eq? t 'window-update)
		   (not (zero? (cadr f)))))
	  (let* ((id (cadr f))
		 (stream (alist-ref id streams)))
	    (if (stream-accepts? stream t)
		(let* ((shandler (lambda (id hbls db)
				   (let* ((headers (append-map (lambda (hb) (hpack-decode decoder hb)) hbls))
					  (body db)
					  (fn (if (eq? mode 'server)
						  make-request-with-headers-and-body
						  make-response-with-headers-and-body)))
				     (handler (update) id (fn headers body)))))
		       (stream (stream-recv stream f shandler)))
		  (set! streams (alist-update id stream streams)))
		(connection-error id 'protocol-error (conc "not expecting " t " frame")))))
      (update)))

  (define (http-connection-listen conn handler)
    (let lp ((c conn))
      (and (not (eq? 'closed (conn-status c)))
	   (lp (conn-recv c (read-frame) handler)))))

  (define (conn-response->frames conn id res)
    (let* ((encoder (conn-encoder conn)))
      `((headers ,id ,(hpack-encode encoder (response-all-headers res)) #t #f)
	(data ,id ,(response-body res) #t))))

  (define (http-connection-write-response conn id res)
    (let* ((encoder (conn-encoder conn)))
      (fold (lambda (f c)
	      (conn-send c f))
	    conn
	    (conn-response->frames conn id res))))

  (define (conn-read-client-settings conn)
    (let* ((f (read-frame))
	   (t (car f)))
      (if (not (eq? t 'settings))
	  (conn-connection-error conn 0 'protocol-error "expecting settings frame")
	  (conn-recv conn f identity))))
 
  (define (conn-read-client-preface conn)
    (let* ((s (read-string 24)))
      (if (string=? "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" s)
	  conn
	  (conn-connection-error conn 0 'protocol-error "bad client preface")))
    conn)
  
  (define (conn-write-server-preface conn)
    (write-frame `(settings ,(conn-local-settings conn) #f))
    conn)
 
  (define (make-http-server-connection
	   #!optional
	   (in (current-input-port))
	   (out (current-output-port)))
    (conn-read-client-settings
     (conn-read-client-preface
      (conn-write-server-preface
       (make-conn mode: 'server
		  in: in
		  out: out
		  local-settings: server-initial-settings
		  peer-settings: client-initial-settings))))))

;;server
(use tcp-server)
(use openssl)

(import http2)

(define (make-http-server-handler handler)
  ;; todo - run each request handler as a seperate thread (use mutexes on write-response)
  (lambda (conn id req)
	     (http-connection-write-response
	      conn
	      id
	      (handler req))))

(define (make-http-server handler)
  (lambda (ignore)
    (let* ((l (ssl-listen* port: 8000
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
;; driver
(define (handler req)
  (make-response status: 200
		 body: (with-output-to-string
			 (lambda ()
			   (display (request-pseudo-headers req))))))

((make-http-server handler) #t)
