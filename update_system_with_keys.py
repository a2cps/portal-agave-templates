#!/usr/bin/env python
import sys

with open(sys.argv[1]) as f:
    definition = f.read()

SSH_PUB_KEY = sys.argv[2]
SSH_PRIV_KEY = sys.argv[3]

definition = definition.replace("$SSH_PUB_KEY", SSH_PUB_KEY).replace(
    "$SSH_PRIV_KEY", SSH_PRIV_KEY.replace("\n", "\\n")
)

print(definition)
