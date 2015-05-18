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
