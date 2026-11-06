#!/usr/bin/env bash
# Resilio Sync для Home Assistant.
# 1) Бэкапы HA (/backup, только чтение) раз в N минут копируются в /share/resilio/ha-backups;
#    хранятся последние keep_backups.
# 2) Resilio Sync синхронизирует эту папку. Два режима:
#    * webui: true (по умолчанию) — веб-интерфейс Resilio на порту из раздела «Сеть» (8888/tcp). Resilio 3.x без активированной
#      лицензии (бесплатной после регистрации или Pro) не синхронизирует — активация делается в интерфейсе,
#      там же добавляется папка /share/resilio/ha-backups. Состояние Resilio хранится между запусками.
#    * webui: false — папка задаётся конфигурацией с ключом из /data/secret (без интерфейса; лицензию так
#      активировать нельзя — для Resilio 3.x подходит, только если лицензия уже есть в хранилище).
set -uo pipefail

OPT=/data/options.json
NAME=$(jq -r '.device_name' "$OPT")
KEEP=$(jq -r '.keep_backups' "$OPT")
INTERVAL=$(jq -r '.copy_interval_minutes' "$OPT")
PORT=$(jq -r '.listening_port' "$OPT")
HOSTS=$(jq -c '.known_hosts // []' "$OPT")
WEBUI=$(jq -r 'if .webui == false then "false" else "true" end' "$OPT")
WEBPORT_OPT=$(jq -r '.webui_port // empty' "$OPT")

SYNC_DIR=/share/resilio/ha-backups
TMP_DIR=/share/resilio/.tmp
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# Смена режима: служебное состояние Resilio и метка папки (.sync/ID) от прежнего ключа мешают — сбрасываем.
MODE="webui=$WEBUI"
if [ "$(cat /data/mode 2>/dev/null)" != "$MODE" ]; then
    log "Режим: $MODE — сбрасываю состояние Resilio от прежнего режима"
    rm -rf /data/.sync "$SYNC_DIR/.sync"
    echo "$MODE" > /data/mode
fi
# В режиме конфигурации состояние сбрасываем при каждом запуске: иначе папка грузится из прошлого sync.dat
# («Selected folder is already added»), а настройки (known_hosts и т.п.) не применяются.
[ "$WEBUI" = "false" ] && rm -rf /data/.sync
mkdir -p /data/.sync "$SYNC_DIR" "$TMP_DIR"

# --- обновление Resilio -------------------------------------------------------
# Resilio в образе — версии на момент сборки. При каждом запуске проверяем официальный apt-репозиторий
# (с подписью Resilio) и ставим новую версию. Нет сети — работаем на текущей. Перезапуск дополнения раз в
# неделю (автоматизация в HA) = автообновление. Версия пишется в /share/resilio/.version (для HA).
rs_version() { dpkg-query -W -f='${Version}' resilio-sync 2>/dev/null || echo "?"; }
OLD_VER=$(rs_version)
if timeout 180 apt-get update -o Dir::Etc::sourcelist=sources.list.d/resilio-sync.list \
        -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0 -qq > /dev/null 2>&1 \
   && timeout 300 apt-get install -y -qq --only-upgrade --no-install-recommends resilio-sync > /dev/null 2>&1; then
    NEW_VER=$(rs_version)
    [ "$NEW_VER" != "$OLD_VER" ] && log "Resilio Sync обновлён: $OLD_VER → $NEW_VER" || log "Resilio Sync $NEW_VER (последняя)"
else
    NEW_VER=$OLD_VER; log "Проверить обновление Resilio не удалось, работаю на $OLD_VER"
fi
rm -rf /var/lib/apt/lists/* 2>/dev/null
PREV_VER=$(cat /share/resilio/.version 2>/dev/null || echo "")
echo "$NEW_VER" > /share/resilio/.version
RS_UPDATED=""
[ -n "$PREV_VER" ] && [ "$PREV_VER" != "$NEW_VER" ] && RS_UPDATED="$PREV_VER"

# --- токен Supervisor (уведомления и события в HA) ---------------------------
# в образах HA с s6-overlay переменные окружения контейнера лежат в /run/s6/container_environment
if [ -z "${SUPERVISOR_TOKEN:-}" ] && [ -r /run/s6/container_environment/SUPERVISOR_TOKEN ]; then
    SUPERVISOR_TOKEN=$(cat /run/s6/container_environment/SUPERVISOR_TOKEN)
fi

# Порт веб-интерфейса — из раздела «Сеть» дополнения (8888/tcp): на него же ведёт кнопка «Открыть веб-интерфейс».
# Устаревшая опция webui_port учитывается, только если Supervisor недоступен.
WEBPORT=""
if [ -n "${SUPERVISOR_TOKEN:-}" ]; then
    WEBPORT=$(curl -fsS -m 10 -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" http://supervisor/addons/self/info 2>/dev/null               | jq -r '.data.network["8888/tcp"] // empty' 2>/dev/null)
fi
if [ -n "$WEBPORT_OPT" ] && [ "$WEBPORT_OPT" != "${WEBPORT:-8888}" ]; then
    log "Опция webui_port ($WEBPORT_OPT) устарела и не используется — порт меняется в разделе «Сеть» дополнения"
fi
WEBPORT=${WEBPORT:-${WEBPORT_OPT:-8888}}
ha_post() {   # ha_post <путь API core> <json>
    [ -n "${SUPERVISOR_TOKEN:-}" ] || return 1
    curl -fsS -o /dev/null -X POST -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" -H "Content-Type: application/json" \
        --data-binary "$2" "http://supervisor/core/api/$1"
}
notify() {    # notify <заголовок> <текст>
    ha_post services/persistent_notification/create \
        "$(jq -n --arg t "$1" --arg m "$(printf '%b' "$2")" '{notification_id: "resilio_sync_key", title: $t, message: $m}')" \
    || log "Не удалось создать уведомление в HA"
}
if [ -n "$RS_UPDATED" ]; then
    ha_post events/resilio_sync_updated "$(jq -n --arg o "$RS_UPDATED" --arg n "$NEW_VER" '{old: $o, new: $n}')" \
    || log "Не удалось отправить событие resilio_sync_updated"
fi

# --- конфигурация Resilio ----------------------------------------------------
if [ "$WEBUI" = "true" ]; then
    WUSER=$(jq -r '.webui_user // ""' "$OPT"); WPASS=$(jq -r '.webui_password // ""' "$OPT")
    jq -n --arg name "$NAME" --argjson port "$PORT" --arg web "0.0.0.0:$WEBPORT" --arg u "$WUSER" --arg p "$WPASS" '{
      device_name: $name, listening_port: $port,
      storage_path: "/data/.sync", pid_file: "/data/rslsync.pid", use_upnp: false,
      directory_root: "/share/resilio/",
      webui: ({ listen: $web } + (if $u != "" and $p != "" then {login: $u, password: $p} else {} end))
    }' > /data/sync.conf
    HOST_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n 1)
    URL="http://${HOST_IP:-<IP Home Assistant>}:$WEBPORT/gui/"
    log "=================================================================="
    log "Веб-интерфейс Resilio: $URL"
    log "1) задайте логин и пароль; 2) активируйте лицензию (Resilio 3.x без неё не синхронизирует):"
    log "   бесплатная — регистрация на resilio.com/sync/register, или ваша Pro — «Связать устройство»;"
    log "3) «+» → «Стандартная папка» → $SYNC_DIR, затем «Поделиться» → ключ «Только чтение» для ПК."
    log "Бэкапы копируются в эту папку автоматически (хранится: $KEEP)."
    log "=================================================================="
    notify "Resilio Sync: настройте в веб-интерфейсе" \
        "Откройте [$URL]($URL)\n\n1. Задайте логин и пароль.\n2. Активируйте лицензию — Resilio 3.x без неё не синхронизирует: бесплатная после регистрации на resilio.com/sync/register или ваша Pro («Связать устройство»).\n3. «+» → «Стандартная папка» → \`$SYNC_DIR\`, затем «Поделиться» → ключ «Только чтение» — его добавьте в Resilio на ПК.\n\nБэкапы HA копируются в эту папку автоматически."
else
    if [ ! -s /data/secret ]; then
        rslsync --generate-secret > /data/secret
        log "Создан новый ключ папки"
    fi
    SECRET=$(tr -d '[:space:]' < /data/secret)
    RO_SECRET=$(rslsync --get-ro-secret "$SECRET" | tr -d '[:space:]')
    jq -n --arg name "$NAME" --argjson port "$PORT" --arg secret "$SECRET" --arg dir "$SYNC_DIR" --argjson hosts "$HOSTS" '{
      device_name: $name, listening_port: $port,
      storage_path: "/data/.sync", pid_file: "/data/rslsync.pid", use_upnp: false,
      shared_folders: [{
        secret: $secret, dir: $dir,
        use_relay_server: true, use_tracker: true, search_lan: true,
        use_sync_trash: true, overwrite_changes: false,
        known_hosts: $hosts
      }]
    }' > /data/sync.conf
    log "=================================================================="
    log "Папка синхронизации: $SYNC_DIR (бэкапов хранится: $KEEP)"
    log "Ключ ТОЛЬКО ДЛЯ ЧТЕНИЯ — добавьте его в Resilio на ПК / сервере:"
    log "    $RO_SECRET"
    log "(Resilio → «+» → «Ввести ключ или ссылку»)"
    log "=================================================================="
    notify "Resilio Sync: ключ для чтения" \
        "Добавьте папку с бэкапами HA в Resilio на ПК или сервере: «+» → «Ввести ключ или ссылку».\n\nКлюч только для чтения:\n\`$RO_SECRET\`\n\nПапка в HA: $SYNC_DIR"
fi

# подробный журнал Resilio — только по опции debug (по умолчанию маска FFFFFFFF засоряет журнал дополнения)
if [ "$(jq -r '.debug // false' "$OPT")" = "true" ]; then
    echo FFFFFFFF > /data/.sync/debug.txt; log "Подробный журнал Resilio включён (debug)"
else
    echo 0 > /data/.sync/debug.txt
fi

# --- копирование бэкапов ----------------------------------------------------
backup_name() {
    # Новые версии HA называют файлы понятно («Automatic_backup_2026.11.0_2026-11-06_05.01_….tar») — оставляем.
    # Старые — slug из 8 символов («a1b2c3d4.tar»): добавляем дату и имя из backup.json внутри архива.
    local base meta date name
    base=$(basename "$1" .tar)
    if ! [[ "$base" =~ ^[0-9a-f]{8}$ ]]; then echo "$base.tar"; return 0; fi
    meta=$(tar -xOf "$1" ./backup.json 2>/dev/null || tar -xOf "$1" backup.json 2>/dev/null)
    date=$(echo "$meta" | jq -r '.date // empty' 2>/dev/null | sed -E 's/^([0-9]{4}-[0-9]{2}-[0-9]{2})T([0-9]{2}):([0-9]{2}).*/\1_\2\3/')
    name=$(echo "$meta" | jq -r '.name // "backup"' 2>/dev/null | tr -cs 'A-Za-z0-9._-' '_' | sed 's/_$//')
    [ -n "$date" ] || date=$(date -r "$1" '+%Y-%m-%d_%H%M')
    echo "${date}_${name:-backup}_${base}.tar"
}

copy_loop() {
    while true; do
        # только последние KEEP бэкапов HA — иначе старые копировались бы и тут же удалялись
        while IFS= read -r src; do
            dst=$(backup_name "$src")
            [ -e "$SYNC_DIR/$dst" ] && continue
            # cp -p: дата файла = дата бэкапа, по ней ниже определяются самые старые
            if cp -p "$src" "$TMP_DIR/$dst" && mv "$TMP_DIR/$dst" "$SYNC_DIR/$dst"; then
                log "Скопирован бэкап: $dst"
            else
                rm -f "$TMP_DIR/$dst"; log "Ошибка копирования: $src"
            fi
        done < <(ls -1t /backup/*.tar 2>/dev/null | head -n "$KEEP")
        # старше KEEP — удаляем (у других устройств они уйдут в архив Resilio .sync/Archive)
        ls -1t "$SYNC_DIR"/*.tar 2>/dev/null | tail -n +"$((KEEP + 1))" | while IFS= read -r old; do
            rm -f "$old"; log "Удалён старый бэкап: $(basename "$old")"
        done
        sleep "$((INTERVAL * 60))"
    done
}

# --- автоприменение лицензии ---------------------------------------------------
# Файл лицензии (*.btskey) в /share/resilio/ применяется через API веб-интерфейса (action=applylicensefile,
# path — путь на этом устройстве). Нужны логин/пароль интерфейса из опций. Повторно — только если файл сменился
# или сброшено состояние Resilio (метка лежит в /data/.sync).
apply_license() {
    local lic sum api tok resp i
    lic=$(ls -1t /share/resilio/*.btskey 2>/dev/null | head -n 1)
    [ -n "$lic" ] || return 0
    if [ -z "${WUSER:-}" ] || [ -z "${WPASS:-}" ]; then
        log "Есть файл лицензии $(basename "$lic"), но не заданы webui_user/webui_password — применить автоматически нельзя"
        return 0
    fi
    sum=$(sha256sum "$lic" | cut -c1-16)
    [ "$(cat /data/.sync/license_applied 2>/dev/null)" = "$sum" ] && return 0
    api="http://127.0.0.1:$WEBPORT/gui"
    for i in $(seq 1 30); do   # ждём, пока поднимется веб-интерфейс
        tok=$(curl -fsS -m 5 -u "$WUSER:$WPASS" -c /tmp/rs.cookie -b /tmp/rs.cookie "$api/token.html" 2>/dev/null \
              | sed -n "s/.*<div id='token'[^>]*>\([^<]*\)<.*/\1/p")
        [ -n "$tok" ] && break; sleep 2
    done
    if [ -z "$tok" ]; then log "Лицензия: веб-интерфейс не ответил (проверьте webui_user/webui_password)"; return 0; fi
    resp=$(curl -fsS -m 30 -u "$WUSER:$WPASS" -c /tmp/rs.cookie -b /tmp/rs.cookie -G "$api/" \
           --data-urlencode "token=$tok" --data-urlencode "action=applylicensefile" --data-urlencode "path=$lic" 2>&1)
    if [ "$(echo "$resp" | jq -r '(.value.error // .error // 0) | tostring' 2>/dev/null || echo fail)" != "0" ]; then
        log "Лицензия: Resilio отклонил файл $(basename "$lic"): $(echo "$resp" | head -c 300)"
    else
        echo "$sum" > /data/.sync/license_applied
        log "Лицензия применена из $(basename "$lic")"
        info=$(curl -fsS -m 15 -u "$WUSER:$WPASS" -c /tmp/rs.cookie -b /tmp/rs.cookie -G "$api/" \
               --data-urlencode "token=$tok" --data-urlencode "action=getlicenseinfo" 2>/dev/null | head -c 300)
        [ -n "$info" ] && log "Лицензия: $info"
    fi
    rm -f /tmp/rs.cookie
}

copy_loop &
log "Запуск Resilio Sync"
rslsync --nodaemon --config /data/sync.conf &
RS_PID=$!
trap 'kill -TERM "$RS_PID" 2>/dev/null' TERM INT
[ "$WEBUI" = "true" ] && apply_license
wait "$RS_PID"
