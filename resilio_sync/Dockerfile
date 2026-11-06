ARG BUILD_FROM
FROM ${BUILD_FROM}

# Resilio Sync ставится из официального apt-репозитория Resilio (пакет проверяется подписью Resilio).
# В репозиторий дополнения бинарник не входит. CDN с архивами (download-cdn.resilio.com) из некоторых
# регионов отвечает 404, а apt-репозиторий доступен.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl gnupg jq tar \
    && curl -fsSL https://linux-packages.resilio.com/resilio-sync/key.asc \
       | gpg --dearmor -o /usr/share/keyrings/resilio-sync.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/resilio-sync.gpg] https://linux-packages.resilio.com/resilio-sync/deb resilio-sync non-free" \
       > /etc/apt/sources.list.d/resilio-sync.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends resilio-sync \
    && rm -rf /var/lib/apt/lists/* \
    && command -v rslsync

COPY run.sh /run.sh
RUN chmod a+x /run.sh

CMD [ "/run.sh" ]
