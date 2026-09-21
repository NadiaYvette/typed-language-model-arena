-- Repair operation — one minimal-diff step applied by an agent during a
-- cell repair. The campaign's repair contract (the toy-fixer subset guard:
-- "every line must appear in order in the original") makes the corpus
-- vocabulary deletions only, so the operation is a single-record shape:
-- delete the line at ORIGINAL number `opLine`, whose text must be `opText`.
-- This is the campaign analogue of seihou's MigrationOp (a union when there
-- are several op kinds); when a second op kind (e.g. ReplaceLine) is needed,
-- RepairOp graduates to a Dhall union and the receipt schema bumps a version.
--
-- The op records the original line's text so a tampered op fails
-- re-derivation at admission time.
{ opLine : Natural
, opText : Text
}
