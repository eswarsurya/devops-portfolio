# Runs the app's lint and unit tests inside a clean container.
# The build fails, and so does the pipeline stage, if any check fails.
FROM python:3.12-slim
WORKDIR /src
COPY requirements.txt requirements-dev.txt ./
RUN pip install --no-cache-dir -r requirements-dev.txt
COPY . .
RUN ruff check . && ruff format --check . && pytest -q
