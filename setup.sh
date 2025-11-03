#!/usr/bin/env bash
# =============================================================================
# setup.sh
# WordPress Multi-site generator (uses master-template/)
# - Generates site-<short>/ from master-template/site-template
# - Generates nginx/<domain>.conf from master-template/nginx/site-template.conf
# - Ensures nginx/includes/ files exist (copy from master-template if needed)
# - Appends dynamic cache zones into nginx/includes/fastcgi-cache.conf
# - Appends services (php_*, redis_*) and volumes into docker-compose.yml
# - Appends SITEx entries into .env and DB create statements into scripts/init-databases.sql
# - Issues Let's Encrypt certs (standalone) then copies to ssl/live/<domain>
# - Installs root crontab entries to renew using webroot
# - Supports dry-run (--dry) and basic rollback on error
# =============================================================================
set -euo pipefail

# ---------- config ----------
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
MASTER="${BASE_DIR}/master-template"
TEMPLATE_SITE="${MASTER}/site-template"
TEMPLATE_NGINX="${MASTER}/nginx/site-template.conf"
MASTER_INCLUDES="${MASTER}/nginx/includes"
TARGET_NGINX_DIR="${BASE_DIR}/nginx"
TARGET_INCLUDES_DIR="${TARGET_NGINX_DIR}/includes"
FASTCGI_MASTER="${MASTER_INCLUDES}/fastcgi-cache.conf"
FASTCGI_TARGET="${TARGET_INCLUDES_DIR}/fastcgi-cache.conf"
SSL_PARAMS_MASTER="${MASTER_INCLUDES}/ssl-params.conf"
SSL_PARAMS_TARGET="${TARGET_INCLUDES_DIR}/ssl-params.conf"
COMPOSE_FILE="${BASE_DIR}/docker-compose.yml"
ENV_FILE="${BASE_DIR}/.env"
DB_INIT="${BASE_DIR}/scripts/init-databases.sql"
SSL_DIR="${BASE_DIR}/ssl/live"
DRY_RUN=false
BACKUP_DIR="${BASE_DIR}/.setup_backups_$(date +%s)"

# Colors
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

# ---------- helpers ----------
log() { echo -e "${GREEN}>>${NC} $*"; }
warn() { echo -e "${YELLOW}!!${NC} $*"; }
err() { echo -e "${RED}!!${NC} $*"; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { err "Requirement missing: $1"; exit 1; }
}

safe_mkdir() {
  if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY] mkdir -p $*"
  else
    mkdir -p "$@"
  fi
}

backup_file() {
  local f="$1"
  if [[ -f "$f" ]]; then
    safe_mkdir "$BACKUP_DIR"
    if [[ "$DRY_RUN" == true ]]; then
      echo "[DRY] cp $f $BACKUP_DIR/"
    else
      cp -a "$f" "$BACKUP_DIR/"
    fi
  fi
}

# ---------- rollback ----------
on_error() {
  err "Error occurred. Attempting basic rollback..."
  if [[ -d "$BACKUP_DIR" ]]; then
    warn "Backup dir exists: $BACKUP_DIR (you can inspect and restore manually)"
  fi
  err "Rollback not fully automatic. Check $BACKUP_DIR and revert if needed."
  exit 1
}
trap on_error ERR

# ---------- parse flags ----------
usage() {
  cat <<EOF
Usage: $0 [--dry] [--auto]
  --dry     : dry-run (no destructive changes)
  --auto    : non-interactive (generate from args; not implemented)
EOF
  exit 1
}

for arg in "$@"; do
  case "$arg" in
    --dry) DRY_RUN=true ;;
    --help) usage ;;
    *) ;;
  esac
done

# ---------- checks ----------
log "Checking system prerequisites..."
for cmd in docker docker-compose certbot openssl wget sed awk grep; do
  require_cmd "$cmd"
done

# ensure master template present
if [[ ! -d "$MASTER" ]]; then
  err "master-template/ not found in $BASE_DIR. Abort."
  exit 1
fi
if [[ ! -f "$TEMPLATE_NGINX" ]] || [[ ! -d "$TEMPLATE_SITE" ]]; then
  err "Required master-template files missing (nginx/site-template.conf or site-template/)."
  exit 1
fi

# ---------- input ----------
read -rp "Berapa site yang ingin dibuat? [contoh: 2] : " TOTAL
if ! [[ "$TOTAL" =~ ^[0-9]+$ ]] || [[ "$TOTAL" -lt 1 ]]; then
  err "Jumlah tidak valid."
  exit 1
fi

DOMAINS=()
for ((i=1;i<=TOTAL;i++)); do
  while true; do
    read -rp "Masukkan domain ke-$i (contoh: example.com): " D
    if [[ -z "$D" ]]; then
      warn "Domain tidak boleh kosong."
      continue
    fi
    DOMAINS+=("$D")
    break
  done
done

read -rp "Jalankan langsung docker compose up setelah setup? [Y/n]: " DOCKER_NOW
DOCKER_NOW=${DOCKER_NOW:-Y}

# ---------- PREPARE target includes if missing ----------
log "Ensuring nginx/includes/ exists and global templates are present..."
if [[ "$DRY_RUN" == true ]]; then
  echo "[DRY] ensure $TARGET_INCLUDES_DIR and copy includes from master if missing"
else
  safe_mkdir "$TARGET_INCLUDES_DIR"
  # copy ssl params if not exists
  if [[ ! -f "$SSL_PARAMS_TARGET" ]]; then
    if [[ -f "$SSL_PARAMS_MASTER" ]]; then
      cp -a "$SSL_PARAMS_MASTER" "$SSL_PARAMS_TARGET"
      log "Copied ssl-params.conf to nginx/includes/"
    else
      warn "Master ssl-params.conf missing; ensure global SSL settings exist."
    fi
  fi
  # create or initialize fastcgi target from master-template (with placeholder)
  if [[ ! -f "$FASTCGI_TARGET" ]]; then
    if [[ -f "$FASTCGI_MASTER" ]]; then
      cp -a "$FASTCGI_MASTER" "$FASTCGI_TARGET"
      log "Copied fastcgi-cache.conf template to nginx/includes/"
    else
      # create minimal base if master not exist
      cat > "$FASTCGI_TARGET" <<'EOF'
# FastCGI cache (generated)
{{CACHE_ZONES}}
fastcgi_cache_key "$scheme$request_method$host$request_uri";
fastcgi_ignore_headers Cache-Control Expires Set-Cookie;
fastcgi_cache_methods GET HEAD;
fastcgi_cache_lock on;
fastcgi_cache_lock_timeout 5s;
fastcgi_cache_background_update on;
fastcgi_cache_use_stale error timeout updating invalid_header http_500 http_503;
EOF
      log "Created minimal fastcgi-cache.conf"
    fi
  fi
fi

# ---------- utility to compute short name and upper ----------
short_name(){ echo "$1" | awk -F. '{print $1}'; }
upper(){ echo "$1" | tr '[:lower:]' '[:upper:]'; }

# ---------- generate per-domain pieces ----------
for DOMAIN in "${DOMAINS[@]}"; do
  SHORT=$(short_name "$DOMAIN")
  UPPER=$(upper "$SHORT")
  SITE_DIR="${BASE_DIR}/site-${SHORT}"
  NGINX_CONF_TARGET="${TARGET_NGINX_DIR}/${DOMAIN}.conf"
  CACHE_VOLUME_NAME="cache_${SHORT}"
  PHP_SERVICE_NAME="php_${SHORT}"
  REDIS_SERVICE_NAME="redis_${short}"

  log "Processing $DOMAIN (short=$SHORT upper=$UPPER)..."

  # 1) create site dir and copy template files
  log " - Creating site directory $SITE_DIR ..."
  if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY] mkdir -p $SITE_DIR/wordpress"
    echo "[DRY] copy master site template files to $SITE_DIR"
  else
    backup_file "$SITE_DIR"
    safe_mkdir "$SITE_DIR/wordpress"
    cp -a "${TEMPLATE_SITE}/Dockerfile" "$SITE_DIR/" || true
    cp -a "${TEMPLATE_SITE}/php.ini" "$SITE_DIR/" || true
    cp -a "${TEMPLATE_SITE}/www.conf" "$SITE_DIR/" || true
    log "   files copied"
  fi

  # 2) download wordpress into site dir
  log " - Downloading WordPress into $SITE_DIR/wordpress ..."
  if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY] wget latest wordpress -> $SITE_DIR/wordpress"
  else
    if [[ -z "$(ls -A "$SITE_DIR/wordpress" 2>/dev/null)" ]]; then
      wget -q https://wordpress.org/latest.tar.gz -O /tmp/wordpress.tar.gz
      tar -xzf /tmp/wordpress.tar.gz -C /tmp/
      mv /tmp/wordpress/* "$SITE_DIR/wordpress/"
      rm -rf /tmp/wordpress /tmp/wordpress.tar.gz
      log "   wordpress downloaded"
    else
      log "   wordpress folder already populated, skipping download"
    fi
  fi

  # 3) update scripts/init-databases.sql
  DB_NAME="wp_${SHORT}"
  if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY] append DB creation for $DB_NAME to $DB_INIT"
  else
    backup_file "$DB_INIT"
    if ! grep -q "$DB_NAME" "$DB_INIT" 2>/dev/null; then
      cat >> "$DB_INIT" <<EOF

CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO 'wp_user'@'%';
FLUSH PRIVILEGES;
EOF
      log "   appended DB create to $DB_INIT"
    else
      log "   DB entry already exists in $DB_INIT, skipping"
    fi
  fi

  # 4) update .env
  if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY] append SITE_DOMAIN and DB_NAME to $ENV_FILE"
  else
    backup_file "$ENV_FILE"
    # find next SITE index by counting SITEx_DOMAIN lines
    COUNT_EXISTING=$(grep -c '^SITE[0-9]\+_DOMAIN=' "$ENV_FILE" 2>/dev/null || true)
    IDX=$(( COUNT_EXISTING + 1 ))
    echo "SITE${IDX}_DOMAIN=${DOMAIN}" >> "$ENV_FILE"
    echo "SITE${IDX}_DB_NAME=${DB_NAME}" >> "$ENV_FILE"
    log "   appended SITE${IDX}_DOMAIN and DB name to .env"
  fi

  # 5) generate nginx vhost from template
  log " - Generating nginx config ${NGINX_CONF_TARGET} ..."
  if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY] sed replace placeholders in $TEMPLATE_NGINX -> $NGINX_CONF_TARGET"
  else
    # backup existing target if any
    backup_file "$NGINX_CONF_TARGET"
    sed -e "s/{{DOMAIN}}/${DOMAIN}/g" \
        -e "s/{{SHORT}}/${SHORT}/g" \
        -e "s/{{UPPER}}/${UPPER}/g" \
        "$TEMPLATE_NGINX" > "$NGINX_CONF_TARGET"
    log "   nginx conf created"
  fi

  # 6) add fastcgi_cache_path block to fastcgi-cache.conf
  log " - Adding cache zone for ${SHORT} ..."
  if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY] append fastcgi_cache_path /var/cache/nginx/${SHORT} ... to ${FASTCGI_TARGET}"
  else
    backup_file "$FASTCGI_TARGET"
    # construct block
    read -r -d '' CACHE_BLOCK <<EOF || true

fastcgi_cache_path /var/cache/nginx/${SHORT}
    levels=1:2
    keys_zone=${UPPER}:100m
    max_size=1g
    inactive=60m
    use_temp_path=off;
EOF
    # only append if keys_zone not already present
    if ! grep -q "keys_zone=${UPPER}" "$FASTCGI_TARGET"; then
      # insert at top where placeholder is or append before the fastcgi_cache_key line
      if grep -q "{{CACHE_ZONES}}" "$FASTCGI_TARGET"; then
        sed -i "s/{{CACHE_ZONES}}/${CACHE_BLOCK}\n{{CACHE_ZONES}}/" "$FASTCGI_TARGET"
        # remove placeholder if at final run (we'll leave placeholders harmless)
      else
        # append just before fastcgi_cache_key (if exists)
        if grep -q "fastcgi_cache_key" "$FASTCGI_TARGET"; then
          awk -v block="$CACHE_BLOCK" '/fastcgi_cache_key/ && c==0 { print block; c=1 } { print }' "$FASTCGI_TARGET" > "${FASTCGI_TARGET}.tmp" && mv "${FASTCGI_TARGET}.tmp" "$FASTCGI_TARGET"
        else
          echo -e "${CACHE_BLOCK}" >> "$FASTCGI_TARGET"
        fi
      fi
      log "   cache zone added to $FASTCGI_TARGET"
    else
      log "   cache zone ${UPPER} already present, skipping"
    fi
  fi

  # 7) update docker-compose.yml: add php service, redis service, volume, and mount in nginx
  log " - Updating docker-compose.yml to include php_${SHORT}, redis_${SHORT}, and volume ${CACHE_VOLUME_NAME} ..."
  if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY] Append php_${SHORT} and redis_${short} service blocks and volume ${CACHE_VOLUME_NAME}"
  else
    backup_file "$COMPOSE_FILE"
    # build php service block based on php_bereal or php_markazsunnah existing service as template
    # We'll create a reasonable generic block based on php_bereal structure observed earlier.
    read -r -d '' PHP_BLOCK <<EOF || true

  php_${SHORT}:
    build:
      context: ./site-${SHORT}
      dockerfile: Dockerfile
    container_name: wp_php_${SHORT}
    volumes:
      - ./site-${SHORT}/wordpress:/var/www/html
    environment:
      WORDPRESS_DB_HOST: db:3306
      WORDPRESS_DB_NAME: ${DB_NAME}
      WORDPRESS_DB_USER: wp_user
      WORDPRESS_DB_PASSWORD_FILE: /run/secrets/db_password
      WORDPRESS_CONFIG_EXTRA: |
        define('WP_REDIS_HOST', 'redis_${SHORT}');
        define('WP_REDIS_PORT', 6379);
        define('WP_CACHE_KEY_SALT', '${SHORT}_');
        define('FORCE_SSL_ADMIN', true);
        define('WP_HOME', 'https://${DOMAIN}');
        define('WP_SITEURL', 'https://${DOMAIN}');
    secrets:
      - db_password
    depends_on:
      db:
        condition: service_healthy
      redis_${SHORT}:
        condition: service_healthy
    networks:
      - frontend
      - backend
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "php-fpm -t 2>&1 | grep 'successful'"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 15s
EOF

    read -r -d '' REDIS_BLOCK <<EOF || true

  redis_${SHORT}:
    image: redis:alpine
    container_name: wp_redis_${SHORT}
    command: >
      redis-server
      --maxmemory 150mb
      --maxmemory-policy allkeys-lru
      --save ""
      --appendonly no
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 3s
      retries: 5
    networks:
      - backend
    restart: unless-stopped
EOF

    # Append service blocks before "networks:" section
    if grep -q "^networks:" "$COMPOSE_FILE"; then
      awk -v phpblock="$PHP_BLOCK" -v redisblock="$REDIS_BLOCK" '
        BEGIN{printed=0}
        /^networks:/ && printed==0 { print phpblock; print redisblock; printed=1 }
        { print }
      ' "$COMPOSE_FILE" > "${COMPOSE_FILE}.tmp" && mv "${COMPOSE_FILE}.tmp" "$COMPOSE_FILE"
      log "   php and redis blocks appended before networks:"
    else
      # fallback: append at end
      echo -e "${PHP_BLOCK}\n${REDIS_BLOCK}" >> "$COMPOSE_FILE"
      log "   php and redis blocks appended at end of compose file"
    fi

    # Append volume for cache under volumes: section
    if grep -q "^volumes:" "$COMPOSE_FILE"; then
      # append volume under volumes: (simple approach)
      awk -v vol="  ${CACHE_VOLUME_NAME}:\n    driver: local\n" '
        BEGIN{done=0}
        /^volumes:/ && done==0 { print; print vol; done=1; next }
        { print }
      ' "$COMPOSE_FILE" > "${COMPOSE_FILE}.tmp" && mv "${COMPOSE_FILE}.tmp" "$COMPOSE_FILE"
      log "   cache volume ${CACHE_VOLUME_NAME} appended under volumes:"
    else
      echo -e "\nvolumes:\n  ${CACHE_VOLUME_NAME}:\n    driver: local\n" >> "$COMPOSE_FILE"
      log "   volumes section appended with ${CACHE_VOLUME_NAME}"
    fi

    # Add mounts in nginx service: find nginx service volumes and append mounts
    # We'll append two lines to nginx.volumes: nginx should have a volumes section; we will insert mounts just after the existing nginx service volumes section.
    # This is a best-effort: search for the nginx service block and its volumes sub-block
    awk -v domain_conf="./nginx/${DOMAIN}.conf:/etc/nginx/conf.d/${DOMAIN}.conf:ro" -v site_mount="./site-${SHORT}/wordpress:/var/www/${SHORT}:ro" -v cache_mount="${CACHE_VOLUME_NAME}:/var/cache/nginx/${SHORT}" '
      BEGIN{in_nginx=0; in_vol=0}
      /^  nginx:/{print; in_nginx=1; next}
      in_nginx==1 && /^    volumes:/{print; in_vol=1; next}
      in_nginx==1 && in_vol==1 && /^[[:space:]]*-/ && !seen1 {print "      - " domain_conf; print "      - " site_mount; print "      - " cache_mount; seen1=1; print; next}
      { print }
    ' "$COMPOSE_FILE" > "${COMPOSE_FILE}.tmp" && mv "${COMPOSE_FILE}.tmp" "$COMPOSE_FILE" || true
    log "   attempted to add mounts to nginx.volumes (verify manually)"
  fi

  # 8) ensure ssl dir exists
  if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY] mkdir -p ${SSL_DIR}/${DOMAIN}"
  else
    safe_mkdir "${SSL_DIR}/${DOMAIN}"
  fi

  # 9) issue initial cert (standalone) - stop nginx temporarily
  log " - Issuing initial Let's Encrypt cert for ${DOMAIN} (standalone)..."
  if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY] certbot certonly --standalone -d ${DOMAIN} -d www.${DOMAIN}"
  else
    # stop nginx container to free port 80 if it's running under docker compose
    docker compose stop nginx 2>/dev/null || true
    sudo certbot certonly --standalone -d "${DOMAIN}" -d "www.${DOMAIN}" --agree-tos --no-eff-email --email "admin@${SHORT}.local" || {
      err "certbot failed for ${DOMAIN}. Continuing with next domain (inspect logs)"
      continue
    }
    # copy certs
    sudo mkdir -p "${SSL_DIR}/${DOMAIN}"
    sudo cp -L /etc/letsencrypt/live/"${DOMAIN}"/{fullchain.pem,privkey.pem,chain.pem} "${SSL_DIR}/${DOMAIN}/" || warn "copy certs failed, check permissions"
    sudo chmod -R 644 "${SSL_DIR}/${DOMAIN}"
    sudo chmod 600 "${SSL_DIR}/${DOMAIN}/privkey.pem" || true
    log "   cert copied to ${SSL_DIR}/${DOMAIN}"
    # start nginx again
    docker compose up -d nginx 2>/dev/null || true
  fi

  # 10) setup cron for renewal (webroot)
  log " - Installing root crontab entry for renewal (webroot) for ${DOMAIN} ..."
  if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY] install cron entry for ${DOMAIN}"
  else
    CRON_CMD="0 3 * * 0 certbot certonly --webroot -w ${BASE_DIR}/site-${SHORT}/wordpress -d ${DOMAIN} -d www.${DOMAIN} --quiet && docker compose -f ${COMPOSE_FILE} restart nginx"
    # remove old matching lines for this domain and add new
    (sudo crontab -l 2>/dev/null | grep -v "$DOMAIN" || true; echo "$CRON_CMD") | sudo crontab -
    log "   cron entry installed for domain ${DOMAIN}"
  fi

  log "Finished processing ${DOMAIN}."
done

# ---------- final steps ----------
if [[ "$DOCKER_NOW" =~ ^[YyY] ]]; then
  if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY] docker compose build && docker compose up -d"
  else
    log "Building and starting containers..."
    docker compose build
    docker compose up -d
    log "Containers started. Check 'docker compose ps' and container logs if necessary."
  fi
else
  log "Skipping docker compose up - run 'docker compose build && docker compose up -d' manually when ready."
fi

log "Setup complete. Inspect $BACKUP_DIR for backups of modified files (if any)."
echo
log "Next steps:"
echo " - Verify nginx configs: sudo docker compose exec nginx nginx -t"
echo " - Visit your sites once DNS points to this server"
echo " - Check certs in ${SSL_DIR}/<domain>"
echo " - If anything looks off, inspect backups in ${BACKUP_DIR}"
