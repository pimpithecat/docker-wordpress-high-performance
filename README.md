# High-Performance WordPress Docker

**Automated multi-site WordPress deployment** with Nginx, PHP-FPM, MySQL 8, and Redis caching. One script to rule them all.

## ⚡ Performance

Tested on **Hetzner Cloud SG** (1 vCPU, 2 GB RAM):
- **~17 req/s** sustained (1,000+ req/min)
- **P95 latency: 2.5s** under 100 concurrent users
- **71% success rate** at CPU saturation
- **FastCGI + Redis** caching enabled
- Optimal for **25-40 concurrent users** on single vCPU

*Scale to 2+ vCPU for production workloads.*

---

## 🚀 Quick Start
```bash
git clone https://github.com/pimpithecat/docker-wordpress-high-performance.git
cd docker-wordpress-high-performance
sudo chmod +x ./setup.sh
```

**⚠️ Cloudflare Users:** Disable proxy (gray cloud ☁️) before running setup. Re-enable orange cloud 🟠 after SSL certificates are issued.
```bash
./setup.sh init
```

Follow prompts to create your first site. SSL certificates generated automatically.

### After Installation

1. **Access your WordPress site** at `https://yourdomain.com`
2. Complete WordPress setup (site title, admin user, password)
3. **Install Redis Object Cache plugin:**
   - Go to **Plugins → Add New**
   - Search for "**Redis Object Cache**"
   - Install and activate
4. **Enable Redis:**
   - Go to **Settings → Redis**
   - Click "**Enable Object Cache**"
   - Verify status shows "**Connected**"

✅ Your site is now fully optimized with FastCGI + Redis caching!

---

## 📦 What Gets Installed

The script **automatically checks and installs** missing dependencies:

### Auto-installed if missing:
- **Docker Engine** (latest from official Docker repository)
- **Docker Compose Plugin** (v2)
- **certbot** (Let's Encrypt SSL certificates)
- **openssl** (password generation & SSL)
- **wget** (WordPress download)

### Auto-configured:
- Adds current user to `docker` group (no sudo needed)
- Creates deployment directory structure
- Generates secure database passwords
- Sets up SSL auto-renewal cron jobs

**Already have them?** Script detects existing installations and skips automatically. ✅

---

## 📋 Core Commands
```bash
./setup.sh add example.com         # Add new site
./setup.sh remove example.com      # Remove site + DB + cache
./setup.sh remove --all            # Remove ALL sites (keep infrastructure)
./setup.sh list                    # Show all sites & status
./setup.sh clean                   # Nuke everything (full reset)
```

---

## 🔧 Essential Operations

### Cache Management
```bash
cd deployments/production

# Clear all caches for a site
docker compose exec nginx find /var/cache/nginx/sitename -type f -delete
docker compose exec redis_sitename redis-cli FLUSHALL
docker compose exec nginx nginx -s reload
```

### View Logs
```bash
docker compose logs -f                      # All services
docker compose logs php_sitename --tail=50  # Specific site
```

### Database Access
```bash
cat secrets/db_password.txt                 # Show password
docker compose exec db mysql -u wp_user -p$(cat secrets/db_password.txt)
```

### Restart Services
```bash
docker compose restart nginx
docker compose restart php_sitename
```

---

## 📁 Structure
```
master-template/       # Templates (git tracked)
  ├── nginx/
  └── site-template/

deployments/
  └── production/      # Generated (gitignored)
      ├── docker-compose.yml
      ├── sites/
      ├── ssl/
      └── secrets/
```

---

## 🆘 Quick Fixes

**Permission denied?**
```bash
sudo usermod -aG docker $USER
newgrp docker
```
**Redirects to `/wp-admin/install.php` showing "Already installed" after fresh setup?**
```bash
# This is FastCGI cache serving stale installation page
cd deployments/production
docker compose exec nginx find /var/cache/nginx/sitename -type f -delete
docker compose exec nginx nginx -s reload
# Hard refresh browser (Ctrl+Shift+R or Cmd+Shift+R)
```
**Why?** FastCGI cached the WordPress installer page. Clearing cache fixes it.

**Database error?**
```bash
# Recreate DB for site
docker compose exec db mysql -u root -p$(cat secrets/db_root_password.txt) \
  -e "CREATE DATABASE wp_sitename; GRANT ALL ON wp_sitename.* TO 'wp_user'@'%';"
```

**Redis not connecting?**
```bash
docker compose exec redis_sitename redis-cli ping  # Should return PONG
```

---

## 🔐 Security

- Auto-generated DB passwords (`secrets/`)
- Let's Encrypt SSL with auto-renewal
- Isolated Redis per site
- Non-root containers (UID 82)

---

## 📦 Backup
```bash
cp -a docker-wordpress-high-performance docker-wordpress-high-performance-backup
docker compose exec db mysqldump -u root -p$(cat secrets/db_root_password.txt) \
  --all-databases > backup-$(date +%Y%m%d).sql
```

---

**License:** MIT  
**Author:** [@pimpithecat](https://github.com/pimpithecat)
