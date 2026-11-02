*---------------------------------------------------------------
* pathtab.s -- THE default command search path, in one place.
*
* Data only, and its own module for exactly that reason: two
* programs need this list and neither should need the other's
* code to get it. src/bin/sh.s uses it when `PATH` is unset;
* src/liba/pathres.s uses it when the ENVIRONMENT has no PATH.
* A liba module links WHOLE (docs/REL-LIBA-SPIKE.md), so putting
* the table beside the resolver would drag PATHRSLV into `sh`,
* which has its own resolver and would never call it.
*
* IT USED TO LIVE IN sh.s AND ONLY THERE. That was fine while
* the shell was the only thing that resolved a command word.
* It stopped being fine when `find -exec` needed the same
* answer: a second copy of a POLICY list is a second thing to
* forget to change.
*
* ':'-SEPARATED, NUL-TERMINATED -- the Unix format, and the same
* format a user's own `PATH` arrives in. It was NUL-separated
* with a double-NUL terminator until 2026-08-26, which meant
* sh.s carried TWO parsers: one that copied this table verbatim
* and one that split a `PATH` value on ':'. One format means one
* parser, and the shared one is the one that already had to
* handle real user input.
*
* A TRAILING '/' ON EACH ENTRY IS NOT REQUIRED of a user's PATH
* and is not required here either -- both consumers append one
* when it is missing. It is written here anyway because that is
* what the entries mean.
*---------------------------------------------------------------
PATHTAB     asc   "/bin/"
            dfb   0
