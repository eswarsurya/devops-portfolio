"""Generate a team API key. Prints the key once (give it to the team) and the hash (put in config)."""

import secrets
import sys

from .config import hash_key

if __name__ == "__main__":
    team = sys.argv[1] if len(sys.argv) > 1 else "team"
    key = f"gw-{team}-{secrets.token_urlsafe(24)}"
    print(f"key (share with {team}, shown once): {key}")
    print(f"key_sha256 (put in gateway.yaml):   {hash_key(key)}")
