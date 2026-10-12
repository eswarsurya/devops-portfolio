import logging, os, time
from flask import Flask, jsonify

logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"))
logger = logging.getLogger("incident-ready-api")
STARTED_AT = time.time()

def create_app(test_config=None):
    app = Flask(__name__)
    app.config.update(test_config or {})

    @app.get("/")
    def index():
        return jsonify(service="incident-ready-api", status="running")

    @app.get("/health/live")
    def liveness():
        return jsonify(status="ok", check="liveness"), 200

    @app.get("/health/ready")
    def readiness():
        if os.getenv("DEPENDENCY_STATUS", "ok").lower() != "ok":
            logger.warning("readiness_failed dependency=demo-dependency")
            return jsonify(status="not_ready", dependency="demo-dependency"), 503
        return jsonify(status="ready"), 200

    @app.get("/api/v1/status")
    def status():
        return jsonify(service="incident-ready-api",
                       version=os.getenv("APP_VERSION", "local"),
                       uptime_seconds=round(time.time() - STARTED_AT, 2))

    @app.errorhandler(404)
    def not_found(_error):
        return jsonify(error="not_found", message="Endpoint does not exist"), 404

    return app

app = create_app()

if __name__ == "__main__":
    app.run(host="127.0.0.1", port=int(os.getenv("PORT", "8080")), debug=False)
