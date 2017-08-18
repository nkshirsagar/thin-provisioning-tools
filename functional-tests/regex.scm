(library
  (regex)
  (export lit
          seq
          alt
          opt
          star
          plus
          compile-rx
          match-rx)
  (import (chezscheme)
          (fmt fmt)
          (loops)
          (matchable))

  ;; Simple regex library, because it's friday and I'm bored.
  ;; Playing with the ideas in: https://swtch.com/~rsc/regexp/regexp2.html
  ;; which reminded me of reading through the source code to Sam in '93.

  ;; Rather than parsing a string we'll use expressions.
  ;; (lit <string>)
  ;; (seq rx1 rx2)
  ;; (alt rx1 rx2)
  ;; (opt rx)
  ;; (star rx)
  ;; (plus rx)
  ;;
  ;; The expressions get compiled into a vector of vm instructions.
  ;; (char c)
  ;; (match)
  ;; (jmp x)
  ;; (split x y)

  ;; instructions are closures that manipulate the thread

  ;; FIXME: slow
  (define (append-instr code . i) (append code i))
  (define (label-instr l) `(label ,l))
  (define (jmp-instr l) `(jmp ,l))
  (define (char-instr c) `(char ,c))
  (define (split-instr l1 l2) `(split ,l1 ,l2))
  (define (match-instr) '(match))
  (define (match-instr? instr) (equal? '(match) instr))

  (define (label-code label code)
    (cons (label-instr label) code))

  ;; Compiles to a list of labelled instructions that can later be flattened
  ;; into a linear sequence.
  (define (lit str)
    (map char-instr (string->list str)))

  (define (seq rx1 rx2)
    (append rx1 rx2))

  (define (alt rx1 rx2)
    (let ((label1 (gensym))
          (label2 (gensym))
          (tail (gensym)))
      (let ((c1 (label-code label1
                            (append-instr rx1 (jmp-instr tail))))
            (c2 (label-code label2 rx2)))
        (cons (split-instr label1 label2)
              (append-instr (append c1 c2) (label-instr tail))))))

  (define (opt rx)
    (let ((head (gensym))
          (tail (gensym)))
      (cons (split-instr head tail)
            (label-code head
                        (append-instr rx (label-instr tail))))))

  (define (star rx)
    (let ((head (gensym))
          (body (gensym))
          (tail (gensym)))
      (label-code head
                  (cons (split-instr body tail)
                        (label-code body
                                    (append-instr rx
                                                  (jmp-instr head)
                                                  (label-instr tail)))))))

  (define (plus rx)
    (let ((head (gensym))
          (tail (gensym)))
      (label-code head
                  (append-instr rx
                                (split-instr head tail)
                                (label-instr tail)))))

  (define (label-locations code)
    (let ((locs (make-eq-hashtable)))
     (let loop ((pc 0)
                (code code))
       (if (null? code)
           locs
           (match (car code)
                  (('label l)
                   (begin
                     (hashtable-set! locs l pc)
                     (loop pc (cdr code))))
                  (instr
                    (loop (+ 1 pc) (cdr code))))))))

  (define (remove-labels code locs)
    (let loop ((pc 0)
               (code code)
               (acc '()))
      (if (null? code)
          (reverse acc)
          (match (car code)
                 (('label l)
                  (loop pc (cdr code) acc))

                 (('jmp l)
                  (loop (+ 1 pc) (cdr code)
                        (cons `(jmp ,(hashtable-ref locs l #f)) acc)))

                 (('split l1 l2)
                  (loop (+ 1 pc) (cdr code)
                        (cons `(split ,(hashtable-ref locs l1 #f)
                                      ,(hashtable-ref locs l2 #f))
                              acc)))

                 (instr (loop (+ 1 pc) (cdr code) (cons instr acc)))))))

  (define (optimise-jumps! code)
    (upto (n (vector-length code))
          (match (vector-ref code n)
                 (('jmp l)
                  (when (match-instr? (vector-ref code l))
                    (vector-set! code n (match-instr))))

                 (('split l1 l2)
                  (when (or (match-instr? (vector-ref code l1))
                            (match-instr? (vector-ref code l2)))
                    (vector-set! code n (match-instr))))

                 (_ _)))
    code)

  (define (compile-rx rx)
    (let ((rx (append-instr rx (match-instr))))
     (optimise-jumps!
       (list->vector
         (remove-labels rx (label-locations rx))))))

  ;; A 'thread' consists of an index into the instructions.  A 'bundle' holds
  ;; the current threads.  Note there cannot be more threads than instructions,
  ;; so a bundle is represented as a bitvector the same length as the
  ;; instructions.  Threads are run in lock step, all taking the same input.

  (define-record-type thread-set (fields (mutable stack) (mutable seen)))

  (define (mk-thread-set count)
    (make-thread-set '() (make-vector count #f)))

  (define (add-thread! ts i)
    (unless (vector-ref (thread-set-seen ts) i)
      (vector-set! (thread-set-seen ts) i #t)
      (thread-set-stack-set! ts (cons i (thread-set-stack ts)))))

  (define (pop-thread! ts)
    (if (null? (thread-set-stack ts))
        #f
        (let ((t (car (thread-set-stack ts))))
         (thread-set-stack-set! ts (cdr (thread-set-stack ts)))
         t)))

  (define (no-threads? ts)
    (null? (thread-set-stack ts)))

  (define (any-matches? ts code)
    (call/cc
      (lambda (k)
        (while (i (pop-thread! ts))
               (if (match-instr? (vector-ref code i))
                   (k #t)))
        #f)))

  (define (mk-init-thread-set count)
    (let ((ts (mk-thread-set count)))
     (add-thread! ts 0)
     ts))

  (define (match-rx code txt)
    (fmt #t (dsp "running ") (pretty code) nl)
    (call/cc
      (lambda (k)
        (let ((code-len (vector-length code)))
         (let loop ((threads (mk-init-thread-set code-len))
                    (input (string->list txt)))
           (if (null? input)
               (any-matches? threads code)
               (let ((in-c (car input))
                     (next-threads (mk-thread-set code-len)))
                 (fmt #t (dsp "processing: ") (wrt in-c) nl)
                 (while (i (pop-thread! threads))
                        (match (vector-ref code i)
                               (('match) (k #t))

                               (('char c)
                                (when (eq? c in-c)
                                  (add-thread! next-threads (+ 1 i))))

                               (('jmp l) (add-thread! threads l))

                               (('split l1 l2)
                                (begin
                                  (add-thread! threads l1)
                                  (add-thread! threads l2)))))
                 (if (no-threads? next-threads)
                     #f
                     (loop next-threads (cdr input))))))))))

  )
