# MKTP follow-ups that needed T.800 text (open)

Source item moved from PLAN.md on 2026-10-14. The T.800 (11/2015) text was pulled on 2026-10-11 by the route in LEARNINGS (2026-09-16 entry); the clauses are extracted verbatim into docs/T800_JP2H_RCT_MARKER_PLACEMENT_VERBATIM.md once read.

MKTP follow-ups needing T.800 text before a severity is chosen (each red-first once the clause is in hand): ihdr first in jp2h (I.5.3.1) and at least one colr box (I.5.3.3, Table I.4; the unit-test JP2 helpers emit colr-less jp2h and must change first); MCT = 1 with fewer than 3 or geometrically mismatched components (G.2; decode already refuses); COD/COC/QCD/QCC/RGN in a tile-part header other than the first (Table A.1 placement; WARN 145 today). B.10.7 and D.4.1-D.4.2 are settled (2026-10-12, checked item above). The T.800 PDF text is obtainable by the same route as the Annex E extracts (LEARNINGS, 2026-09-16 entry on reaching the reference material): pull the remaining clauses that way instead of waiting.

## Outcome (2026-10-14)

The clauses were read from the cached extraction and recorded verbatim in
docs/T800_JP2H_RCT_MARKER_PLACEMENT_VERBATIM.md. Every row turned out to be a
proven violation, implemented red-first as FAIL 141 (jp2_invalid_codestream)
with the clause in the detail:

- jp2h must start with ihdr (I.5.3.1); at least one colr box (I.5.3); colr
  boxes contiguous (I.5.3); the first colr box must use METH 1 or 2 with a
  Table I.10 EnumCS (I.3.3), while later colr boxes stay unflagged (ISO
  file5/file7 shape). The unit-test JP2 shells now carry a greyscale colr.
- SGcod MCT 1 with fewer than three components is undecodable (Table A.17),
  and components 0..2 with unequal XRsiz/YRsiz or Ssiz violate G.2/G.3.
- COD, COC, QCD, QCC and RGN in a tile-part header with TPsot > 0 (A.6.1 to
  A.6.5 "shall be found only in the first tile-part", Figure A.5), and a POC
  whose first appearance for a tile is a later part (A.6.6). These replaced
  the former c145 WARN for a later-part COD/QCD/QCC/COC/RGN.
