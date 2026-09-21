-- One source state as the oracle sees it: the bytes and their diagnostics,
-- rendered in the exact "<path>:<line>: warning: [W-code] message" shape of
-- Campaign.Oracle / Toy.Fixer.Domain showDiagnostic. A state with no
-- diagnostics is a passing state.
{ ssSource : Text
, ssDiagnostics : List Text
}
