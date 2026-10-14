# Entropy-tail discriminator (open)

Source item moved from PLAN.md on 2026-10-14. Research record: docs/mktp-research/jpeg2000.md sections 4.5, 4.6 and 6.

Sharper discriminator for the entropy tail: a tail of 3 is the field class and cannot be flagged by length alone (e1_colr bolter and g3_colr shotgun mutants measure exactly 3). Candidate: check the unread bytes against the FLUSH pattern (D.4.2 drops a trailing 0xFF, so a conforming tail is the coder's own output) before treating them as surplus.
