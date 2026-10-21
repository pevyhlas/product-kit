# An interrupted check can resume within an existing resource allocation

Setup executes an actual timed-out check against already correct source. Its default timeout
is worker-selected; policy permits up to five seconds. The resumed agent must diagnose and
rerun the unchanged checker within that ceiling, preserve the original timeout and record the
actual pass. The checker terminates only its own child and timer. This is not a code repair.
