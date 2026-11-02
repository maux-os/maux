*---------------------------------------------------------------
* asputinc.s -- the file src/test/asputtest.s `put`s. Staged on
* the image as /mnt/MAUX/PUTINC.S, with the parent's put line
* rewritten to that absolute path (build_as_image.py), the same
* way build_maux_src_image.py rewrites the real tree's.
*---------------------------------------------------------------
PUTSUB      clc
            adc   #$10
            rts
