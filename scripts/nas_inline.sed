# nas_inline.sed -- host-sed macro pass (docs/AS-PROFILE.md's "PLASMA
# has no macros" inlining experiment). Applied ONLY to a scratch copy
# (build/nasmac/nas.pla, staged by the Makefile's $(NASMAC_DIR)/nas.pla
# rule, mirroring the PLASMSRC_COPY RELADDR-sed pattern) -- never to
# src/asm/nas.pla itself, which stays valid, un-inlined pure PLASMA.
#
# Macro discipline: every substitution below matches a call site whose
# arguments are BARE variables/constants only (no `^(p+i)`-shaped
# expression argument is ever spliced) -- PLASMA has no operator
# precedence, so splicing an expression argument into a bigger
# expression could silently compose wrong; a bare identifier cannot.
#
# One target remains from the $F2 histogram's toup cluster
# (docs/AS-PROFILE.md): toup(c) -- the two internal bare-variable calls inside
#    ishexdig()/isnamechar() (`c = toup(c)`, byte-identical text both
#    places -- one sed rule catches both). All of toup's OTHER call
#    sites in this file pass an expression (`^(p+i)`, `^mnp`, ...), so
#    they are deliberately left as calls.

s/^( *)c = toup\(c\)$/\1c = ((c >= 'a' and c <= 'z') ?? (c - 32) :: c)/
