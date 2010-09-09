(in-package :cl-random)

(defun check-mean-variance-compatibility (mean variance)
  "Assert that the mean is a vector, and its dimensions are compatible with
variance."
  (assert (and (vectorp mean) 
               (= (length mean) (nrow variance) (ncol variance)))))

;;;;
;;;;  MULTIVARIATE-NORMAL distribution
;;;;
;;;;  The generator of this distribution allows to draws to be
;;;;  multiplied by a scale factor, which is useful for sampling from
;;;;  posteriors, etc.

(defclass mv-normal (multivariate log-pdf-constant)
  ((mean :initarg :mean :reader mean :type vector
         :documentation "vector of means")
   (variance :initarg :variance :reader variance
          :type hermitian-matrix
          :documentation "variance matrix")
   (variance-right-sqrt 
    :initarg :variance-right-sqrt
    :reader variance-right-sqrt :type dense-matrix
    :documentation "(right) square root of variance, ie M such that M^T M=variance")))

(defmethod initialize-instance :after ((rv mv-normal) &key &allow-other-keys)
  (let ((variance-or-sqrt
         (cond
           ((slot-boundp rv 'variance)
            (aprog1 (slot-value rv 'variance)
              (assert (typep it 'hermitian-matrix) ()
                      "VARIANCE has to be a hermitian matrix.")))
           ((slot-boundp rv 'variance-right-sqrt)
            (aprog1 (slot-value rv 'variance-right-sqrt)
              (assert (square-matrix? it) ()
                      "VARIANCE-SQRT has to be a square matrix.")))
           (t (error "At least one of VARIANCE or VARIANCE-RIGHT-SQRT ~
                      has to be provided.")))))
    (if (slot-boundp rv 'mean)
        (check-mean-variance-compatibility (slot-value rv 'mean)
                                           variance-or-sqrt)
        (setf (slot-value rv 'mean)
              (lla-array (nrow variance-or-sqrt)
                          (array-lla-type (elements variance-or-sqrt))
                          0)))))

(define-cached-slot (rv mv-normal log-pdf-constant)
  (bind (((:slots-r/o variance-right-sqrt) rv))
    (- (/ (* (log (* 2 pi)) (nrow variance-right-sqrt)) -2)
       (logdet variance-right-sqrt))))

(define-cached-slot (rv mv-normal variance)
  (mm t (variance-right-sqrt rv)))

(define-cached-slot (rv mv-normal variance-right-sqrt)
  (factor (cholesky (variance rv) :U)))

(define-printer (mv-normal)
  (format stream "~&MEAN: ~A~%VARIANCE:~%~A~%" (mean rv) (variance rv)))

(defmethod dimensions ((rv mv-normal))
  (list (length (mean rv))))

(defmethod rv-type ((rv mv-normal))
  'simple-array1)

(defun normal-quadratic-form% (x rv)
  "Calculate (x-mean)^T variance^-1 (x-mean), given X."
  (dot (solve (transpose (variance-right-sqrt rv)) (e- x (mean rv))) t))

(defmethod log-pdf ((rv mv-normal) x &optional unscaled?)
  (scale-log-pdf rv unscaled? (* -0.5d0 (normal-quadratic-form% x rv))))

(define-cached-slot (rv mv-normal generator)
  (bind (((:slots-read-only mean variance-right-sqrt) rv)
         (n (length mean)))
    (lambda (&optional (scale 1d0))
      (let* ((x (lla-array n :double)))
        (dotimes (i n)
          (setf (aref x i) (draw-standard-normal)))
        (e+ mean (mm x variance-right-sqrt scale))))))

(defmethod sub ((rv mv-normal) &rest ranges)
  (bind (((range) ranges)
         ((:slots-r/o mean variance) rv))
    (if (typep range 'fixnum)
        (make-instance 'normal
                       :mu (float (sub mean range) 1d0)
                       :sigma (float (sqrt (sub variance range range)) 1d0))
        (make-instance 'mv-normal
                       :mean (sub mean range)
                       :variance (sub variance range range)))))

;;;  MULTIVARIATE T distribution
;;;
;;;  When drawing numbers, the scaling factor (with distribution
;;;  inverse-chi-square, df nu) returned as the second value.

(defclass mv-t (multivariate log-pdf-constant)
  ((scaling-factor :accessor scaling-factor
                   :initarg :scaling-factor
                   :type inverse-chi-square
                   :documentation
                   "distribution that scales the variance of draws.")
   (mv-normal :accessor mv-normal
              :initarg :mv-normal
              :type mv-normal :documentation
              "distribution for obtaining normal draws")))

(defmethod nu ((rv mv-t))
  (nu (scaling-factor rv)))

(defmethod initialize-instance :after ((rv mv-t) &key 
                                       (mean nil mean?) 
                                       (sigma nil sigma?)
                                       (sigma-right-sqrt nil sigma-right-sqrt?)
                                       nu
                                       (mv-normal nil mv-normal?)
                                       (scaling-factor nil scaling-factor?)
                                       &allow-other-keys)
  (bind (((:flet @ (present? value keyword))
          (when present?
            (list keyword value))))
    (if mv-normal?
        (check-type mv-normal mv-normal)
        (setf (mv-normal rv)
              (apply #'make-instance 'mv-normal
                     (concatenate 'list 
                                  (@ mean? mean :mean)
                                  (@ sigma? sigma :variance)
                                  (@ sigma-right-sqrt? sigma-right-sqrt
                                     :variance-right-sqrt)))))
    (if scaling-factor?
        (check-type scaling-factor inverse-chi-square)
        (setf (scaling-factor rv)
              (make-instance 'inverse-chi-square :nu (float nu 0d0))))))

(defmethod sub ((rv mv-t) &rest ranges)
  (bind (((:slots-r/o mv-normal scaling-factor) rv)
         ((range) ranges))
    (if (typep range 'fixnum)
        (error "not implemented")       ; need univariate t
        (make-instance 'mv-t :mv-normal (sub mv-normal range)
                       :scaling-factor scaling-factor))))

(define-cached-slot (rv mv-t log-pdf-constant)
  (bind (((:accessors-r/o mv-normal nu) rv)
         ((:slots-r/o variance-right-sqrt) mv-normal)
         (d (nrow variance-right-sqrt)))
    (- (log-gamma (/ (+ nu d) 2d0))
       (log-gamma (/ nu 2d0))
       (* (+ (log nu) (log pi)) (/ d 2d0))
       (logdet variance-right-sqrt))))

(define-printer (mv-t)
  (with-slots (mv-normal scaling-factor) rv
    (format stream "~&NU: ~A  MEAN: ~A~%SIGMA:~%~A~%" (nu scaling-factor)
            (mean mv-normal) (variance mv-normal))))

(defmethod dimensions ((rv mv-t))
  (dimensions (mv-normal rv)))

(defmethod rv-type ((rv mv-t))
  'numeric-vector)

(defmethod mean ((rv mv-t))
  (assert (< 1 (nu rv)))
  (mean (mv-normal rv)))

(defmethod variance ((rv mv-t))
  (bind (((:accessors-r/o nu) rv))
    (assert (< 2 nu))
    (e* (variance (mv-normal rv)) (/ nu (- nu 2d0)))))

(defmethod log-pdf ((rv mv-t) x &optional unscaled?)
  (bind (((:accessors-r/o nu mv-normal) rv)
         (d (size (mean rv))))
    (scale-log-pdf rv unscaled? 
                   (* (log (1+ (/ (normal-quadratic-form% x mv-normal)
                                  nu)))
                      (/ (+ nu d) -2d0)))))

(define-cached-slot (rv mv-t generator)
  (bind (((:slots-read-only scaling-factor mv-normal) rv)
         (scaling-factor-generator (generator scaling-factor))
         (mv-normal-generator (generator mv-normal)))
    (lambda ()
      (let ((scaling-factor (funcall scaling-factor-generator)))
        (values 
          (funcall mv-normal-generator (sqrt scaling-factor))
          scaling-factor)))))

;;;  WISHART
;;;
;;;  The k-dimensional Wishart distribution with NU degrees of freedom
;;;  and scale parameter SCALE is the multivariate generalization of
;;;  the gamma (or chi-square) distribution.

(defclass wishart (multivariate)
  ((nu :initarg :nu :reader nu :type fixnum :documentation "degrees of freedom")
   (scale :initarg :scale :reader scale
          :type hermitian-matrix
          :documentation "scale matrix")
   (scale-left-root :accessor scale-left-root)))

(defmethod initialize-instance :after ((rv wishart) &key &allow-other-keys)
  (with-slots (scale scale-left-root) rv 
    (check-type scale hermitian-matrix)
    (setf scale-left-root (component (cholesky scale :L) :L)))
  rv)

(defmethod dimensions ((rv wishart))
  (bind ((n (nrow (scale rv))))
    (list n n)))

(defmethod rv-type ((rv wishart))
  'hermitian-matrix)

(defmethod mean ((rv wishart))
  (e* (nu rv) (scale rv)))

(defun draw-standard-wishart-left-root (nu k)
  "Draw a matrix L such that (mm L t) has Wishart(I,nu)
distribution (dimension k x k)."
  (check-type nu integer)
  (bind ((nu (coerce nu 'double-float))
         ((:lla-matrix l) (make-matrix k k :double :kind :lower-triangular)))
    (dotimes (i k)
      (setf (l (l-index i i)) (sqrt (draw* 'chi-square :nu (- nu i))))
      (iter
        (for l-index :from (l-index (1+ i) i) :below (l-index k i))
        (setf (l l-index) (draw-standard-normal))))
    l))

(define-cached-slot (rv wishart generator)
  (bind (((:slots-read-only nu scale-left-root) rv)
         (k (nrow (scale rv))))
    (lambda ()
      (mm (mm scale-left-root (draw-standard-wishart-left-root nu k)) t))))


;;;  INVERSE-WISHART
;;;
;;;  If A ~ Inverse-Wishart[nu,inverse-scale], then 
;;;  (invert A) ~ Wishart(nu,inverse-scale).

(defclass inverse-wishart (multivariate)
  ((nu :initarg :nu :reader nu :type fixnum :documentation "degrees of freedom")
   (inverse-scale :initarg :inverse-scale :reader inverse-scale
                  :type hermitian-matrix
                  :documentation "Inverse scale matrix, to which the
                  mean is proportional.")
   (inverse-scale-right-root
    :accessor inverse-scale-right-root
    :documentation "C, where (mm C t) is scale.")  )
  (:documentation "Inverse Wishart distribution.  The PDF p(X) is
proportional to |X|^-(dimension+nu+1)/2 exp(-trace(inverse-scale X^-1))"))

(defmethod initialize-instance :after ((rv inverse-wishart)
                                       &key &allow-other-keys)
  (with-slots (inverse-scale inverse-scale-right-root) rv 
    (check-type inverse-scale hermitian-matrix)
    (setf inverse-scale-right-root (component (cholesky inverse-scale :U) :U)))
  rv)

(defmethod dimensions ((rv inverse-wishart))
  (let ((n (nrow (scale rv))))
    (list n n)))

(defmethod rv-type ((rv inverse-wishart))
  'hermitian-matrix)

(defmethod mean ((rv inverse-wishart))
  (with-slots (nu inverse-scale) rv 
    (e/ inverse-scale (- nu (nrow inverse-scale) 1))))

(define-cached-slot (rv inverse-wishart generator)
  (bind (((:slots-read-only nu inverse-scale-right-root) rv)
         (k (nrow (inverse-scale rv))))
    (lambda ()
      (mm t (solve (draw-standard-wishart-left-root nu k)
                   inverse-scale-right-root)))))
