import os

os.environ.setdefault("STORE", "memory")  # app.main builds an app at import; never touch GCP in tests
