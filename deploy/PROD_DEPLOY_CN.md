# api.example.com 部署与更新说明

本文记录当前 `sub2api` 项目在 `sub2api` 服务器上的实际部署方式，以及以后更新程序时的推荐操作。

## 当前部署结构

服务器：

```text
SSH alias: prod-sub2api
公网 IP: 203.0.113.10
部署目录: /opt/sub2api/current
访问域名: https://api.example.com
```

服务结构：

```text
公网 80/443
  -> Nginx
  -> 127.0.0.1:18080
  -> sub2api Docker 容器
  -> postgres Docker 容器
  -> redis Docker 容器
```

当前约定：

- `api.example.com` 是主域名。
- `example.com` 和 `www.example.com` 不再作为站点入口。
- `18080` 只监听 `127.0.0.1`，不直接暴露公网。
- PostgreSQL 和 Redis 数据必须保存在项目代码目录之外，避免更新代码时误删：

```text
/opt/sub2api/data/app
/opt/sub2api/data/postgres
/opt/sub2api/data/redis
```

重要：不要把数据库目录放在 `/opt/sub2api/current` 下面。`current` 是代码目录，可以被同步、替换、重建；数据库目录必须独立。

## 常用检查命令

登录服务器：

```bash
ssh prod-sub2api
```

查看容器状态：

```bash
cd /opt/sub2api/current
docker compose --env-file deploy/.env -f deploy/docker-compose.current.yml ps
```

查看应用日志：

```bash
cd /opt/sub2api/current
docker compose --env-file deploy/.env -f deploy/docker-compose.current.yml logs -f sub2api
```

健康检查：

```bash
curl http://127.0.0.1:18080/health
curl https://api.example.com/health
```

## 日常更新程序，不动数据库

适用于只改了前端、后端代码、静态资源，想保留数据库数据的情况。

安全原则：

- 只同步代码到 `/opt/sub2api/current`。
- 不删除 `/opt/sub2api/current` 整个目录。
- 不执行 `docker compose down -v`。
- 不删除 `/opt/sub2api/data`。
- 只重建 `sub2api` 应用容器，不重建 PostgreSQL/Redis 数据目录。

在本机执行：

```bash
cd /path/to/sub2api

COPYFILE_DISABLE=1 rsync -az --delete \
  --exclude='.git' \
  --exclude='frontend/node_modules' \
  --exclude='deploy/.env' \
  --exclude='deploy/.env.example' \
  --exclude='deploy/data' \
  --exclude='deploy/postgres_data' \
  --exclude='deploy/redis_data' \
  --exclude='data' \
  --exclude='postgres_data' \
  --exclude='redis_data' \
  -e 'ssh -i ~/.ssh/sub2api_prod' \
  ./ root@SERVER_IP:/opt/sub2api/current/
```

然后只重建应用容器：

```bash
ssh prod-sub2api

cd /opt/sub2api/current
find . -name '._*' -delete
docker compose --env-file deploy/.env -f deploy/docker-compose.current.yml up -d --no-deps --build sub2api
```

验证：

```bash
docker compose --env-file deploy/.env -f deploy/docker-compose.current.yml ps
curl http://127.0.0.1:18080/health
curl https://api.example.com/health
```

预期结果：

```text
sub2api          重建并 healthy
sub2api-postgres 不重启
sub2api-redis    不重启
```

也可以使用脚本：

```bash
cd /path/to/sub2api

SSH_HOST=203.0.113.10 \
SSH_USER=root \
SSH_KEY_PATH=~/.ssh/sub2api_prod \
REMOTE_BASE=/opt/sub2api \
SERVER_PORT=18080 \
SKIP_FIREWALL=1 \
ADMIN_EMAIL=admin@example.com \
bash deploy/push-current-to-rocky.sh
```

该脚本必须满足：

- 不能执行 `rm -rf /opt/sub2api/current`。
- 不能删除 `/opt/sub2api/data`。
- 数据目录在 `/opt/sub2api/data/*`，不在 `/opt/sub2api/current/*`。

执行前可以检查脚本是否安全：

```bash
grep -n 'rm -rf .*current' deploy/push-current-to-rocky.sh
```

如果有输出，不要执行。

## 备份数据库

做任何部署前，建议先备份数据库：

```bash
ssh prod-sub2api

cd /opt/sub2api/current
mkdir -p /opt/sub2api/backups
docker compose --env-file deploy/.env -f deploy/docker-compose.current.yml exec -T postgres \
  pg_dump -U sub2api -d sub2api --format=custom \
  > /opt/sub2api/backups/sub2api-$(date +%Y%m%d%H%M%S).dump
```

查看备份：

```bash
ls -lh /opt/sub2api/backups
```

恢复示例：

```bash
cd /opt/sub2api/current
docker compose --env-file deploy/.env -f deploy/docker-compose.current.yml exec -T postgres \
  pg_restore -U sub2api -d sub2api --clean --if-exists \
  < /opt/sub2api/backups/你的备份文件.dump
```

## 清库重新部署

适用于不需要保留现有数据，想全新初始化数据库的情况。

先确认真的要删除数据。清库会删除：

```text
/opt/sub2api/data/app
/opt/sub2api/data/postgres
/opt/sub2api/data/redis
```

执行：

```bash
ssh prod-sub2api

cd /opt/sub2api/current
find . -name '._*' -delete
docker compose --env-file deploy/.env -f deploy/docker-compose.current.yml down
rm -rf /opt/sub2api/data/app /opt/sub2api/data/postgres /opt/sub2api/data/redis
mkdir -p /opt/sub2api/data/app /opt/sub2api/data/postgres /opt/sub2api/data/redis
bash deploy/rocky-deploy.sh --deploy-dir /opt/sub2api --admin-email admin@example.com --port 18080 --tz Asia/Shanghai --skip-firewall
```

首次启动会自动创建管理员账号。查看自动生成的密码：

```bash
cd /opt/sub2api/current
docker compose --env-file deploy/.env -f deploy/docker-compose.current.yml logs sub2api | grep -i 'Generated admin password'
```

## Nginx 与 HTTPS

Nginx 配置文件：

```text
/etc/nginx/conf.d/sub2api-example.conf
```

证书路径：

```text
/etc/letsencrypt/live/api.example.com/fullchain.pem
/etc/letsencrypt/live/api.example.com/privkey.pem
```

查看证书：

```bash
ssh prod-sub2api
certbot certificates -d api.example.com
```

自动续期状态：

```bash
systemctl status certbot-renew.timer
```

手动测试续期：

```bash
certbot renew --dry-run
```

如果修改了 Nginx 配置：

```bash
nginx -t
systemctl reload nginx
```

## 域名说明

DNS 当前应包含：

```text
api.example.com -> 203.0.113.10
```

证书当前包含：

```text
api.example.com
```

规范访问地址：

```text
https://api.example.com
```

`https://example.com` 和 `https://www.example.com` 现在不再提供站点。

## 常见问题

### 1. 更新后页面没变化

先确认是否真的重建了 `sub2api` 镜像：

```bash
ssh prod-sub2api
cd /opt/sub2api/current
docker compose --env-file deploy/.env -f deploy/docker-compose.current.yml up -d --no-deps --build sub2api
```

然后浏览器强制刷新，或清理缓存后再访问：

```text
https://api.example.com
```

### 2. 出现 502

通常是应用容器没启动成功。

```bash
ssh prod-sub2api
cd /opt/sub2api/current
docker compose --env-file deploy/.env -f deploy/docker-compose.current.yml ps
docker compose --env-file deploy/.env -f deploy/docker-compose.current.yml logs --tail=200 sub2api
```

### 3. migration 报 `._xxx.sql`

这是 macOS AppleDouble 元数据文件被上传到了服务器。

处理：

```bash
ssh prod-sub2api
cd /opt/sub2api/current
find . -name '._*' -delete
docker compose --env-file deploy/.env -f deploy/docker-compose.current.yml up -d --no-deps --build sub2api
```

本机同步代码时需要带：

```bash
COPYFILE_DISABLE=1
```

### 4. 绝对不要使用的危险操作

保留数据库时不要执行：

```bash
rm -rf /opt/sub2api/current
rm -rf /opt/sub2api/data
docker compose down -v
docker compose --env-file deploy/.env -f deploy/docker-compose.current.yml down -v
```

原因：

- `/opt/sub2api/current` 是代码目录，旧版本曾把数据库放在它下面。
- `/opt/sub2api/data` 是当前数据库目录。
- `down -v` 会删除 Docker volume，可能清掉持久化数据。

日常更新只允许：

```bash
docker compose --env-file deploy/.env -f deploy/docker-compose.current.yml up -d --no-deps --build sub2api
```

### 5. 需要记住的入口

现在只使用：

```text
https://api.example.com
```

`example.com` 和 `www.example.com` 不再作为站点入口。

### 6. 需要临时检查应用本机端口

```bash
ssh prod-sub2api
curl http://127.0.0.1:18080/health
```

不要把 `18080` 直接开放到公网，公网访问走 Nginx 的 `80/443`。
