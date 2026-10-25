# Resume rechecks a changed shared contract and a deployment-dependent task

An old task expects v1, while another PR changed the canonical interface to v2. The new interface
is merged but explicitly not deployed. The worker must preserve the new contract, leave dependent
client work blocked, and complete the independent ready greeting task. Scratch is absent.
