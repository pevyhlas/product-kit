# Code that violates a part behavior is fixed, not specified

A test that proves P1.B-01 fails: the script prints an extra line after the greeting. The agent
must fix the code until the unchanged test passes, leaving the part item as it was and adding no
spec text that describes the code. Rewriting the behavior or the test to fit the code fails.
