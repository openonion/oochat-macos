FROM python:3.11-slim

RUN useradd --create-home --uid 1000 appuser

WORKDIR /app

RUN apt-get update \
 && apt-get install -y --no-install-recommends chromium \
 && ln -sf /usr/bin/chromium /usr/bin/google-chrome \
 && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir --retries 10 --timeout 120 -r requirements.txt

COPY . .

RUN chmod 0555 /app/docker/entrypoint.sh \
 && ln -s /app/docker/entrypoint.sh /usr/local/bin/connectonion-entrypoint \
 && mkdir -p /home/appuser/.co /agent-work \
 && chown -R appuser:appuser /app /home/appuser /agent-work
USER appuser

ENV PYTHONUNBUFFERED=1
ENV CONNECTONION_HOST_PORT=8000

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD python -c "import os, urllib.request; port = os.environ.get('CONNECTONION_HOST_PORT', '8000'); urllib.request.urlopen('http://127.0.0.1:' + port + '/health', timeout=4)" || exit 1

ENTRYPOINT ["connectonion-entrypoint"]
CMD ["python", "/app/host_agent.py"]
