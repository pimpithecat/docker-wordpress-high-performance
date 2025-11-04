#!/usr/bin/env bash
# =============================================================================
# setup.sh - FINAL COMPLETE VERSION WITH UID 82 FIXES
# WordPress Multi-site Manager with Subdirectory Pattern + Incremental Mode
# =============================================================================
set -euo pipefail

# ---------- config ----------
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
MASTER="${BASE_DIR}/master-template"
TEMPLATE_SITE="${MASTER}/site-template"
TEMPLATE_NGINX="${MASTER}/nginx/site-template.conf"
TEMPLATE_NGINX_CONF="${MASTER}/nginx/nginx.conf"
MASTER_INCLUDES="${MASTER}/nginx/includes"

# Deployment environment
DEPLOY_ENV="${DEPLOY_ENV:-production}"
DEPLOY_DIR="${BASE_DIR}/deployments/${DEPLOY_ENV}"

# Deployment-specific paths
TARGET_NGINX_DIR="${DEPLOY_DIR}/nginx"
TARGET_INCLUDES_DIR="${TARGET_NGINX_DIR}/includes"
FASTCGI_MASTER="${MASTER_INCLUDES}/fastcgi-cache.conf"
FASTCGI_TARGET="${TARGET_INCLUDES_DIR}/fastcgi-cache.conf"
SSL_PARAMS_MASTER="${MASTER_INCLUDES}/ssl-params.conf"
SSL_PARAMS_TARGET="${TARGET_INCLUDES_DIR}/ssl-params.conf"
COMPOSE_FILE="${DEPLOY_DIR}/docker-compose.yml"
ENV_FILE="${DEPLOY_DIR}/.env"
DB_INIT="${DEPLOY_DIR}/scripts/init-databases.sql"
SSL_DIR="${DEPLOY_DIR}/ssl/live"
SECRETS_DIR="${DEPLOY_DIR}/secrets"
SITES_DIR="${DEPLOY_DIR}/sites"

# Runtime state
DRY_RUN=false
BACKUP_DIR="${DEPLOY_DIR}/.setup_backups_$(date +%s)"
CREATED_FILES=()
CREATED_DIRS=()
MODIFIED_FILES=()

# Arrays to store site data
SITE_SHORTS=()
SITE_DOMAINS=()
SITE_DB_NAMES=()
SITE_VOLUMES=()
EXISTING_SITES=()

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

short_name(){ echo "$1" | awk -F. '{print $1}'; }
upper(){ echo "$1" | tr '[:lower:]' '[:upper:]'; }

# ---------- rollback system ----------
perform_rollback() {
  err "Performing complete rollback..."

  if [[ -f "$COMPOSE_FILE" ]]; then
    docker compose -f "$COMPOSE_FILE" down -v 2>/dev/null || true
  fi

  for file in "${CREATED_FILES[@]}"; do
    if [[ -f "$file" ]]; then
      warn "Removing created file: $file"
      rm -f "$file"
    fi
  done

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

  if [[ -d "${DEPLOY_DIR}/ssl" ]]; then
    warn "Force removing ssl directory"
    sudo rm -rf "${DEPLOY_DIR}/ssl" 2>/dev/null || true
  fi

  if [[ -d "$BACKUP_DIR" ]]; then
    for file in "${MODIFIED_FILES[@]}"; do
      local backup_file="${BACKUP_DIR}/$(basename "$file")"
      if [[ -f "$backup_file" ]]; then
        warn "Restoring: $file"
        cp -a "$backup_file" "$file"
      fi
    done
  fi

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

# ---------- detect existing sites ----------
detect_existing_sites() {
  EXISTING_SITES=()
  if [[ -f "$ENV_FILE" ]]; then
    while IFS='=' read -r key value; do
      if [[ "$key" =~ ^SITE[0-9]+_DOMAIN$ ]]; then
        EXISTING_SITES+=("$value")
      fi
    done < "$ENV_FILE"
  fi
}

# ---------- usage ----------
usage() {
  cat <<EOF
${GREEN}WordPress Multi-site Manager${NC}

${BLUE}Usage:${NC}
  $0 <command> [options]

${BLUE}Commands:${NC}
  ${GREEN}init${NC}              Initialize new deployment (first time setup)
  ${GREEN}add${NC} <domain>      Add a new site to existing deployment
  ${GREEN}remove${NC} <domain>   Remove a site from deployment
  ${GREEN}remove --all${NC}      Remove ALL sites (confirmation required)
  ${GREEN}list${NC}              List all configured sites and their status
  ${GREEN}clean${NC}             Remove entire deployment (confirmation required)

${BLUE}Options:${NC}
  --env <name>      Deployment environment (default: production)
  --dry             Dry-run mode (no destructive changes)
  --help, -h        Show this help message

${BLUE}Examples:${NC}
  # First time setup
  $0 init

  # Add new sites
  $0 add example.com
  $0 add another-site.com

  # List sites
  $0 list

  # Remove specific site
  $0 remove example.com

  # Remove all sites
  $0 remove --all

  # Clean everything
  $0 clean

${BLUE}File Structure:${NC}
  master-template/       Templates (version controlled)
  deployments/
    └── production/      Generated files (gitignored)
        ├── docker-compose.yml
        ├── .env
        ├── nginx/
        ├── sites/
        ├── ssl/
        └── secrets/

EOF
  exit 0
}

# ---------- parse args ----------
COMMAND=""
ORIGINAL_ARGS=("$@")
while [[ $# -gt 0 ]]; do
  case "$1" in
    init|add|remove|rm|list|ls|clean)
      COMMAND="$1"
      shift
      break
      ;;
    --env)
      DEPLOY_ENV="$2"
      DEPLOY_DIR="${BASE_DIR}/deployments/${DEPLOY_ENV}"
      # Update all paths
      TARGET_NGINX_DIR="${DEPLOY_DIR}/nginx"
      TARGET_INCLUDES_DIR="${TARGET_NGINX_DIR}/includes"
      FASTCGI_TARGET="${TARGET_INCLUDES_DIR}/fastcgi-cache.conf"
      SSL_PARAMS_TARGET="${TARGET_INCLUDES_DIR}/ssl-params.conf"
      COMPOSE_FILE="${DEPLOY_DIR}/docker-compose.yml"
      ENV_FILE="${DEPLOY_DIR}/.env"
      DB_INIT="${DEPLOY_DIR}/scripts/init-databases.sql"
      SSL_DIR="${DEPLOY_DIR}/ssl/live"
      SECRETS_DIR="${DEPLOY_DIR}/secrets"
      SITES_DIR="${DEPLOY_DIR}/sites"
      shift 2
      ;;
    --dry)
      DRY_RUN=true
      shift
      ;;
    --help|-h|help)
      usage
      ;;
    *)
      err "Unknown option: $1"
      usage
      ;;
  esac
done

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

# ---------- verify docker access ----------
verify_docker_access() {
  log "Verifying Docker access..."
  if ! docker ps &>/dev/null 2>&1; then
    warn "Cannot access Docker daemon"

    if ! groups | grep -q '\bdocker\b'; then
      warn "Adding user $USER to docker group..."
      sudo usermod -aG docker "$USER"
      log "✓ User added to docker group"
    fi

    if command -v sg &>/dev/null; then
      log "Re-executing script with docker group permissions..."
      exec sg docker -c "$0 ${ORIGINAL_ARGS[*]}"
    else
      err ""
      err "════════════════════════════════════════════════════"
      err "  Cannot auto-apply docker group permissions!"
      err ""
      err "  Please run ONE of these:"
      err "    1. Logout and login again"
      err "    2. Run: newgrp docker"
      err "       Then: ./setup.sh $COMMAND"
      err "════════════════════════════════════════════════════"
      err ""
      exit 1
    fi
  fi

  log "✓ Docker access verified"
}

# ---------- system checks ----------
system_checks() {
  log "Checking system prerequisites..."
  if [[ "${DRY_RUN}" == true ]]; then
    log "[DRY] Skipping direct binary checks"
  else
    require_cmd docker
    for cmd in certbot openssl wget sed awk grep; do
      require_cmd "$cmd"
    done
  fi

  if docker compose version &>/dev/null; then
    log "✓ Docker Compose (plugin) available."
  elif command -v docker-compose &>/dev/null; then
    log "✓ docker-compose binary available."
  else
    err "Docker Compose not found. Install docker-compose-plugin or docker-compose binary."
    exit 1
  fi

  if [[ ! -d "$MASTER" ]]; then
    err "master-template/ not found in $BASE_DIR. Abort."
    exit 1
  fi
  if [[ ! -f "$TEMPLATE_NGINX" ]] || [[ ! -d "$TEMPLATE_SITE" ]]; then
    err "Required master-template files missing (nginx/site-template.conf or site-template/)."
    exit 1
  fi
}

# ---------- initialize base structure ----------
init_base_structure() {
  log "Initializing base deployment structure..."

  if [[ "${DRY_RUN}" == true ]]; then
    echo "[DRY] Would create deployment directories"
    return
  fi

  # Create deployment directories
  safe_mkdir "$DEPLOY_DIR"
  safe_mkdir "$TARGET_NGINX_DIR"
  safe_mkdir "$TARGET_INCLUDES_DIR"
  safe_mkdir "$SITES_DIR"
  safe_mkdir "$(dirname "$DB_INIT")"

  # Create secrets if missing
  if [[ ! -d "$SECRETS_DIR" ]]; then
    safe_mkdir "$SECRETS_DIR"

    DB_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
    DB_ROOT_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)

    echo "$DB_PASSWORD" > "$SECRETS_DIR/db_password.txt"
    echo "$DB_ROOT_PASSWORD" > "$SECRETS_DIR/db_root_password.txt"

    chmod 600 "$SECRETS_DIR"/*.txt

    track_created_file "$SECRETS_DIR/db_password.txt"
    track_created_file "$SECRETS_DIR/db_root_password.txt"

    log "✓ Generated database passwords"
  else
    log "✓ Secrets already exist"
  fi

  # Create .env if missing
  if [[ ! -f "$ENV_FILE" ]]; then
    cat > "$ENV_FILE" <<EOF
# WordPress Multi-site Configuration
# Environment: ${DEPLOY_ENV}
# Auto-generated by setup.sh
EOF
    track_created_file "$ENV_FILE"
    log "✓ Created .env file"
  else
    log "✓ .env file already exists"
  fi

  # Create init-databases.sql if missing
  if [[ ! -f "$DB_INIT" ]]; then
    cat > "$DB_INIT" <<EOF
-- Auto-generated by setup.sh
-- WordPress Multi-site Database Initialization
EOF
    track_created_file "$DB_INIT"
    log "✓ Created init-databases.sql"
  else
    log "✓ init-databases.sql already exists"
  fi

  # Copy nginx.conf if missing
  NGINX_CONF_TARGET="${TARGET_NGINX_DIR}/nginx.conf"
  if [[ ! -f "$NGINX_CONF_TARGET" ]]; then
    if [[ -f "$TEMPLATE_NGINX_CONF" ]]; then
      cp -a "$TEMPLATE_NGINX_CONF" "$NGINX_CONF_TARGET"
      track_created_file "$NGINX_CONF_TARGET"
      log "✓ Copied nginx.conf"
    fi
  fi

  # Copy SSL params if missing
  if [[ ! -f "$SSL_PARAMS_TARGET" ]]; then
    if [[ -f "$SSL_PARAMS_MASTER" ]]; then
      cp -a "$SSL_PARAMS_MASTER" "$SSL_PARAMS_TARGET"
      track_created_file "$SSL_PARAMS_TARGET"
      log "✓ Copied ssl-params.conf"
    fi
  fi

  # Copy or create fastcgi-cache.conf if missing
  if [[ ! -f "$FASTCGI_TARGET" ]]; then
    if [[ -f "$FASTCGI_MASTER" ]]; then
      cp -a "$FASTCGI_MASTER" "$FASTCGI_TARGET"
      track_created_file "$FASTCGI_TARGET"
      log "✓ Copied fastcgi-cache.conf"
    else
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
      log "✓ Created minimal fastcgi-cache.conf"
    fi
  fi

  log "✓ Base structure initialized"
}

# ---------- process single domain ----------
process_domain() {
  local DOMAIN="$1"
  local SHORT=$(short_name "$DOMAIN")
  local UPPER=$(upper "$SHORT")
  local SITE_DIR="${SITES_DIR}/${SHORT}"
  local NGINX_CONF="${TARGET_NGINX_DIR}/${DOMAIN}.conf"
  local CACHE_VOLUME="cache_${SHORT}"
  local DB_NAME="wp_${SHORT}"

  log "Processing $DOMAIN (short=$SHORT)..."

  # Store for docker-compose generation
  SITE_SHORTS+=("$SHORT")
  SITE_DOMAINS+=("$DOMAIN")
  SITE_DB_NAMES+=("$DB_NAME")
  SITE_VOLUMES+=("$CACHE_VOLUME")

  # 1) Create site directory
  if [[ "${DRY_RUN}" == false ]]; then
    # Auto-clean if folder exists (from failed previous run)
    if [[ -d "$SITE_DIR" ]]; then
      sudo rm -rf "$SITE_DIR" 2>/dev/null || rm -rf "$SITE_DIR"
    fi
    safe_mkdir "$SITE_DIR"
    safe_mkdir "$SITE_DIR/wordpress"
    cp -a "${TEMPLATE_SITE}/Dockerfile" "$SITE_DIR/" || true
    cp -a "${TEMPLATE_SITE}/php.ini" "$SITE_DIR/" || true
    cp -a "${TEMPLATE_SITE}/www.conf" "$SITE_DIR/" || true

    track_created_file "$SITE_DIR/Dockerfile"
    log "  ✓ Site directory created"
  fi

  # 2) Download WordPress
  if [[ "${DRY_RUN}" == false ]]; then
    if [[ -z "$(ls -A "$SITE_DIR/wordpress" 2>/dev/null)" ]]; then
      wget -q https://wordpress.org/latest.tar.gz -O /tmp/wordpress.tar.gz
      tar -xzf /tmp/wordpress.tar.gz -C /tmp/
      mv /tmp/wordpress/* "$SITE_DIR/wordpress/"
      rm -rf /tmp/wordpress /tmp/wordpress.tar.gz
      log "  ✓ WordPress downloaded"
    else
      log "  ✓ WordPress already exists"
    fi
  fi

  # 3) Update database init
  if [[ "${DRY_RUN}" == false ]]; then
    if ! grep -q "$DB_NAME" "$DB_INIT" 2>/dev/null; then
      cat >> "$DB_INIT" <<EOF

CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO 'wp_user'@'%';
FLUSH PRIVILEGES;
EOF
      log "  ✓ Database entry added"
    fi
  fi

  # 4) Update .env
  if [[ "${DRY_RUN}" == false ]]; then
    COUNT_EXISTING=$(grep -c '^SITE[0-9]\+_DOMAIN=' "$ENV_FILE" 2>/dev/null || true)
    IDX=$(( COUNT_EXISTING + 1 ))
    echo "SITE${IDX}_DOMAIN=${DOMAIN}" >> "$ENV_FILE"
    echo "SITE${IDX}_DB_NAME=${DB_NAME}" >> "$ENV_FILE"
    log "  ✓ Environment variables added"
  fi

  # 5) Generate nginx config
  if [[ "${DRY_RUN}" == false ]]; then
    sed -e "s/{{DOMAIN}}/${DOMAIN}/g" \
        -e "s/{{SHORT}}/${SHORT}/g" \
        -e "s/{{UPPER}}/${UPPER}/g" \
        "$TEMPLATE_NGINX" > "$NGINX_CONF"

    track_created_file "$NGINX_CONF"
    log "  ✓ Nginx config created"
  fi

  # 6) Add FastCGI cache zone
  if [[ "${DRY_RUN}" == false ]]; then
    if ! grep -q "keys_zone=${UPPER}" "$FASTCGI_TARGET"; then
      CACHE_BLOCK="
fastcgi_cache_path /var/cache/nginx/${SHORT}
    levels=1:2
    keys_zone=${UPPER}:100m
    max_size=1g
    inactive=60m
    use_temp_path=off;"

      if grep -q "{{CACHE_ZONES}}" "$FASTCGI_TARGET"; then
        awk -v block="$CACHE_BLOCK" '
          /{{CACHE_ZONES}}/ {
            gsub(/{{CACHE_ZONES}}/, block "\n{{CACHE_ZONES}}");
          }
          { print }
        ' "$FASTCGI_TARGET" > "${FASTCGI_TARGET}.tmp" && mv "${FASTCGI_TARGET}.tmp" "$FASTCGI_TARGET"
      else
        echo "$CACHE_BLOCK" >> "$FASTCGI_TARGET"
      fi
      log "  ✓ Cache zone added"
    fi
  fi

  # 7) Setup SSL
  if [[ "${DRY_RUN}" == false ]]; then
    safe_mkdir "${SSL_DIR}"
    safe_mkdir "${SSL_DIR}/${DOMAIN}"

    # Stop nginx for standalone certbot
    docker compose -f "$COMPOSE_FILE" stop nginx 2>/dev/null || true

    info "  Requesting SSL certificate for ${DOMAIN}..."
    sudo certbot certonly --standalone \
      -d "${DOMAIN}" -d "www.${DOMAIN}" \
      --agree-tos --no-eff-email --register-unsafely-without-email \
      --non-interactive || {
        err "  Certbot failed for ${DOMAIN}"
        warn "  You may need to manually fix SSL later"
        return
    }

    sudo mkdir -p "${SSL_DIR}/${DOMAIN}"
    sudo cp -L /etc/letsencrypt/live/"${DOMAIN}"/{fullchain.pem,privkey.pem,chain.pem} "${SSL_DIR}/${DOMAIN}/"
    sudo chmod -R 644 "${SSL_DIR}/${DOMAIN}"
    sudo chmod 600 "${SSL_DIR}/${DOMAIN}/privkey.pem"
    log "  ✓ SSL certificate issued"

    # Restart nginx
    docker compose -f "$COMPOSE_FILE" up -d nginx 2>/dev/null || true
  fi

  # 8) Setup cron for renewal
  if [[ "${DRY_RUN}" == false ]]; then
    CRON_CMD="0 3 * * 0 certbot certonly --webroot -w ${SITE_DIR}/wordpress -d ${DOMAIN} -d www.${DOMAIN} --quiet && docker compose -f ${COMPOSE_FILE} restart nginx"
    (sudo crontab -l 2>/dev/null | grep -v "$DOMAIN" || true; echo "$CRON_CMD") | sudo crontab -
    log "  ✓ Cron entry installed"
  fi

  # ✅ Fix permission to match container (www-data UID 82)
  sudo chown -R 82:82 "$SITE_DIR" 2>/dev/null || chown -R 82:82 "$SITE_DIR"

  log "  ✓ Finished processing ${DOMAIN}"
}

# ---------- generate docker-compose.yml ----------
generate_docker_compose() {
  log "Generating docker-compose.yml..."

  if [[ "${DRY_RUN}" == true ]]; then
    echo "[DRY] Would generate docker-compose.yml"
    return
  fi

  backup_file "$COMPOSE_FILE"

  # Start with base
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

  # Nginx config
  cat >> "$COMPOSE_FILE" <<'NGINX_PORTS'
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx/includes:/etc/nginx/includes:ro
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./ssl:/etc/letsencrypt:ro
NGINX_PORTS

  # Add site-specific volumes
  for i in "${!SITE_SHORTS[@]}"; do
    SHORT="${SITE_SHORTS[$i]}"
    DOMAIN="${SITE_DOMAINS[$i]}"
    VOLUME="${SITE_VOLUMES[$i]}"

    cat >> "$COMPOSE_FILE" <<NGINX_VOLUMES
      - ./nginx/${DOMAIN}.conf:/etc/nginx/conf.d/${DOMAIN}.conf:ro
      - ./sites/${SHORT}/wordpress:/var/www/${SHORT}:ro
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
      context: ./sites/${SHORT}
      dockerfile: Dockerfile
    container_name: wp_php_${SHORT}
    volumes:
      - ./sites/${SHORT}/wordpress:/var/www/html
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
  log "✓ Generated docker-compose.yml with ${#SITE_SHORTS[@]} site(s)"
}

# ---------- cleanup placeholders ----------
cleanup_placeholders() {
  if [[ "${DRY_RUN}" == false ]]; then
    sed -i '/{{CACHE_ZONES}}/d' "$FASTCGI_TARGET" 2>/dev/null || true
  fi
}

# ============================================================================
# COMMANDS
# ============================================================================

# ---------- cmd: init ----------
cmd_init() {
  log "Initializing new deployment: ${DEPLOY_ENV}"

  # Check if already exists
  if [[ -d "$DEPLOY_DIR" ]] && [[ -f "$COMPOSE_FILE" ]]; then
    detect_existing_sites
    if [[ ${#EXISTING_SITES[@]} -gt 0 ]]; then
      warn "Deployment already exists with ${#EXISTING_SITES[@]} site(s)"
      warn "Existing sites: ${EXISTING_SITES[*]}"
      read -rp "Continue and add more sites? [y/N]: " confirm
      if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log "Cancelled. Use '$0 add <domain>' to add sites."
        exit 0
      fi
    fi
  fi

  # Install dependencies
  install_docker_if_missing
  install_dependencies_if_missing
  verify_docker_access
  system_checks

  # Initialize structure
  init_base_structure

  # Ask for sites
  read -rp "How many sites to create? [1-10]: " TOTAL
  if ! [[ "$TOTAL" =~ ^[0-9]+$ ]] || [[ "$TOTAL" -lt 1 ]] || [[ "$TOTAL" -gt 10 ]]; then
    err "Invalid number. Must be between 1-10"
    exit 1
  fi

  DOMAINS=()
  for ((i=1;i<=TOTAL;i++)); do
    while true; do
      read -rp "Enter domain #$i (e.g., example.com): " D
      if [[ -z "$D" ]]; then
        warn "Domain cannot be empty"
        continue
      fi

      if [[ " ${EXISTING_SITES[*]} " =~ " ${D} " ]]; then
        warn "Domain $D already exists!"
        continue
      fi

      DOMAINS+=("$D")
      break
    done
  done

  # Process all domains
  for DOMAIN in "${DOMAINS[@]}"; do
    process_domain "$DOMAIN"
  done

  # Cleanup and generate compose
  cleanup_placeholders
  generate_docker_compose

  # Start containers
  read -rp "Start containers now? [Y/n]: " start_now
  if [[ ! "$start_now" =~ ^[Nn]$ ]]; then
    log "Building and starting containers..."
    cd "$DEPLOY_DIR"
    docker compose build
    docker compose up -d
    log "✓ Containers started"
  fi

  # ✅ Global permission fix for all sites
  sudo chown -R 82:82 "${DEPLOY_DIR}/sites" 2>/dev/null || true

  log "✓ Initialization complete!"
  log ""
  log "Next steps:"
  log "  - Check status: cd ${DEPLOY_DIR} && docker compose ps"
  log "  - View logs: cd ${DEPLOY_DIR} && docker compose logs -f"
  log "  - Add more sites: $0 add <domain>"
}

# ---------- cmd: add ----------
cmd_add() {
  local NEW_DOMAIN="$1"

  if [[ -z "$NEW_DOMAIN" ]]; then
    err "Usage: $0 add <domain>"
    err "Example: $0 add example.com"
    exit 1
  fi

  # Check deployment exists
  if [[ ! -d "$DEPLOY_DIR" ]] || [[ ! -f "$COMPOSE_FILE" ]]; then
    err "Deployment not found. Run '$0 init' first."
    exit 1
  fi

  detect_existing_sites

  # Check if already exists
  if [[ " ${EXISTING_SITES[*]} " =~ " ${NEW_DOMAIN} " ]]; then
    err "Site $NEW_DOMAIN already exists!"
    exit 1
  fi

  log "Adding new site: $NEW_DOMAIN"

  install_docker_if_missing
  install_dependencies_if_missing
  verify_docker_access
  system_checks

  # Load existing sites into arrays
  for site in "${EXISTING_SITES[@]}"; do
    SHORT=$(short_name "$site")
    SITE_SHORTS+=("$SHORT")
    SITE_DOMAINS+=("$site")
    SITE_DB_NAMES+=("wp_$SHORT")
    SITE_VOLUMES+=("cache_$SHORT")
  done

  # Process the new domain
  process_domain "$NEW_DOMAIN"

  # Regenerate docker-compose with new site
  cleanup_placeholders
  generate_docker_compose

  # Build and start only new containers
  SHORT=$(short_name "$NEW_DOMAIN")
  log "Building new containers..."
  cd "$DEPLOY_DIR"
  docker compose build php_${SHORT}
  docker compose up -d

  # ✅ Global permission fix for all sites
  sudo chown -R 82:82 "${DEPLOY_DIR}/sites" 2>/dev/null || true

  log "✓ Site $NEW_DOMAIN added successfully!"
  log "  Access at: https://$NEW_DOMAIN"
}

# ---------- cmd: list ----------
cmd_list() {
  if [[ ! -d "$DEPLOY_DIR" ]]; then
    warn "No deployment found at: $DEPLOY_DIR"
    exit 0
  fi

  detect_existing_sites

  log "Deployment: ${DEPLOY_ENV}"
  log "Location: ${DEPLOY_DIR}"
  echo ""

  if [[ ${#EXISTING_SITES[@]} -eq 0 ]]; then
    warn "No sites configured yet"
    log "Run '$0 init' to create your first site"
    exit 0
  fi

  log "Configured sites: ${#EXISTING_SITES[@]}"
  echo ""

  for site in "${EXISTING_SITES[@]}"; do
    SHORT=$(short_name "$site")

    # Check container status
    if [[ -f "$COMPOSE_FILE" ]] && docker compose -f "$COMPOSE_FILE" ps php_${SHORT} 2>/dev/null | grep -q Up; then
      STATUS="${GREEN}running${NC}"
    else
      STATUS="${RED}stopped${NC}"
    fi

    # Check SSL
    SSL_FILE="${SSL_DIR}/${site}/fullchain.pem"
    if [[ -f "$SSL_FILE" ]]; then
      EXPIRY=$(openssl x509 -enddate -noout -in "$SSL_FILE" 2>/dev/null | cut -d= -f2)
      SSL_STATUS="${GREEN}valid${NC} (expires: $EXPIRY)"
    else
      SSL_STATUS="${RED}missing${NC}"
    fi

    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}Site:${NC}     $site"
    echo -e "${GREEN}Status:${NC}   $STATUS"
    echo -e "${GREEN}Database:${NC} wp_${SHORT}"
    echo -e "${GREEN}SSL:${NC}      $SSL_STATUS"
    echo -e "${GREEN}Path:${NC}     ${SITES_DIR}/${SHORT}"
  done

  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# ---------- cmd: remove ----------
cmd_remove() {
  local TARGET="$1"

  if [[ -z "$TARGET" ]]; then
    err "Usage: $0 remove <domain|--all>"
    err "Example: $0 remove example.com"
    err "         $0 remove --all"
    exit 1
  fi

  detect_existing_sites

  if [[ "$TARGET" == "--all" ]]; then
    if [[ ${#EXISTING_SITES[@]} -eq 0 ]]; then
      warn "No sites to remove"
      exit 0
    fi

    warn "This will remove ALL ${#EXISTING_SITES[@]} site(s):"
    for site in "${EXISTING_SITES[@]}"; do
      echo "  - $site"
    done
    echo ""
    read -rp "Type 'yes' to confirm: " confirm
    if [[ "$confirm" != "yes" ]]; then
      log "Cancelled"
      exit 0
    fi

    log "Stopping all containers..."
    cd "$DEPLOY_DIR"
    docker compose down -v

    log "Removing all sites..."
    for site in "${EXISTING_SITES[@]}"; do
      SHORT=$(short_name "$site")
      sudo rm -rf "${SITES_DIR}/${SHORT}" 2>/dev/null || rm -rf "${SITES_DIR}/${SHORT}"
      rm -f "${TARGET_NGINX_DIR}/${site}.conf"
      sudo rm -rf "${SSL_DIR}/${site}" 2>/dev/null || true
      sudo crontab -l 2>/dev/null | grep -v "$site" | sudo crontab - 2>/dev/null || true
    done

    # Clear config files
    cat > "$ENV_FILE" <<EOF
# WordPress Multi-site Configuration
# Environment: ${DEPLOY_ENV}
# Auto-generated by setup.sh
EOF

    cat > "$DB_INIT" <<EOF
-- Auto-generated by setup.sh
-- WordPress Multi-site Database Initialization
EOF

    log "✓ All sites removed"
    log "Run '$0 init' to create new sites"
    exit 0
  fi

  # Remove specific site
  DOMAIN="$TARGET"
  SHORT=$(short_name "$DOMAIN")

  if [[ ! " ${EXISTING_SITES[*]} " =~ " ${DOMAIN} " ]]; then
    err "Site $DOMAIN not found"
    err "Available sites: ${EXISTING_SITES[*]}"
    exit 1
  fi

  warn "Removing site: $DOMAIN"
  read -rp "Continue? [y/N]: " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    log "Cancelled"
    exit 0
  fi

  log "Stopping containers for $DOMAIN..."
  cd "$DEPLOY_DIR"
  docker compose stop php_${SHORT} redis_${SHORT} 2>/dev/null || true
  docker compose rm -f php_${SHORT} redis_${SHORT} 2>/dev/null || true

  log "Removing files..."
  sudo rm -rf "${SITES_DIR}/${SHORT}" 2>/dev/null || rm -rf "${SITES_DIR}/${SHORT}"
  rm -f "${TARGET_NGINX_DIR}/${DOMAIN}.conf"
  sudo rm -rf "${SSL_DIR}/${DOMAIN}" 2>/dev/null || true

  log "Updating configuration..."
  # Remove from .env
  sed -i "/SITE.*_DOMAIN=${DOMAIN}/d" "$ENV_FILE"
  sed -i "/SITE.*_DB_NAME=wp_${SHORT}/d" "$ENV_FILE"

  # Remove from database init
  sed -i "/CREATE DATABASE IF NOT EXISTS wp_${SHORT}/,/FLUSH PRIVILEGES;/d" "$DB_INIT"

  # Remove from fastcgi cache
  UPPER=$(upper "$SHORT")
  sed -i "/fastcgi_cache_path \/var\/cache\/nginx\/${SHORT}/,/use_temp_path=off;/d" "$FASTCGI_TARGET"

  # Remove cron
  sudo crontab -l 2>/dev/null | grep -v "$DOMAIN" | sudo crontab - 2>/dev/null || true

  # Rebuild remaining sites arrays
  SITE_SHORTS=()
  SITE_DOMAINS=()
  SITE_DB_NAMES=()
  SITE_VOLUMES=()

  for site in "${EXISTING_SITES[@]}"; do
    if [[ "$site" != "$DOMAIN" ]]; then
      s=$(short_name "$site")
      SITE_SHORTS+=("$s")
      SITE_DOMAINS+=("$site")
      SITE_DB_NAMES+=("wp_$s")
      SITE_VOLUMES+=("cache_$s")
    fi
  done

  # Regenerate docker-compose
  if [[ ${#SITE_SHORTS[@]} -gt 0 ]]; then
    generate_docker_compose
    docker compose down
    docker compose up -d
  else
    log "No sites remaining. Stopping all containers..."
    docker compose down -v
  fi

  log "✓ Site $DOMAIN removed successfully"
}

# ---------- cmd: clean ----------
cmd_clean() {
  if [[ ! -d "$DEPLOY_DIR" ]]; then
    warn "No deployment found at: $DEPLOY_DIR"
    exit 0
  fi

  detect_existing_sites

  warn "This will completely remove the ${DEPLOY_ENV} deployment"
  if [[ ${#EXISTING_SITES[@]} -gt 0 ]]; then
    warn "Including ${#EXISTING_SITES[@]} site(s): ${EXISTING_SITES[*]}"
  fi
  echo ""
  read -rp "Type 'yes' to confirm: " confirm
  if [[ "$confirm" != "yes" ]]; then
    log "Cancelled"
    exit 0
  fi

  if [[ -f "$COMPOSE_FILE" ]]; then
    log "Stopping containers..."
    cd "$DEPLOY_DIR"
    docker compose down -v 2>/dev/null || true
  fi

  log "Removing deployment directory..."
  sudo rm -rf "$DEPLOY_DIR"

  # Remove cron entries
  for site in "${EXISTING_SITES[@]}"; do
    sudo crontab -l 2>/dev/null | grep -v "$site" | sudo crontab - 2>/dev/null || true
  done

  log "✓ Deployment cleaned"
  log "Run '$0 init' to create a new deployment"
}

# ============================================================================
# MAIN ROUTER
# ============================================================================

if [[ -z "$COMMAND" ]]; then
  usage
fi

case "$COMMAND" in
  init)
    cmd_init "$@"
    ;;
  add)
    cmd_add "$@"
    ;;
  remove|rm)
    cmd_remove "$@"
    ;;
  list|ls)
    cmd_list
    ;;
  clean)
    cmd_clean
    ;;
  *)
    err "Unknown command: $COMMAND"
    usage
    ;;
esac

# Clean up backup dir if everything succeeded
if [[ -d "$BACKUP_DIR" ]] && [[ ${#MODIFIED_FILES[@]} -eq 0 ]]; then
  rm -rf "$BACKUP_DIR"
fi
