# One image, two entry points: the API (default) and the ingest job (python -m app.ingest).
FROM python:3.12-slim AS build
WORKDIR /build
RUN python -m venv /venv
ENV PATH="/venv/bin:$PATH"
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

FROM python:3.12-slim
ARG APP_VERSION=dev
ENV PATH="/venv/bin:$PATH" PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 APP_VERSION=${APP_VERSION} PORT=8080
RUN useradd --create-home --uid 10001 app
WORKDIR /srv
COPY --from=build /venv /venv
COPY app ./app
USER app
EXPOSE 8080
# Cloud Run sets PORT; exec so uvicorn gets SIGTERM directly and shuts down cleanly.
CMD exec uvicorn app.main:app --host 0.0.0.0 --port "$PORT" --proxy-headers
