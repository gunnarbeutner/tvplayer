FROM python:3.13-alpine

WORKDIR /app

COPY requirements.txt ./
RUN pip install --no-cache-dir --requirement requirements.txt

COPY announce.py guide_cache.py ./

RUN addgroup -S tvplayer \
    && adduser -S -G tvplayer tvplayer \
    && mkdir -p /data \
    && chown tvplayer:tvplayer /data
USER tvplayer

ENV PYTHONUNBUFFERED=1

VOLUME ["/data"]
EXPOSE 49382/tcp

CMD ["python", "/app/announce.py"]
