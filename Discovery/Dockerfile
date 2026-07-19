FROM python:3.13-alpine

WORKDIR /app

COPY requirements.txt ./
RUN pip install --no-cache-dir --requirement requirements.txt

COPY announce.py ./

RUN addgroup -S tvplayer && adduser -S -G tvplayer tvplayer
USER tvplayer

ENV PYTHONUNBUFFERED=1

CMD ["python", "/app/announce.py"]
