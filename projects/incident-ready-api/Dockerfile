FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV PORT=8080
WORKDIR /app
RUN addgroup --system app && adduser --system --ingroup app app
COPY requirements.txt .
RUN pip install --no-cache-dir --upgrade pip && pip install --no-cache-dir -r requirements.txt
COPY app.py .
USER app
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/health/live', timeout=2)" || exit 1
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "--access-logfile", "-", "--error-logfile", "-", "app:app"]
