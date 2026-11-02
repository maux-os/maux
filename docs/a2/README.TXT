maux design notes -- Apple II readable reference
================================================================

These files hold the long-form design rationale that used to
live in source-file header comments.  Each one is named for
the module it documents:

    K.*   src/kernel        L.*   src/liba
    B.*   src/bin           T.*   src/test
    I.*   include

Two reasons they live here rather than in the source.

1. Real Merlin-8 rejects source lines longer than 64
   characters ("Operand too long in line: N", and it fires on
   comment lines too).  Self-hosting means the tree has to be
   assemblable by the real assembler, so the source cannot
   carry wide tables and hanging-indent prose.

2. src/kernel/bankcopy.s had grown 311 lines of header essay
   before its first line of code.  That is a document, and it
   should be filed as one.

Format: plain ASCII, no markdown, prose wrapped at 64 columns.
Tables and diagrams keep their natural width -- 64 characters
is an assembler limit, not a display one, and these files are
read, not assembled.  They are ProDOS TXT once shipped, and
the filenames are ProDOS-legal (15 chars, A-Z 0-9 and '.').

The source keeps its title block, its per-routine interface
comments (IN/OUT/CLOBBERS) and any short note needed to read
the code in front of you.  Only the essays moved.
