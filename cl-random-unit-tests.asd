(defsystem :cl-random-unit-tests
  :description "Unit tests for CL-RANDOM."
  :version "alpha"
  :author "Tamas K Papp <tkpapp@gmail.com"
  :license "Same as CL-RANDOM--this is part of the CL-RANDOM library."
  :serial t
  :components
  ((:module 
    "package-init"
    :pathname #P"unit-tests/"
    :components
    ((:file "package")))
   (:module
    "utilities-and-setup"
    :pathname #P"unit-tests/"
    :components
    ((:file "utilities")
     (:file "setup")))
   (:module 
    "tests"
    :pathname #P"unit-tests/"
    :components
    ((:file "log-infinity-tests")
     (:file "special-functions-tests")
     (:file "univariate-tests"))))
  :depends-on
  (:cl-utilities :iterate :metabang-bind :anaphora :lla :cl-random
                 :lift :cl-num-utils :tpapp-utils))
