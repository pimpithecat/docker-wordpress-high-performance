#!/usr/bin/env bash
# =============================================================================
# setup.sh - FINAL WORKING VERSION
# WordPress Multi-site generator (fixed all issues)
# =============================================================================
set -euo pipefail

# ---------- config ----------
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
MASTER="${BASE_DIR}/master-template"
TEMPLATE_SITE="${MASTER}/site-template"
TEMPLATE_NGINX="${MASTER}/nginx/site-template.conf"
TEMPLATE_NGINX_CONF="${MASTER}/nginx/nginx.conf"
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
SECRETS_DIR="${BASE_DIR}/secrets"
DRY_RUN=false
BACKUP_DIR="${BASE_DIR}/.setup_backups_$(date +%s)"
CREATED_FILES=()
CREATED_DIRS=()
MODIFIED_FILES=()

# Arrays to store site data
SITE_SHORTS=()
SITE_DOMAINS=()
SITE_DB_NAMES=()
SITE_VOLUMES=()

# Colors
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'

# ---------- helpers ----------
log()  { echo -e "${GREEN}>>${NC} $*"; }
warn() { echo -e "${YELLOW}!!${NC} $*"; }
err()  { echo -e "${RED}!!${NC} $*" >&2; }
info() { echo -e "${BLUE}ℹ${NC} $*"; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { err "Requirement missing: $1"; exit 1; }
}

safe_mkdir() {
  if [[ "${DRY_RUN}" == true ]]; then
    echo "[DRY] mkdir -p $*"
  else
    mkdir -p "$@"
    CREATED_DIRS+=("$1")
  fi
}

backup_file() {
  local f="$1"
  if [[ -f "$f" ]]; then
    safe_mkdir "$BACKUP_DIR"
    if [[ "${DRY_RUN}" == true ]]; then
      echo "[DRY] cp $f $BACKUP_DIR/"
    else
      cp -a "$f" "$BACKUP_DIR/"
      MODIFIED_FILES+=("$f")
    fi
  fi
}

track_created_file() {
  local f="$1"
  if [[ "${DRY_RUN}" == false ]]; then
    CREATED_FILES+=("$f")
  fi
}

# ---------- rollback system ----------
perform_rollback() {
  err "Performing complete rollback..."

  # Stop any running containers
  if [[ -f "$COMPOSE_FILE" ]]; then
    docker compose down -v 2>/dev/null || true
  fi

  # Remove created files
  for file in "${CREATED_FILES[@]}"; do
    if [[ -f "$file" ]]; then
      warn "Removing created file: $file"
      rm -f "$file"
    fi
  done

  # Remove created directories (in reverse order)
  for ((idx=${#CREATED_DIRS[@]}-1 ; idx>=0 ; idx--)); do
    local dir="${CREATED_DIRS[idx]}"
    if [[ -d "$dir" ]]; then
      warn "Removing created directory: $dir"
      if [[ "$dir" =~ ssl ]]; then
        sudo rm -rf "$dir" 2>/dev/null || rm -rf "$dir"
      else
        rm -rf "$dir"
      fi
    fi
  done

  # Force cleanup ssl parent
  if [[ -d "${BASE_DIR}/ssl" ]]; then
    warn "Force removing ssl directory"
    sudo rm -rf "${BASE_DIR}/ssl" 2>/dev/null || true
  fi

  # Restore modified files from backup
  if [[ -d "$BACKUP_DIR" ]]; then
    for file in "${MODIFIED_FILES[@]}"; do
      local backup_file="${BACKUP_DIR}/$(basename "$file")"
      if [[ -f "$backup_file" ]]; then
        warn "Restoring: $file"
        cp -a "$backup_file" "$file"
      fi
    done
  fi

  # Remove backup dir
  if [[ -d "$BACKUP_DIR" ]]; then
    rm -rf "$BACKUP_DIR"
  fi

  err "Rollback complete. All changes have been reverted."
}

on_error() {
  err "Error occurred at line $BASH_LINENO. Starting rollback..."
  perform_rollback
  exit 1
}
trap on_error ERR

# ---------- parse flags ----------
usage() {
  cat <<EOF
Usage: $0 [--dry] [--clean] [--help]
  --dry     : dry-run (no destructive changes)
  --clean   : remove all existing setup and start fresh
  --help    : show this help
EOF
  exit 1
}

CLEAN_MODE=false
for arg in "$@"; do
  case "$arg" in
    --dry) DRY_RUN=true ;;
    --clean) CLEAN_MODE=true ;;
    --help) usage ;;
    *) ;;
  esac
done

# ---------- clean mode ----------
if [[ "$CLEAN_MODE" == true ]]; then
  warn "CLEAN MODE: Removing all existing setup..."
  read -rp "Are you sure? This will delete everything! [yes/NO]: " confirm
  if [[ "$confirm" != "yes" ]]; then
    log "Clean mode cancelled."
    exit 0
  fi

  docker compose down -v 2>/dev/null || true
  sudo rm -rf ssl/ 2>/dev/null || true
  rm -rf docker-compose.yml .env nginx/ site-* scripts/ secrets/ .setup_backups_*
  log "Clean complete. Run script again to setup from scratch."
  exit 0
fi

# ---------- auto-install Docker if missing ----------
install_docker_if_missing() {
  if [[ "${DRY_RUN}" == true ]]; then
    echo "[DRY] Would check and install Docker + Compose if missing (skipped)"
    return
  fi

  if ! command -v docker &> /dev/null; then
    warn "Docker not found. Installing Docker Engine..."
    sudo apt-get update -y
    sudo apt-get install -y ca-certificates curl gnupg lsb-release

    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc

    echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt-get update -y
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    if ! command -v docker &> /dev/null; then
      err "Docker installation failed. Please install manually."
      exit 1
    fi
    log "✓ Docker installed successfully."
  else
    log "✓ Docker found: $(docker --version)"
  fi

  if docker compose version &>/dev/null; then
    log "✓ Docker Compose (plugin) detected."
  elif command -v docker-compose &>/dev/null; then
    log "✓ Legacy docker-compose binary detected."
  else
    warn "Docker Compose not found; installing docker-compose-plugin..."
    sudo apt-get install -y docker-compose-plugin || {
      err "Failed to install docker-compose-plugin."
      exit 1
    }
    log "✓ Docker Compose plugin installed."
  fi
}

# ---------- auto-install dependencies ----------
install_dependencies_if_missing() {
  local DEPS=(certbot openssl wget)
  if [[ "${DRY_RUN}" == true ]]; then
    echo "[DRY] Would check and install missing dependencies: ${DEPS[*]}"
    return
  fi

  local MISSING=()
  for dep in "${DEPS[@]}"; do
    if ! command -v "$dep" >/dev/null 2>&1; then
      MISSING+=("$dep")
    fi
  done

  if [[ ${#MISSING[@]} -gt 0 ]]; then
    warn "Missing dependencies: ${MISSING[*]}. Installing..."
    sudo apt-get update -y
    sudo apt-get install -y "${MISSING[@]}" || {
      err "Failed to install dependencies: ${MISSING[*]}"
      exit 1
    }
    log "✓ Dependencies installed: ${MISSING[*]}"
  else
    log "✓ All dependencies already installed."
  fi
}

# ---------- call installers ----------
install_docker_if_missing
install_dependencies_if_missing

# ---------- checks ----------
log "Checking system prerequisites..."
if [[ "${DRY_RUN}" == true ]]; then
  log "[DRY] Skipping direct binary checks (certbot, openssl, etc.)"
else
  require_cmd docker
  for cmd in certbot openssl wget sed awk grep; do
    require_cmd "$cmd"
  done
fi

# verify compose availability
if docker compose version &>/dev/null; then
  log "✓ Docker Compose (plugin) available."
elif command -v docker-compose &>/dev/null; then
  log "✓ docker-compose binary available."
else
  err "Docker Compose not found. Install docker-compose-plugin or docker-compose binary."
  exit 1
fi

# ensure master template present
if [[ ! -d "$MASTER" ]]; then
  err "master-template/ not found in $BASE_DIR. Abort."
  exit 1
fi
if [[ ! -f "$TEMPLATE_NGINX" ]] || [[ ! -d "$TEMPLATE_SITE" ]]; then
  err "Required master-template files missing (nginx/site-template.conf or site-template/)."
  exit 1
fi

# ---------- create secrets if missing ----------
log "Ensuring secrets directory exists..."
if [[ "${DRY_RUN}" == true ]]; then
  echo "[DRY] Would create secrets directory and generate passwords"
else
  if [[ ! -d "$SECRETS_DIR" ]]; then
    safe_mkdir "$SECRETS_DIR"

    # Generate random passwords
    DB_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
    DB_ROOT_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)

    echo "$DB_PASSWORD" > "$SECRETS_DIR/db_password.txt"
    echo "$DB_ROOT_PASSWORD" > "$SECRETS_DIR/db_root_password.txt"

    chmod 600 "$SECRETS_DIR"/*.txt

    track_created_file "$SECRETS_DIR/db_password.txt"
    track_created_file "$SECRETS_DIR/db_root_password.txt"

    log "✓ Generated database passwords in $SECRETS_DIR/"
  else
    log "✓ Secrets directory already exists"
  fi
fi

# ---------- ensure .env exists ----------
if [[ ! -f "$ENV_FILE" ]]; then
  log "Creating .env file..."
  if [[ "${DRY_RUN}" == true ]]; then
    echo "[DRY] Would create .env file"
  else
    cat > "$ENV_FILE" <<'EOF'
# WordPress Multi-site Configuration
# Auto-generated by setup.sh
EOF
    track_created_file "$ENV_FILE"
    log "✓ Created .env file"
  fi
else
  log "✓ .env file already exists"
fi

# ---------- ensure scripts dir exists ----------
if [[ ! -d "$(dirname "$DB_INIT")" ]]; then
  safe_mkdir "$(dirname "$DB_INIT")"
fi

# ---------- ensure init-databases.sql exists ----------
if [[ ! -f "$DB_INIT" ]]; then
  log "Creating init-databases.sql..."
  if [[ "${DRY_RUN}" == true ]]; then
    echo "[DRY] Would create init-databases.sql"
  else
    cat > "$DB_INIT" <<'EOF'
-- Auto-generated by setup.sh
-- WordPress Multi-site Database Initialization
EOF
    track_created_file "$DB_INIT"
    log "✓ Created init-databases.sql"
  fi
else
  log "✓ init-databases.sql already exists"
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

    # Check if domain already exists
    if grep -q "SITE.*_DOMAIN=$D" "$ENV_FILE" 2>/dev/null; then
      warn "Domain $D sudah ada dalam konfigurasi!"
      read -rp "Gunakan domain ini lagi? [y/N]: " reuse
      if [[ ! "$reuse" =~ ^[Yy]$ ]]; then
        continue
      fi
    fi

    DOMAINS+=("$D")
    break
  done
done

read -rp "Jalankan langsung docker compose up setelah setup? [Y/n]: " DOCKER_NOW
DOCKER_NOW=${DOCKER_NOW:-Y}

# ---------- PREPARE target includes if missing ----------
log "Ensuring nginx/includes/ exists and global templates are present..."
if [[ "${DRY_RUN}" == true ]]; then
  echo "[DRY] ensure $TARGET_INCLUDES_DIR and copy includes from master if missing"
else
  safe_mkdir "$TARGET_NGINX_DIR"
  safe_mkdir "$TARGET_INCLUDES_DIR"

  # Copy nginx.conf if not exists - TAMBAH INI ↓
  NGINX_CONF_TARGET="${TARGET_NGINX_DIR}/nginx.conf"
  if [[ ! -f "$NGINX_CONF_TARGET" ]]; then
    if [[ -f "$TEMPLATE_NGINX_CONF" ]]; then
      cp -a "$TEMPLATE_NGINX_CONF" "$NGINX_CONF_TARGET"
      track_created_file "$NGINX_CONF_TARGET"
      log "Copied nginx.conf to nginx/"
    else
      warn "Master nginx.conf missing; nginx may not start correctly"
    fi
  fi

  # copy ssl params if not exists
  if [[ ! -f "$SSL_PARAMS_TARGET" ]]; then
    if [[ -f "$SSL_PARAMS_MASTER" ]]; then
      cp -a "$SSL_PARAMS_MASTER" "$SSL_PARAMS_TARGET"
      track_created_file "$SSL_PARAMS_TARGET"
      log "Copied ssl-params.conf to nginx/includes/"
    else
      warn "Master ssl-params.conf missing; ensure global SSL settings exist."
    fi
  fi

  # create or initialize fastcgi target from master-template
  if [[ ! -f "$FASTCGI_TARGET" ]]; then
    if [[ -f "$FASTCGI_MASTER" ]]; then
      cp -a "$FASTCGI_MASTER" "$FASTCGI_TARGET"
      track_created_file "$FASTCGI_TARGET"
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
      track_created_file "$FASTCGI_TARGET"
      log "Created minimal fastcgi-cache.conf"
    fi
  fi
fi

# ---------- utility functions ----------
short_name(){ echo "$1" | awk -F. '{print $1}'; }
upper(){ echo "$1" | tr '[:lower:]' '[:upper:]'; }

# ---------- generate per-domain pieces ----------
for DOMAIN in "${DOMAINS[@]}"; do
  SHORT=$(short_name "$DOMAIN")
  UPPER=$(upper "$SHORT")
  SITE_DIR="${BASE_DIR}/site-${SHORT}"
  NGINX_CONF_TARGET="${TARGET_NGINX_DIR}/${DOMAIN}.conf"
  CACHE_VOLUME_NAME="cache_${SHORT}"
  DB_NAME="wp_${SHORT}"

  log "Processing $DOMAIN (short=$SHORT upper=$UPPER)..."

  # Store for docker-compose generation
  SITE_SHORTS+=("$SHORT")
  SITE_DOMAINS+=("$DOMAIN")
  SITE_DB_NAMES+=("$DB_NAME")
  SITE_VOLUMES+=("$CACHE_VOLUME_NAME")

  # 1) create site dir and copy template files
  log " - Creating site directory $SITE_DIR ..."
  if [[ "${DRY_RUN}" == true ]]; then
    echo "[DRY] mkdir -p $SITE_DIR/wordpress"
    echo "[DRY] copy master site template files to $SITE_DIR"
  else
    backup_file "$SITE_DIR"
    safe_mkdir "$SITE_DIR"
    safe_mkdir "$SITE_DIR/wordpress"

    cp -a "${TEMPLATE_SITE}/Dockerfile" "$SITE_DIR/" || true
    cp -a "${TEMPLATE_SITE}/php.ini" "$SITE_DIR/" || true
    cp -a "${TEMPLATE_SITE}/www.conf" "$SITE_DIR/" || true

    track_created_file "$SITE_DIR/Dockerfile"
    track_created_file "$SITE_DIR/php.ini"
    track_created_file "$SITE_DIR/www.conf"

    log "   files copied"
  fi

  # 2) download wordpress into site dir
  log " - Downloading WordPress into $SITE_DIR/wordpress ..."
  if [[ "${DRY_RUN}" == true ]]; then
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
  if [[ "${DRY_RUN}" == true ]]; then
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
  if [[ "${DRY_RUN}" == true ]]; then
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

  # 5) generate nginx vhost from template - FIX SSL PATH!
  log " - Generating nginx config ${NGINX_CONF_TARGET} ..."
  if [[ "${DRY_RUN}" == true ]]; then
    echo "[DRY] sed replace placeholders in $TEMPLATE_NGINX -> $NGINX_CONF_TARGET"
  else
    backup_file "$NGINX_CONF_TARGET"
    sed -e "s/{{DOMAIN}}/${DOMAIN}/g" \
        -e "s/{{SHORT}}/${SHORT}/g" \
        -e "s/{{UPPER}}/${UPPER}/g" \
        "$TEMPLATE_NGINX" | \
    sed 's|/etc/letsencrypt/live/|/etc/letsencrypt/live/|g' \
        > "$NGINX_CONF_TARGET"

    track_created_file "$NGINX_CONF_TARGET"
    log "   nginx conf created with correct SSL paths"
  fi

  # 6) add fastcgi_cache_path block to fastcgi-cache.conf
  log " - Adding cache zone for ${SHORT} ..."
  if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY] append fastcgi_cache_path /var/cache/nginx/${SHORT} ... to ${FASTCGI_TARGET}"
  else
    backup_file "$FASTCGI_TARGET"

    # Construct cache zone block
    read -r -d '' CACHE_BLOCK <<EOF || true

fastcgi_cache_path /var/cache/nginx/${SHORT}
    levels=1:2
    keys_zone=${UPPER}:100m
    max_size=1g
    inactive=60m
    use_temp_path=off;
EOF

    # Only append if zone not already present
    if ! grep -q "keys_zone=${UPPER}" "$FASTCGI_TARGET"; then
      if grep -q "{{CACHE_ZONES}}" "$FASTCGI_TARGET"; then
        awk -v block="$CACHE_BLOCK" '
          /{{CACHE_ZONES}}/ {
            gsub(/{{CACHE_ZONES}}/, block "\n{{CACHE_ZONES}}");
          }
          { print }
        ' "$FASTCGI_TARGET" > "${FASTCGI_TARGET}.tmp" && mv "${FASTCGI_TARGET}.tmp" "$FASTCGI_TARGET"
        log "   cache zone added to $FASTCGI_TARGET (via placeholder)"
      else
        if grep -q "fastcgi_cache_key" "$FASTCGI_TARGET"; then
          awk -v block="$CACHE_BLOCK" '
            /fastcgi_cache_key/ && !added { print block; added=1 } { print }
          ' "$FASTCGI_TARGET" > "${FASTCGI_TARGET}.tmp" && mv "${FASTCGI_TARGET}.tmp" "$FASTCGI_TARGET"
        else
          echo -e "${CACHE_BLOCK}" >> "$FASTCGI_TARGET"
        fi
        log "   cache zone added to $FASTCGI_TARGET"
      fi
    else
      log "   cache zone ${UPPER} already present, skipping"
    fi
  fi

  # 7) ensure ssl dir exists - TRACK PARENT TOO!
  if [[ "${DRY_RUN}" == true ]]; then
    echo "[DRY] mkdir -p ${SSL_DIR}/${DOMAIN}"
  else
    # Track ssl parent directory
    if [[ ! -d "${BASE_DIR}/ssl" ]]; then
      safe_mkdir "${BASE_DIR}/ssl"
    fi
    safe_mkdir "${SSL_DIR}"
    safe_mkdir "${SSL_DIR}/${DOMAIN}"
  fi

  # 8) issue initial cert (standalone)
  log " - Issuing initial Let's Encrypt cert for ${DOMAIN} (standalone)..."
  if [[ "${DRY_RUN}" == true ]]; then
    echo "[DRY] certbot certonly --standalone -d ${DOMAIN} -d www.${DOMAIN}"
  else
    docker compose stop nginx 2>/dev/null || true

    # Default email
    CERT_EMAIL="${CERT_EMAIL:-admin@${DOMAIN}}"

    info "Requesting SSL certificate for ${DOMAIN}..."
    sudo certbot certonly --standalone \
      -d "${DOMAIN}" -d "www.${DOMAIN}" \
      --agree-tos --no-eff-email --register-unsafely-without-email \
      --non-interactive || {
        err "certbot failed for ${DOMAIN}. Continuing with next domain (inspect logs)"
        warn "You may need to manually fix SSL for this domain later."
        continue
    }

    sudo mkdir -p "${SSL_DIR}/${DOMAIN}"
    sudo cp -L /etc/letsencrypt/live/"${DOMAIN}"/{fullchain.pem,privkey.pem,chain.pem} "${SSL_DIR}/${DOMAIN}/" || {
      warn "copy certs failed, check permissions"
    }
    sudo chmod -R 644 "${SSL_DIR}/${DOMAIN}"
    sudo chmod 600 "${SSL_DIR}/${DOMAIN}/privkey.pem" || true
    log "   cert copied to ${SSL_DIR}/${DOMAIN}"

    docker compose up -d nginx 2>/dev/null || true
  fi

  # 9) setup cron for renewal
  log " - Installing root crontab entry for renewal (webroot) for ${DOMAIN} ..."
  if [[ "${DRY_RUN}" == true ]]; then
    echo "[DRY] install cron entry for ${DOMAIN}"
  else
    CRON_CMD="0 3 * * 0 certbot certonly --webroot -w ${BASE_DIR}/site-${SHORT}/wordpress -d ${DOMAIN} -d www.${DOMAIN} --quiet && docker compose -f ${COMPOSE_FILE} restart nginx"
    (sudo crontab -l 2>/dev/null | grep -v "$DOMAIN" || true; echo "$CRON_CMD") | sudo crontab -
    log "   cron entry installed for domain ${DOMAIN}"
  fi

  log "Finished processing ${DOMAIN}."
done

# ---------- cleanup placeholders ----------
log "Cleaning up template placeholders..."
if [[ "${DRY_RUN}" == true ]]; then
  echo "[DRY] Would remove {{CACHE_ZONES}} placeholder"
else
  sed -i '/{{CACHE_ZONES}}/d' "$FASTCGI_TARGET" 2>/dev/null || true
  log "✓ Removed template placeholders"
fi

# ---------- GENERATE COMPLETE docker-compose.yml (LIKE WORKING VERSION) ----------
log "Generating complete docker-compose.yml..."
if [[ "${DRY_RUN}" == true ]]; then
  echo "[DRY] Would generate complete docker-compose.yml"
else
  backup_file "$COMPOSE_FILE"

  # Start with base (NO version: field to avoid warning)
  cat > "$COMPOSE_FILE" <<'COMPOSE_BASE'
services:
  nginx:
    image: nginx:latest
    container_name: wp_nginx
COMPOSE_BASE

  # Add depends_on for all PHP services
  echo "    depends_on:" >> "$COMPOSE_FILE"
  for SHORT in "${SITE_SHORTS[@]}"; do
    cat >> "$COMPOSE_FILE" <<DEPENDS
      php_${SHORT}:
        condition: service_healthy
DEPENDS
  done

  # Continue nginx config
  cat >> "$COMPOSE_FILE" <<'NGINX_PORTS'
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx/includes:/etc/nginx/includes:ro
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./ssl:/etc/letsencrypt:ro
NGINX_PORTS

  # Add nginx volume mounts for each site
  for i in "${!SITE_SHORTS[@]}"; do
    SHORT="${SITE_SHORTS[$i]}"
    DOMAIN="${SITE_DOMAINS[$i]}"
    VOLUME="${SITE_VOLUMES[$i]}"

    cat >> "$COMPOSE_FILE" <<NGINX_VOLUMES
      - ./nginx/${DOMAIN}.conf:/etc/nginx/conf.d/${DOMAIN}.conf:ro
      - ./site-${SHORT}/wordpress:/var/www/${SHORT}:ro
      - ${VOLUME}:/var/cache/nginx/${SHORT}
NGINX_VOLUMES
  done

  # Complete nginx service
  cat >> "$COMPOSE_FILE" <<'NGINX_END'
    networks:
      - frontend
    restart: unless-stopped

  db:
    image: mysql:8.0
    container_name: wp_db
    environment:
      MYSQL_ROOT_PASSWORD_FILE: /run/secrets/db_root_password
      MYSQL_USER: wp_user
      MYSQL_PASSWORD_FILE: /run/secrets/db_password
    volumes:
      - db_data:/var/lib/mysql
      - ./scripts:/docker-entrypoint-initdb.d:ro
    secrets:
      - db_password
      - db_root_password
    networks:
      - backend
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
      interval: 10s
      timeout: 5s
      retries: 5
    restart: unless-stopped

NGINX_END

  # Add PHP and Redis services for each site
  for i in "${!SITE_SHORTS[@]}"; do
    SHORT="${SITE_SHORTS[$i]}"
    DOMAIN="${SITE_DOMAINS[$i]}"
    DB_NAME="${SITE_DB_NAMES[$i]}"

    cat >> "$COMPOSE_FILE" <<PHP_SERVICE
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

PHP_SERVICE
  done

  # Add networks, secrets, volumes
  cat >> "$COMPOSE_FILE" <<'COMPOSE_FOOTER'
networks:
  frontend:
  backend:

secrets:
  db_password:
    file: ./secrets/db_password.txt
  db_root_password:
    file: ./secrets/db_root_password.txt

volumes:
  db_data:
COMPOSE_FOOTER

  # Add cache volumes
  for VOLUME in "${SITE_VOLUMES[@]}"; do
    cat >> "$COMPOSE_FILE" <<VOLUME_ENTRY
  ${VOLUME}:
    driver: local
VOLUME_ENTRY
  done

  track_created_file "$COMPOSE_FILE"
  log "✓ Generated complete docker-compose.yml with ${#SITE_SHORTS[@]} site(s)"
fi

# ---------- final steps ----------
if [[ "${DOCKER_NOW}" =~ ^[YyY] ]]; then
  if [[ "${DRY_RUN}" == true ]]; then
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

# Clean up backup dir if everything succeeded
if [[ -d "$BACKUP_DIR" ]] && [[ ${#MODIFIED_FILES[@]} -eq 0 ]]; then
  rm -rf "$BACKUP_DIR"
fi

log "Setup complete!"
echo
log "Next steps:"
echo " - Verify nginx configs: docker compose exec nginx nginx -t"
echo " - Visit your sites once DNS points to this server"
echo " - Check certs in ${SSL_DIR}/<domain>"
if [[ -d "$BACKUP_DIR" ]]; then
  echo " - Backups saved in: ${BACKUP_DIR}"
fi
