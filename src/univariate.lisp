(in-package :cl-random)

(defstruct r-univariate
  "Univariate distribution.")

(defgeneric quantile (random-variable q)
  (:documentation "Quantile of RANDOM-VARIABLE at Q."))

(defgeneric standard-deviation (random-variable)
  (:documentation "Standard deviation of random variable.")
  (:method ((random-variable r-univariate))
    (sqrt (variance random-variable))))

;;; Uniform distribution.

(define-rv r-uniform (left right)
  (:documentation "Uniform(left,right) distribution."
   :include r-univariate)
  ((left :type internal-float :reader t)
   (right :type internal-float :reader t)
   (width :type internal-float))
  (with-floats (left right)
    (assert (< left right))
    (let ((width (- right left)))
      (make :left left :right right :width width)))
  (mean () (/ (+ left right) 2))
  (variance () (/ (expt width 2) 12d0))
  (log-pdf (x &optional ignore-constant?)
           (declare (ignorable ignore-constant?))
           (with-floats (x)
             (if (<= left x right)
                 (- (log width))
                 nil)))
  (cdf (x)
       (with-floats (x)
         (cond
           ((< x left) 0d0)
           ((< right x) 1d0)
           (t (/ (- x left) width)))))
  (quantile (p)
            (with-floats (p)
              (check-probability p)
              (+ left (* p (- right left)))))
  (draw (&key (rng *random-state*))
        (+ left (next width rng))))

;;; Exponential distribution.
;;;
;;; Also provides the primitive draw-standard-exponential, which is useful for
;;; constructing other distributions.

(declaim (inline draw-standard-exponential))
(defun draw-standard-exponential (&key (rng *random-state*))
  "Return a random variable from the Exponential(1) distribution, which has density exp(-x)."
  ;; need 1-random, because there is a small but nonzero chance of getting a 0.
  (- (log (- 1d0 (next 1d0 rng)))))

(define-rv r-exponential (rate)
  (:documentation "Exponential(beta) distribution, with density beta*exp(-beta*x) on x >= 0."
   :include r-univariate)
  ((rate :type internal-float :reader t))
  (with-floats (rate)
    (assert (plusp rate))
    (make :rate rate))
  (mean () (/ rate))
  (variance () (expt rate -2))
  (log-pdf (x &optional ignore-constant?)
           (declare (ignore ignore-constant?))
           (with-floats (x)
             (- (log rate) (* rate x))))
  (cdf (x)
       (with-floats (x)
         (- 1 (exp (- (* rate x))))))
  (quantile (p)
            (with-floats (p)
              (check-probability p :right)
              (/ (log (- 1 p)) (- rate))))
  (draw (&key (rng *random-state*))
        (/ (draw-standard-exponential :rng rng) rate)))


;;; Normal distribution (univariate).
;;;
;;; Also provides some primitives (mostly for standardized normal) that are useful for constructing/drawing from other distributions.

;(declaim (ftype (function () internal-float) draw-standard-normal))

(defun draw-standard-normal (&key (rng *random-state*))
  "Draw a random number from N(0,1)."
  ;; Method from Leva (1992).  This is considered much better/faster than the Box-Muller method.
  (declare (optimize (speed 3) (safety 0))
           #+sbcl (sb-ext:muffle-conditions sb-ext:compiler-note))
  (tagbody
   top
     (let* ((u (next 1d0 rng))
            (v (* 1.7156d0 (- (next 1d0 rng) 0.5d0)))
            (x (- u 0.449871d0))
            (y (+ (abs v) 0.386595d0))
            (q (+ (expt x 2) (* y (- (* 0.19600d0 y) (* 0.25472d0 x))))))
       (if (and (> q 0.27597d0)
                (or (> q 0.27846d0)
                    (plusp (+ (expt v 2) (* 4 (expt u 2) (log u))))))
           (go top)
           (return-from draw-standard-normal (/ v u))))))

(declaim (inline to-standard-normal from-standard-normal))

(defun to-standard-normal (x mu sigma)
  "Scale x to standard normal."
  (/ (- x mu) sigma))

(defun from-standard-normal (x mu sigma)
  "Scale x from standard normal."
  (+ (* x sigma) mu))

(defun cdf-normal% (x mean sd)
  "Internal function for normal CDF."
  (with-floats (x)
    (rmath:pnorm5 x mean sd 1 0)))

(defun quantile-normal% (q mean sd)
  "Internal function for normal quantile."
  (with-floats (q)
    (check-probability q :both)
    (rmath:qnorm5 q mean sd 1 0)))

(defconstant +normal-log-pdf-constant+ (as-float (/ (log (* 2 pi)) -2))
  "Normalizing constant for a standard normal PDF.")

(define-rv r-normal (&optional (mean 0d0) (variance 1d0))
  (:documentation "Normal(mean,variance) distribution."
   :include r-univariate)
  ((mean :type internal-float :reader t)
   (sd :type internal-float :reader t))
  (with-floats (mean variance)
    (assert (plusp variance))
    (make :mean mean :sd (sqrt variance)))
  (variance () (expt sd 2))
  (log-pdf (x &optional ignore-constant?)
           (maybe-ignore-constant ignore-constant?
                                  (with-floats (x)
                                    (/ (expt (- x mean) 2) (expt sd 2) -2d0))
                                  (- +normal-log-pdf-constant+ (log sd))))
  (cdf (x) (cdf-normal% x mean sd))
  (quantile (q)
            (quantile-normal% q mean sd))
  (draw (&key (rng *random-state*))
        (from-standard-normal (draw-standard-normal :rng rng) mean sd)))

;;; !! It is claimed in Marsaglia & Tsang (2000) that the ziggurat
;;; method is about 5-6 times faster than the above, mainly because of
;;; precomputed tables.  Need to write and test this, and if it is
;;; true, use that method instead.


;;; Truncated normal distribution (univariate).

(defun truncated-normal-moments% (N mu sigma left right
                                  &optional (m0 nil m0?))
  "N=0 gives the total mass of the truncated normal, used for normalization,
N=1 the mean, and N=2 the variance.  where p(x) is the normal density.  When LEFT or RIGHT are NIL, they are taken to be - or + infinity, respectively.  M0 may be provided for efficiency if would be calculated multiple times.  The formulas are from Jawitz (2004)."
  (if (zerop N)
      (- (if right (cdf-normal% right mu sigma) 1d0)
         (if left (cdf-normal% left mu sigma) 0d0))
      (let+ (((&flet part (x)
                (if x
                    (let ((y (exp (/ (expt (to-standard-normal x mu sigma) 2)
                                     -2))))
                      (values y (* (+ mu x) y)))
                    (values 0d0 0d0))))
             (m0 (if m0?
                     m0
                     (truncated-normal-moments% 0 mu sigma left right)))
             ((&flet diff (r l)
                (/ (* sigma (- r l))
                   m0 (sqrt (* 2 pi)))))
             ((&values l1 l2) (part left))
             ((&values r1 r2) (part right))
             (mean-mu (diff l1 r1)))
        (ecase N
          (1 (+ mean-mu mu))
          (2 (+ (diff l2 r2) (- (expt sigma 2)
                                (expt mean-mu 2) (* 2 mu mean-mu))))))))

(defun draw-left-truncated-standard-normal (left alpha &key (rng *random-state*))
  "Draw a left truncated standard normal, using an Exp(alpha,left) distribution.  LEFT is the standardized boundary, ALPHA should be calculated with TRUNCATED-NORMAL-OPTIMAL-ALPHA."
  (try ((z (+ (/ (draw-standard-exponential :rng rng) alpha) left))
        (rho (exp (* (expt (- z alpha) 2) -0.5))))
       (<= (next 1d0 rng) rho) z))

(defun truncated-normal-optimal-alpha (left)
  "Calculate optimal exponential parameter for left-truncated normals.  LEFT is the standardized boundary."
  (/ (+ left (sqrt (+ (expt left 2) 4d0)))
     2d0))

(define-rv left-truncated-normal (mu sigma left)
  (:documentation "Truncated normal distribution with given mu and sigma (corresponds to the mean and standard deviation in the untruncated case, respectively), on the interval [left, \infinity)."
   :include r-univariate)
  ((mu :type internal-float)
   (sigma :type internal-float)
   (left :type internal-float)
   (left-standardized :type internal-float)
   (m0 :type internal-float)
   (alpha :type internal-float))
  (with-floats (mu sigma left)
    (let ((left-standardized (to-standard-normal left mu sigma)))
      (make :mu mu :sigma sigma :left left :left-standardized left-standardized
            :m0 (truncated-normal-moments% 0 mu sigma left nil)
            :alpha (truncated-normal-optimal-alpha left-standardized))))
  (log-pdf (x &optional ignore-constant?)
           (when (<= left x)
             (maybe-ignore-constant ignore-constant?
                                    (with-floats (x)
                                      (/ (expt (- x mu) 2)
                                         (expt sigma 2) -2d0))
                                    (- +normal-log-pdf-constant+ (log sigma)
                                       (log m0)))))
  (cdf (x) (if (<= left x)
               (/ (1- (+ (cdf-normal% x mu sigma) m0)) m0)
               0d0))
  (quantile (q)
            (with-floats (q)
              (check-probability q :right)
              (rmath:qnorm5 (+ (* q m0) (- 1 m0)) mu sigma 1 0)))
  (mean () (truncated-normal-moments% 1 mu sigma left nil))
  (variance () (truncated-normal-moments% 2 mu sigma left nil))
  (draw (&key (rng *random-state*))
        (from-standard-normal
         (draw-left-truncated-standard-normal left-standardized alpha :rng rng)
         mu sigma)))

(defun r-truncated-normal (left right &optional (mu 0d0) (sigma 1d0))
  "Truncated normal distribution.  If LEFT or RIGHT is NIL, it corresponds to
-/+ infinity."
  (cond
    ((and left right) (error "not implemented yet"))
    (left (left-truncated-normal mu sigma left))
    (right (error "not implemented yet") )
    (t (r-normal mu (expt sigma 2)))))


;; (defclass truncated-normal (univariate)
;;   ((mu :initarg :mu :initform 0d0 :reader mu :type internal-float)
;;    (sigma :initarg :sigma :initform 1d0 :reader sigma :type positive-internal-float)
;;    (left :initarg :left :initform nil :reader left :type truncation-boundary)
;;    (right :initarg :right :initform nil :reader right :type truncation-boundary)
;;    (mass :type (internal-float 0d0 1d0) :documentation "total mass of the raw PDF")
;;    (mean :reader mean :type internal-float :documentation "mean")
;;    (variance :reader variance :type positive-internal-float :documentation "variance")
;;    (cdf-left :type internal-float :documentation "CDF at left"))
;;   (:documentation ))

;; (define-printer-with-slots truncated-normal mu sigma left right)

;; (defmethod initialize-instance :after ((rv truncated-normal) &key
;;                                        &allow-other-keys)
;;   ;; !!! calculations of mass, mean, variance are very bad if the
;;   ;; support is far out in the tail.  that should be approximated
;;   ;; differently (maybe we should give a warning?).
;;   (bind (((:slots left right mu sigma mass mean variance) rv))
;;     (flet ((conditional-calc (x left-p)
;;              ;; Return (values pdf xpdf cdf), also for missing
;;              ;; boundary (left-p gives which).  x is the normalized
;;              ;; variable; xpdf is x * pdf, 0 for infinite boundaries.
;;              (if x
;;                  (let* ((x (to-standard-normal x mu sigma))
;;                         (pdf (pdf-standard-normal x))
;;                         (xpdf (* x pdf))
;;                         (cdf (cdf-standard-normal x)))
;;                    (values pdf xpdf cdf))
;;                  (values 0d0 0d0 (if left-p 0d0 1d0)))))
;;       (check-type left truncation-boundary)
;;       (check-type right truncation-boundary)
;;       (bind (((:values pdf-left xpdf-left cdf-left)
;;               (conditional-calc left t))
;;              ((:values pdf-right xpdf-right cdf-right)
;;               (conditional-calc right nil)))
;;         ;; (format t "left  pdf=~a  xpdf=~a  cdf=~a~%right pdf=~a  xpdf=~a  cdf=~a~%"
;;         ;;         pdf-left xpdf-left cdf-left pdf-right xpdf-right cdf-right)
;;         (setf mass (- cdf-right cdf-left))
;;         (unless (plusp mass)
;;           (error "invalid left and/or right boundaries"))
;;         (let ((ratio (/ (- pdf-left pdf-right) mass)))
;;           (setf mean (+ mu (* ratio sigma))
;;                 variance (* (expt sigma 2)
;;                             (- (1+ (/ (- xpdf-left xpdf-right) mass))
;;                                (expt ratio 2)))
;;                 (slot-value rv 'cdf-left) cdf-left)))))
;;   rv)


;; (defmethod cdf ((rv truncated-normal) x)
;;   (check-type x internal-float)
;;   (bind (((:slots-read-only mu sigma mass left right cdf-left) rv))
;;     (cond
;;       ((<* x left) 0d0)
;;       ((>* x right) 1d0)
;;       (t (/ (- (cdf-standard-normal (to-standard-normal x mu sigma)) cdf-left)
;;             mass)))))


;; (defun truncated-normal-left-p (optimal-alpha left right)
;;   "Calculate if it is optimal to use the left-truncated draw and
;; reject than the two-sided accept-reject algorithm."
;;   (> (* optimal-alpha (exp (* optimal-alpha left 0.5d0)) (- right left))
;;      (* (exp 0.5d0) (exp (/ (expt left 2))))))

;; (declaim (inline draw-left-truncated-standard-normal
;;                  draw-left-right-truncated-standard-normal))



;; (defun draw-left-right-truncated-standard-normal (left width coefficient)
;;   "Accept-reject algorithm based on uniforms.  Coefficient is
;; multiplying the exponential, and has to be based on exp(left^2) or
;; exp(right^2) as appropriate.  width is right-left."
;;   (try ((z (+ left (next width rng)))
;;         (rho (* coefficient (exp (* (expt z 2) -0.5d0)))))
;;        (<= (next 1d0 rng) rho) z))

;; (define-cached-slot (rv truncated-normal generator)
;;   (declare (optimize (speed 3)))
;;   (bind (((:slots-read-only mu sigma left right) rv))
;;     (declare (internal-float mu sigma)
;;              (truncation-boundary left right))
;;     (macrolet ((lambda* (form)
;;                  "Lambda with no arguments, transform using mu and sigma."
;;                  `(lambda ()
;;                     (from-standard-normal ,form mu sigma)))
;;                (lambda*- (form)
;;                  "Like lambda*, but also negating the argument."
;;                  `(lambda* (- ,form))))
;;       (cond
;;         ;; truncated on both sides
;;         ((and left right)
;;          (let* ((left (to-standard-normal left mu sigma))
;;                 (right (to-standard-normal right mu sigma))
;;                 (width (- right left))
;;                 (contains-zero-p (<= left 0d0 right)))
;;            (cond
;;              ;; too wide: best to sample from normal and discard
;;              ((and (< (sqrt (* 2 pi)) width) contains-zero-p)
;;               (lambda* (try ((x (draw-standard-normal)))
;;                             (<= left x right) x)))
;;              ;; narrow & contains zero: always use uniform-based reject/accept
;;              (contains-zero-p
;;               (lambda* (draw-left-right-truncated-standard-normal
;;                         left width 1d0)))
;;              ;; whole support above 0, need to test
;;              ((< 0d0 left)
;;               (let ((alpha (truncated-normal-optimal-alpha left)))
;;                 (if (truncated-normal-left-p alpha left right)
;;                     ;; optimal to try and reject if not good
;;                     (lambda* (try ((x (draw-left-truncated-standard-normal
;;                                        left alpha)))
;;                                   (<= x right) x))
;;                     ;; optimal to use the uniform-based reject/accept
;;                     (lambda* (draw-left-right-truncated-standard-normal
;;                               left width (* (expt left 2) 0.5d0))))))
;;              ;; whole support below 0, will flip
;;              (t
;;               ;; swap, and then negate
;;               (let ((left (- right))
;;                     (right (- left)))
;;                 (let ((alpha (truncated-normal-optimal-alpha left)))
;;                   (if (truncated-normal-left-p alpha left right)
;;                       ;; optimal to try and reject if not good
;;                       (lambda*- (try ((x (draw-left-truncated-standard-normal
;;                                           left alpha)))
;;                                      (<= x right) x))
;;                       ;; optimal to use the uniform-based reject/accept
;;                       (lambda*- (draw-left-right-truncated-standard-normal
;;                                  left width (* (expt left 2) 0.5d0))))))))))
;;         ;; truncated on the left
;;         (left
;;          (let ((left (to-standard-normal left mu sigma)))
;;                (if (<= left 0d0)
;;                    (lambda* (try ((x (draw-standard-normal)))
;;                                  (<= left x) x))
;;                    (lambda* (draw-left-truncated-standard-normal
;;                              left
;;                              (truncated-normal-optimal-alpha left))))))
;;         ;; truncated on the right, flip
;;         (right
;;          (let ((left (- (to-standard-normal right mu sigma))))
;;            (if (<= left 0d0)
;;                (lambda*- (try ((x (draw-standard-normal)))
;;                               (<= left x) x))
;;                (lambda*- (draw-left-truncated-standard-normal
;;                           left
;;                           (truncated-normal-optimal-alpha left))))))
;;         ;; this is a standard normal, no truncation
;;         (t (lambda* (draw-standard-normal)))))))


;;; Lognormal distribution

(define-rv r-log-normal (log-mean log-sd)
  (:documentation "Log-normal distribution with location log-mean and scale log-sd."
   :include r-univariate)
  ((log-mean :type internal-float)
   (log-sd :type internal-float))
  (with-floats (log-mean log-sd)
    (assert (plusp log-sd))
    (make :log-mean log-mean :log-sd log-sd))
  (mean () (exp (+ log-mean (/ (expt log-sd 2) 2))))
  (variance () (let ((sigma^2 (expt log-sd 2)))
                 (* (1- (exp sigma^2))
                    (exp (+ (* 2 log-mean) sigma^2)))))
  (log-pdf (x &optional ignore-constant?)
           (maybe-ignore-constant ignore-constant?
                                  (with-floats (x)
                                    (let ((log-x (log x)))
                                      (- (/ (expt (- log-x log-mean) 2)
                                            (expt log-sd 2) -2)
                                         log-x)))
                                  (- +normal-log-pdf-constant+ (log log-sd))))
  (cdf (x)
       (if (plusp x)
           (cdf-normal% (log x) log-mean log-sd)
           0d0))
  (quantile (q)
            (check-probability q :right)
            (if (zerop q)
                0d0
                (exp (quantile-normal% q log-mean log-sd))))
  (draw (&key (rng *random-state*))
        (exp (from-standard-normal (draw-standard-normal :rng rng) log-mean log-sd))))


;;; Student's T distribution

(declaim (inline t-scale-to-variance-coefficient))
(defun t-scale-to-variance-coefficient (nu)
  "Return the coefficient that multiplies the Sigma matrix or the squared
scale to get the variance of a (multivariate) Student-T distribution.  Also
checks that nu > 2, ie the variance is defined."
  (assert (< 2d0 nu))
  (/ nu (- nu 2d0)))

(defun draw-standard-t (nu &key (rng *random-state*))
  "Draw a standard T random variate, with NU degrees of freedom."
  ;; !! algorithm from Bailey (1994), test Marsaglia (1984) to see if it is
  ;; !! faster
  (declare (internal-float nu)
           (optimize (speed 3))
           #+sbcl (sb-ext:muffle-conditions sb-ext:compiler-note))
  (try ((v1 (1- (next 2d0 rng)))
        (v2 (1- (next 2d0 rng)))
        (r-square (+ (expt v1 2) (expt v2 2))))
       (<= r-square 1)
       (* v1 (sqrt (the (internal-float 0d0)
                     (/ (* nu (1- (expt r-square (/ -2d0 nu)))) r-square))))))

(define-rv r-t (mean scale nu)
  (:documentation "T(mean,scale,nu) random variate."
   :include r-univariate)
  ((mean :type internal-float :reader t)
   (scale :type internal-float :reader t)
   (nu :type internal-float :reader t))
  (with-floats (mean scale nu)
    (assert (plusp nu))
    (assert (plusp scale))
    (make :mean mean :scale scale :nu nu))
  (variance ()
            (* (expt scale 2)
               (t-scale-to-variance-coefficient nu)))
  (draw (&key (rng *random-state*))
        (from-standard-normal (draw-standard-t nu :rng rng) mean scale)))


;;; Gamma distribution.
;;;
;;; Also provides a generator-standard-gamma, which returns a
;;; generator for a given alpha.

(declaim (inline standard-gamma1-d-c draw-standard-gamma1
                 generator-standard-gamma))

(defun standard-gamma1-d-c (alpha)
  "Return precalculated constants (values d c), useful for drawing
from a gamma distribution."
  (let* ((d (- (as-float alpha) (/ 3)))
         (c (/ (sqrt (* 9 d)))))
    (values d c)))

(defun draw-standard-gamma1 (alpha d c &key (rng *random-state*))
  "Return a standard gamma variate (beta=1) with shape parameter alpha
>= 1.  See Marsaglia and Tsang (2004).  You should precalculate d
and c using the utility function above. "
  ;; !! see how much the change in draw-standard-normal would speed this up
  (declare (optimize (speed 3))
           (type internal-float d c)
           #+sbcl (sb-ext:muffle-conditions sb-ext:compiler-note))
  (check-type alpha (internal-float 1))
  (tagbody
   top
     (let+ (((&values x v) (prog ()     ; loop was not optimized for some reason
                            top
                              (let* ((x (draw-standard-normal :rng rng))
                                     (v (expt (1+ (* c x)) 3)))
                                (if (plusp v)
                                    (return (values x v))
                                    (go top)))))
            (u (next 1d0 rng))
            (xsq (expt x 2)))
       (if (or (< (+ u (* 0.0331 (expt xsq 2))) 1d0)
               (< (log u) (+ (* 0.5 xsq) (* d (+ (- 1d0 v) (log v))))))
           (return-from draw-standard-gamma1 (* d v))
           (go top)))))

(declaim (inline log-gamma))
(defun log-gamma (alpha)
  "Log gamma function."
  (rmath:lgammafn (coerce alpha 'double-float)))

(define-rv r-gamma (alpha beta)
  (:documentation "Gamma(alpha,beta) distribution, with density proportional to x^(alpha-1) exp(-x*beta).  Alpha and beta are known as shape and inverse scale (or rate) parameters, respectively."
   :include r-univariate)
  ((alpha :type internal-float :reader t)
   (beta :type internal-float :reader t))
  (with-floats (alpha beta)
    (assert (plusp alpha))
    (assert (plusp beta))
    (make :alpha alpha :beta beta))
  (mean () (/ alpha beta))
  (variance () (* alpha (expt beta -2)))
  (log-pdf (x &optional ignore-constant?)
           (maybe-ignore-constant
            ignore-constant?
            (with-floats (x)
              (- (+ (* alpha (log beta)) (* (1- alpha) (log x))) (* beta x)))
            (- (log-gamma alpha))))
  ;; note that R uses scale=1/beta
  (cdf (x)
       (with-floats (x)
         (with-fp-traps-masked
           (rmath:pgamma x alpha (/ beta) 1 0))))
  (quantile (q)
            (with-floats (q)
              (check-probability q :right)
              (with-fp-traps-masked
                (rmath:qgamma q alpha (/ beta) 1 0))))
  (draw (&key (rng *random-state*))
        ;; !! could optimize this by saving slots
        (if (< alpha 1d0)
            (let+ ((1+alpha (1+ alpha))
                   (1/alpha (/ alpha))
                   ((&values d c) (standard-gamma1-d-c 1+alpha)))
              ;; use well known-transformation, see p 371 of Marsaglia and
              ;; Tsang (2000)
              (/ (* (expt (next 1d0 rng) 1/alpha)
                    (draw-standard-gamma1 1+alpha d c :rng rng))
                 beta))
            (let+ (((&values d c) (standard-gamma1-d-c alpha)))
              (/ (draw-standard-gamma1 alpha d c :rng rng) beta)))))


;;; Inverse gamma distribution.

(define-rv r-inverse-gamma (alpha beta)
  (:documentation "Inverse-Gamma(alpha,beta) distribution, with density p(x)
 proportional to x^(-alpha+1) exp(-beta/x)"
   :include r-univariate
   :num=-slots (alpha beta))
  ((alpha :type internal-float :reader t)
   (beta :type internal-float :reader t))
  (with-floats (alpha beta)
    (assert (plusp alpha))
    (assert (plusp beta))
    (make :alpha alpha :beta beta))
  (mean () (if (< 1 alpha)
               (/ beta (1- alpha))
               (error "Mean is defined only for ALPHA > 1")))
  (variance () (if (< 2 alpha)
                   (/ (expt beta 2) (expt (1- alpha) 2) (- alpha 2))
                   (error "Variance is defined only for ALPHA > 2")))
  (log-pdf (x &optional ignore-constant?)
           (maybe-ignore-constant
            ignore-constant?
            (- (* (- (1+ alpha)) (log x)) (/ beta x))
            (- (* alpha (log beta)) (log-gamma alpha))))
  (draw (&key (rng *random-state*))
        (if (< alpha 1d0)
            (let+ ((1+alpha (1+ alpha))
                   (1/alpha (/ alpha))
                   ((&values d c) (standard-gamma1-d-c 1+alpha)))
              ;; use well known-transformation, see p 371 of Marsaglia and
              ;; Tsang (2000)
              (/ beta
                 (* (expt (next 1d0 rng) 1/alpha)
                    (draw-standard-gamma1 1+alpha d c :rng rng))))
            (let+ (((&values d c) (standard-gamma1-d-c alpha)))
              (/ beta (draw-standard-gamma1 alpha d c :rng rng))))))


;;; Chi-square and inverse-chi-square distribution (both scaled).
;;;
;;; We just reparametrize and rely on GAMMA and INVERSE-GAMMA.


(defgeneric nu (distribution)
  (:documentation "Return the degrees of freedom when applicable."))

(defgeneric s^2 (distribution)
  (:documentation "Return the scale when applicable."))

(defun r-chi-square (nu)
  "Chi-square distribution with NU degrees of freedom."
  (r-gamma (/ nu 2) 0.5d0))

(defmethod nu ((r-gamma r-gamma))
  (* 2 (r-gamma-alpha r-gamma)))

(defun r-inverse-chi-square (nu &optional (s^2 1d0))
  "Generalized inverse chi-square distribution.  Reparametrized to
INVERSE-GAMMA."
  (let ((nu/2 (/ nu 2)))
    (r-inverse-gamma nu/2 (* nu/2 s^2))))

(defmethod nu ((r-inverse-gamma r-inverse-gamma))
  (* 2 (r-inverse-gamma-alpha r-inverse-gamma)))

(defmethod s^2 ((r-inverse-gamma r-inverse-gamma))
  (let+ (((&structure r-inverse-gamma- alpha beta) r-inverse-gamma))
    (/ beta alpha)))


;;; Beta distribution.

(define-rv r-beta (alpha beta)
  (:documentation "Beta(alpha,beta) distribution, with density proportional to
x^(alpha-1)*(1-x)^(beta-1)."
   :include r-univariate)
  ((alpha :type internal-float :reader t)
   (beta :type internal-float :reader t))
  (with-floats (alpha beta)
    (assert (plusp alpha))
    (assert (plusp beta))
    (make :alpha alpha :beta beta))
  (mean () (/ alpha (+ alpha beta)))
  (variance () (let ((sum (+ alpha beta)))
                 (/ (* alpha beta) (* (expt sum 2) (1+ sum)))))
  (draw (&key (rng *random-state*))
        (let ((alpha (draw (r-gamma alpha 1) :rng rng))
              (beta (draw (r-gamma beta 1) :rng rng)))
          (/ alpha (+ alpha beta))))
  (quantile (q)
            (with-floats (q)
              (rmath:qbeta q alpha beta 1 0))))


;;; Discrete distribution.
;;;
;;; ?? The implementation may be improved speedwise with declarations and
;;; micro-optimizations.  Not a high priority.  However, converting arguments
;;; to internal-float provided a great speedup, especially in cases when the
;;; normalization resulted in rationals -- comparisons for the latter are
;;; quite slow.

(define-rv r-discrete (probabilities)
  (:documentation "Discrete probabilities."
   :include r-univariate
   :instance instance)
  ((probabilities :type float-vector :reader t)
   (prob :type float-vector)
   (alias :type (simple-array fixnum (*)))
   (n-float :type internal-float))
  ;; algorithm from Vose (1991)
  (let* ((probabilities (as-float-probabilities probabilities))
         (p (copy-seq probabilities))   ; this is modified
         (n (length probabilities))
         (alias (make-array n :element-type 'fixnum))
         (prob (make-array n :element-type 'internal-float))
         (n-float (as-float n))
         (threshold (/ n-float))
         small
         large)
    ;; separate using threshold
    (dotimes (i n)
      (if (> (aref p i) threshold)
          (push i large)
          (push i small)))
    ;; reshuffle
    (loop :while (and small large) :do
             (let* ((j (pop small))
                    (k (pop large)))
               (setf (aref prob j) (* n-float (aref p j))
                     (aref alias j) k)
               (if (< threshold (incf (aref p k)
                                      (- (aref p j) threshold)))
                   (push k large)
                   (push k small))))
    ;; the rest use 1
    (loop :for s :in small :do (setf (aref prob s) 1d0))
    (loop :for l :in large :do (setf (aref prob l) 1d0))
    ;; save what's needed
    (make :probabilities probabilities :prob prob :alias alias :n-float n-float))
  (mean ()
        (loop
          for p across probabilities
          for i from 0
          summing (* p i)))
  (variance ()
            (loop
              with mean = (mean instance)
              for p across probabilities
              for i from 0
              summing (* p (expt (- i mean) 2))))
  (log-pdf (i &optional ignore-constant?)
           (declare (ignore ignore-constant?))
           (log (aref probabilities i)))
  (cdf (i)
       ;; NIL gives the whole CDF
       (if i
           (loop ; note: loop semantics takes care of indices outside support
             for p across probabilities
             repeat (1+ i)
             summing p)
           (clnu:cumulative-sum probabilities
                                :result-type 'internal-float-vector)))
  (draw (&key (rng *random-state*))
        (multiple-value-bind (j p) (floor (next n-float rng))
          (if (<= p (aref prob j))
              j
              (aref alias j)))))


;;; Bernoulli distribution

(declaim (inline draw-bernoulli draw-bernoulli-bit))
(defun draw-bernoulli (p &key (rng *random-state*))
  "Return T with probability p, otherwise NIL. Rationals are handled exactly."
  (etypecase p
    (integer (ecase p
               (0 NIL)
               (1 T)))
    (rational (let+ (((&accessors-r/o numerator denominator) p))
                (assert (<= numerator denominator))
                (< (next denominator rng) numerator)))
    (float (< (next (float 1 p) rng) p))))

(defun draw-bernoulli-bit (p &key (rng *random-state*))
  (if (draw-bernoulli p :rng rng) 1 0))


;; Use PR instead of P, otherwise both type predicate and structure member are called
;; r-bernoulli-p.
(define-rv r-bernoulli (pr)
  (:documentation "Bernoulli(pr) distribution, with probability PR for success and 1-PR
for failure."
   :include r-univariate)
  ((pr :type internal-float :reader T))
  (with-floats (pr)
    (check-probability pr :both)
    (make :pr pr))
  (mean () pr)
  (variance () (* pr (- 1 pr)))
  (draw (&key (rng *random-state*))
        (draw-bernoulli-bit pr :rng rng))
  (cdf (x)
       (cond ((< x 0) 0)
	     ((< x 1) (- 1 pr))
	     (T 1))))



;;; Binomial distribution

(declaim (inline draw-binomial))
(defun draw-binomial (p n &key (rng *random-state*))
  "Return the number of successes out of N Bernoulli trials with probability
of success P."
  (let ((successes 0))
    (dotimes (i n successes)
      (when (draw-bernoulli p :rng rng)
	(incf successes)))))

(define-rv r-binomial (pr n)
  (:documentation "Binomial(pr,n) distribution, with N Bernoulli trials with 
probability PR for success."
   :include r-univariate)
  ((pr :type internal-float :reader T)
   (n :type integer :reader T))
  (with-floats (pr)
    (check-probability pr)
    (assert (plusp n))
    (make :pr pr :n n))
  (mean () (* n pr))
  (variance () (* n pr (- 1 pr)))
  (draw (&key (rng *random-state*))
        (draw-binomial pr n :rng rng)))



;;; Geometric distribution

(declaim (inline draw-geometric))
(defun draw-geometric (p &key (rng *random-state*))
  "Return the number of Bernoulli trials, with probability of success P, that were needed to reach the first success. This is >= 1."
    (do ((trials 1 (1+ trials)))
	((draw-bernoulli p :rng rng) trials)))

(define-rv r-geometric (pr)
  (:documentation "Geometric(pr) distribution."
   :include r-univariate)
  ((pr :type internal-float :reader T))
  (with-floats (pr)
    (check-probability pr :left)
    (make :pr pr))
  (mean () (/ pr))
  (variance () (/ (- 1 pr) (* pr pr)))
  (draw (&key (rng *random-state*))
	(draw-geometric pr :rng rng)))



;;; Poisson distribution

(declaim (inline draw-poison))
(defun draw-poisson (lamda &key (rng *random-state*))
  "Return the number of events that occur with probability LAMDA. The algorithm is from Donald E. Knuth (1969). Seminumerical Algorithms. The Art of Computer Programming, Volume 2. Addison Wesley. WARNING: It's simple but only linear in the return value K and is numerically unstable for large LAMDA."
  (do ((l (exp (- lamda)))
       (k 0 (1+ k))
       (p 1d0 (* p u))
       (u (next 1d0 rng) (next 1d0 rng)))
      ((<= p l) k)))
