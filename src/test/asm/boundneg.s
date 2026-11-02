* boundneg.s -- deliberate expected -129 branch failure.
        org   $2200
NEGBASE nop
        ds    126
        bcc   NEGBASE
