#!/usr/bin/env bash
# Resilio Sync для Home Assistant.
# 1) Бэкапы HA (/backup, только чтение) раз в N минут копируются в /share/resilio/ha-backups
#    с понятными именами «ГГГГ-ММ-ДД_ЧЧММ_<имя>_<slug>.tar»; хранятся последние keep_backups.
# 2) Resilio Sync синхронизирует эту папку. Ключ папки создаётся при первом запуске (/data/secret),
#    ключ «только чтение» для других устройств печатается в журнал дополнения.
set -uo pipefail

OPT=/data/options.json
NAME=$(jq -r '.device_name' "$OPT")
KEEP=$(jq -r '.keep_backups' "$OPT")
INTERVAL=$(jq -r '.copy_interval_minutes' "$OPT")
PORT=$(jq -r '.listening_port' "$OPT")

SYNC_DIR=/share/resilio/ha-backups
TMP_DIR=/share/resilio/.tmp
mkdir -p /data/.sync "$SYNC_DIR" "$TMP_DIR"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# --- ключ папки -------------------------------------------------------------
if [ ! -s /data/secret ]; then
    rslsync --generate-secret > /data/secret
    log "Создан новый ключ папки"
fi
SECRET=$(tr -d '[:space:]' < /data/secret)
RO_SECRET=$(rslsync --get-ro-secret "$SECRET" | tr -d '[:space:]')

# --- конфигурация Resilio ----------------------------------------------------
jq -n --arg name "$NAME" --argjson port "$PORT" --arg secret "$SECRET" --arg dir "$SYNC_DIR" '{
  device_name: $name,
  listening_port: $port,
  storage_path: "/data/.sync",
  pid_file: "/data/rslsync.pid",
  use_upnp: false,
  shared_folders: [{
    secret: $secret, dir: $dir,
    use_relay_server: true, use_tracker: true, search_lan: true,
    use_sync_trash: true, overwrite_changes: false
  }]
}' > /data/sync.conf

log "=================================================================="
log "Папка синхронизации: $SYNC_DIR (бэкапов хранится: $KEEP)"
log "Ключ ТОЛЬКО ДЛЯ ЧТЕНИЯ — добавьте его в Resilio на ПК / сервере:"
log "    $RO_SECRET"
log "(Resilio → «+» → «Ввести ключ или ссылку»)"
log "=================================================================="

# тот же ключ — уведомлением в HA (видят только администраторы), чтобы не искать в журнале
# в образах HA с s6-overlay переменные окружения контейнера лежат в /run/s6/container_environment
if [ -z "${SUPERVISOR_TOKEN:-}" ] && [ -r /run/s6/container_environment/SUPERVISOR_TOKEN ]; then
    SUPERVISOR_TOKEN=$(cat /run/s6/container_environment/SUPERVISOR_TOKEN)
fi
if [ -z "${SUPERVISOR_TOKEN:-}" ]; then
    log "Нет SUPERVISOR_TOKEN — уведомление в HA не создано (ключ — выше в журнале)"
else
    jq -n --arg k "$RO_SECRET" --arg d "$SYNC_DIR" '{notification_id: "resilio_sync_key", title: "Resilio Sync: ключ для чтения",
      message: ("Добавьте папку с бэкапами HA в Resilio на ПК или сервере: «+» → «Ввести ключ или ссылку».\n\nКлюч только для чтения:\n`" + $k + "`\n\nПапка в HA: " + $d)}' \
    | curl -fsS -o /dev/null -X POST -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" -H "Content-Type: application/json" \
        --data-binary @- http://supervisor/core/api/services/persistent_notification/create \
    || log "Не удалось создать уведомление в HA (ключ — выше в журнале)"
fi

# подробный отладочный журнал Resilio выключаем (по умолчанию маска FFFFFFFF засоряет журнал дополнения)
echo 0 > /data/.sync/debug.txt

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
        copied=0
        # только последние KEEP бэкапов HA — иначе старые копировались бы и тут же удалялись
        while IFS= read -r src; do
            dst=$(backup_name "$src")
            [ -e "$SYNC_DIR/$dst" ] && continue
            # cp -p: дата файла = дата бэкапа, по ней ниже определяются самые старые
            if cp -p "$src" "$TMP_DIR/$dst" && mv "$TMP_DIR/$dst" "$SYNC_DIR/$dst"; then
                copied=$((copied + 1)); log "Скопирован бэкап: $dst"
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

copy_loop &
log "Запуск Resilio Sync"
exec rslsync --nodaemon --config /data/sync.conf
