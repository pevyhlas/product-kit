# A retiring implementation still needs a minimal supported-path safety fix

The approved replacement does not permit abandoning a current privacy defect or disabling a
supported path. One repair increment is authorized. Fix the leaking legacy renderer, verify its
existing output/security check, and record the carry-forward/removal rationale without adding
optional legacy history features or a migration. This guards against overcorrecting drift by
refusing every legacy repair.
