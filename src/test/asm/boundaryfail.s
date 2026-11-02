* boundaryfail.s -- deliberate expected +128 branch failure.
        org   $2000
        bcc   TOO_FAR
        ds    128
TOO_FAR nop
