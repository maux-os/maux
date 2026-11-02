* noxc.s -- BRA is 65C02-only and XC is intentionally absent.
* It must fail after a preceding warm NCUT launch of boundary.s,
* which has XC.
        org   $2000
        bra   TARGET
TARGET  nop
