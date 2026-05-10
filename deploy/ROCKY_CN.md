# Rocky Linux 部署说明

## 当前项目部署需要的环境

推荐方式是 `Docker Compose`，因为这样宿主机不需要单独安装 `Go`、`Node.js`、`pnpm`、`PostgreSQL`、`Redis`。当前仓库会通过多阶段 `Dockerfile` 在容器内完成前后端构建。

宿主机需要：

- Rocky Linux 8 / 9
- `systemd`
- `dnf`
- `curl`
- `git`
- `openssl`
- `tar`
- Docker Engine
- Docker Compose Plugin

容器内会使用：

- Node.js 24
- pnpm
- Go 1.26.2
- PostgreSQL 18
- Redis 8

需要放通的端口：

- `18080/tcp`
  说明：Sub2API 默认只绑定本机 `127.0.0.1:18080`，公网入口建议走 Nginx `80/443`，可通过 `SERVER_PORT` 修改

可选环境：

- Nginx / Caddy
  说明：如果需要域名、HTTPS、反向代理再加
- 若使用 Nginx 且要兼容 Codex CLI 粘性会话，需要在 `http` 块开启 `underscores_in_headers on;`

## 新增脚本

- `deploy/docker-compose.current.yml`
  说明：使用当前仓库代码构建镜像并启动 `sub2api + postgres + redis`
- `deploy/rocky-deploy.sh`
  说明：在 Rocky 服务器本机执行，自动安装 Docker、生成 `.env`、启动容器
- `deploy/push-current-to-rocky.sh`
  说明：在本机执行，把当前仓库上传到远端 Rocky 并触发部署
- `deploy/rocky-binary-deploy.sh`
  说明：在 Rocky 服务器本机执行，安装 `PostgreSQL + Valkey`，部署当前项目二进制并注册 systemd
- `deploy/push-binary-to-rocky.sh`
  说明：在本机执行，本地编译 Linux 二进制并推送到远端，适合远端无法访问 Docker 仓库/镜像仓库的场景
- `deploy/rocky-nginx-https.sh`
  说明：在 Rocky 服务器本机执行，安装 Nginx 并配置 HTTPS 反向代理
- `deploy/push-nginx-to-rocky.sh`
  说明：在本机执行，把 Nginx HTTPS 脚本推到远端并直接安装

## 用法

在服务器本机执行：

```bash
cd /opt/sub2api/current
bash deploy/rocky-deploy.sh --admin-email admin@example.com --port 18080
```

在本机直接推送到远端：

```bash
cd /path/to/sub2api
SSH_HOST=SERVER_IP bash deploy/push-current-to-rocky.sh
```

脚本会直接调用：

```bash
scp ...
ssh root@SERVER_IP ...
```

然后由你在终端里手工输入 SSH 密码。  
如果你明确需要非交互，也可以额外传：

```bash
SSH_HOST=SERVER_IP SSH_PASSWORD='your-password' bash deploy/push-current-to-rocky.sh
```

更推荐 SSH key 自动化：

```bash
ssh-keygen -t ed25519 -f ~/.ssh/sub2api_rocky -N ''
ssh-copy-id -i ~/.ssh/sub2api_rocky.pub root@SERVER_IP
SSH_HOST=SERVER_IP SSH_KEY_PATH=~/.ssh/sub2api_rocky bash deploy/push-current-to-rocky.sh
```

如果本机没有 `ssh-copy-id`，也可以手工追加公钥：

```bash
cat ~/.ssh/sub2api_rocky.pub
```

把输出内容追加到远端：

```bash
/root/.ssh/authorized_keys
```

如果你想固定后台管理员密码，可以额外传：

```bash
SSH_HOST=SERVER_IP ADMIN_PASSWORD='YourStrongPassword' bash deploy/push-current-to-rocky.sh
```

启动后常用命令：

```bash
cd /opt/sub2api/current
docker compose --env-file deploy/.env -f deploy/docker-compose.current.yml ps
docker compose --env-file deploy/.env -f deploy/docker-compose.current.yml logs -f sub2api
docker compose --env-file deploy/.env -f deploy/docker-compose.current.yml up -d --build
docker compose --env-file deploy/.env -f deploy/docker-compose.current.yml down
```

## Rocky 10 建议

如果目标 Rocky 服务器访问不了 `download.docker.com` 或 `docker.io`，优先用二进制离线部署：

```bash
cd /path/to/sub2api
SSH_HOST=SERVER_IP SSH_KEY_PATH=~/.ssh/sub2api_rocky bash deploy/push-binary-to-rocky.sh
```

远端会安装：

- PostgreSQL 16
- Valkey 8
- Sub2API systemd 服务

常用命令：

```bash
ssh root@SERVER_IP
systemctl status sub2api
journalctl -u sub2api -f
curl http://127.0.0.1:18080/health
```

## Nginx + HTTPS

### 适用场景

- 需要把 `Sub2API` 放到 `80/443`
- 需要 TLS 终止、反向代理、WebSocket 透传
- 需要兼容粘性会话请求头

脚本默认会：

- 安装 `nginx`
- 在 `http` 作用域开启 `underscores_in_headers on;`
- 反代到 `127.0.0.1:18080`
- 开放 `80/tcp` 和 `443/tcp`
- 在启用 SELinux 时自动设置 `httpd_can_network_connect=1`

### 先用自签证书

没有域名时，先用自签证书起 HTTPS：

```bash
cd /path/to/sub2api
SSH_HOST=SERVER_IP \
SSH_KEY_PATH=~/.ssh/sub2api_rocky \
SERVER_NAME=SERVER_IP \
bash deploy/push-nginx-to-rocky.sh
```

这会生成：

- `/etc/nginx/certs/sub2api-selfsigned.crt`
- `/etc/nginx/certs/sub2api-selfsigned.key`

注意：

- 浏览器会提示证书不受信任
- 这是正常现象，因为是自签证书

### 切换到 Let's Encrypt

有域名并且域名已经解析到服务器后：

```bash
cd /path/to/sub2api
SSH_HOST=SERVER_IP \
SSH_KEY_PATH=~/.ssh/sub2api_rocky \
SERVER_NAME=api.example.com \
CERT_MODE=letsencrypt \
LETSENCRYPT_EMAIL=you@example.com \
bash deploy/push-nginx-to-rocky.sh
```

要求：

- 域名已正确解析到服务器
- 外网可访问 `80/443`
- 服务器能访问 Let's Encrypt

### 常用命令

```bash
ssh root@SERVER_IP
systemctl status nginx
nginx -t
journalctl -u nginx -f
curl -k https://127.0.0.1/health
```

## 本次部署记录

目标机器：

- 系统：`Rocky Linux 10.1`
- 地址：`SERVER_IP`
- 最终部署方式：`本地编译 Linux 二进制 + 远端安装 PostgreSQL/Valkey + systemd`

最终结果：

- `sub2api` 已部署到 `/opt/sub2api`
- 环境变量文件写入 `/etc/sub2api/sub2api.env`
- 服务名：`sub2api`
- 数据库：`PostgreSQL 16`
- 缓存：`Valkey 8`
- 健康检查：远端本机 `curl http://127.0.0.1:18080/health` 返回 `{"status":"ok"}`

## 本次遇到的问题与解决方案

### 1. SSH 密码自动输入不稳定

现象：

- 手工执行 `ssh root@SERVER_IP` 可以登录
- 但脚本通过 `expect` 自动喂密码时，远端一直返回 `Permission denied`

原因：

- 这台机器的 SSH 密码交互在当前自动执行环境里不稳定
- 问题不在 SSH 命令本身，在于自动密码输入链路

解决方案：

- 改用 SSH key 自动化
- 新增并使用 `~/.ssh/sub2api_rocky` 这对密钥
- `deploy/push-current-to-rocky.sh` 和 `deploy/push-binary-to-rocky.sh` 都已支持 `SSH_KEY_PATH`

示例：

```bash
SSH_HOST=SERVER_IP SSH_KEY_PATH=~/.ssh/sub2api_rocky bash deploy/push-binary-to-rocky.sh
```

### 2. Rocky 10 无法访问 Docker CE 仓库

现象：

- 安装 Docker 时访问 `https://download.docker.com/linux/centos/10/...` 失败
- 报错类似：`SSL connect error`、`连接被对方重置`

原因：

- 远端网络无法稳定访问 Docker CE 软件源
- 所以 `deploy/rocky-deploy.sh` 这条 Docker 路径在这台机器上不适合直接使用

解决方案：

- 放弃远端在线安装 Docker
- 改走二进制离线部署
- 新增：
  - `deploy/rocky-binary-deploy.sh`
  - `deploy/push-binary-to-rocky.sh`

### 3. 远端无法拉取 Docker 镜像

现象：

- 远端 `podman pull docker.io/library/alpine:3.21` 超时
- `docker.io` 访问失败

原因：

- 远端不仅 Docker 软件源不可用，镜像仓库访问也受限

解决方案：

- 不再依赖远端拉镜像
- 改为本机编译产物后直接上传到服务器

### 4. 本机前端依赖从 npm 官方源下载过慢

现象：

- 首次 `pnpm install` 很慢，长时间停留在下载依赖阶段

原因：

- 本机直连 npm 官方源速度较差

解决方案：

- 在 `deploy/push-binary-to-rocky.sh` 中默认加：

```bash
NPM_CONFIG_REGISTRY=https://registry.npmmirror.com
```

- 这样前端依赖安装可以走缓存和国内镜像

### 5. Go 工具链自动下载失败

现象：

- 本机 Go 构建时尝试下载 `go1.26.2` 工具链
- 访问 `proxy.golang.org` 超时

原因：

- 仓库 `backend/go.mod` 声明版本是 `go 1.26.2`
- 本机安装的是 `go1.26.1`
- Go 默认会尝试补齐 patch 版本工具链

解决方案：

- 在临时构建目录里把 `go.mod` 的 patch 版本改成当前本机 Go 版本
- 构建时加：

```bash
GOTOOLCHAIN=local
```

- 避免自动下载工具链

### 6. Go 模块下载从官方源超时

现象：

- `go build` 阶段拉模块很慢，默认源超时

原因：

- 本机访问默认 Go 模块源不稳定

解决方案：

- 在 `deploy/push-binary-to-rocky.sh` 中默认加：

```bash
GOPROXY_VALUE=https://goproxy.cn,direct
GOSUMDB_VALUE=sum.golang.google.cn
```

- 构建时显式传入 `GOPROXY` 和 `GOSUMDB`

### 7. 前端构建产物路径与脚本假设不一致

现象：

- Vite 构建已经成功
- 但脚本在复制 `frontend/dist` 时失败，提示目录不存在

原因：

- 这个仓库的前端构建产物直接输出到：

```bash
backend/internal/web/dist
```

- 不是固定输出到 `frontend/dist`

解决方案：

- 调整 `deploy/push-binary-to-rocky.sh`
- 优先兼容当前仓库已有的 `backend/internal/web/dist`
- 如果未来切回 `frontend/dist`，脚本也能兼容

### 8. PostgreSQL 默认 `pg_hba.conf` 使用 `ident`

现象：

- `sub2api` 服务启动后不断重试
- 日志报错：

```text
pq: 用户 "sub2api" Ident 认证失败
```

原因：

- Rocky 10 默认初始化出来的 PostgreSQL 本地认证策略里：
  - `127.0.0.1/32` 是 `ident`
  - `::1/128` 是 `ident`
- 应用使用的是用户名+密码连接

解决方案：

- 在 `deploy/rocky-binary-deploy.sh` 中初始化 PostgreSQL 后，自动把本地认证改成：
  - `scram-sha-256`
- 已修正这三行：
  - `local all all`
  - `host all all 127.0.0.1/32`
  - `host all all ::1/128`

修复后结果：

- `sub2api` 自动初始化成功
- 管理员账号创建成功
- 服务进入 `active`

### 9. 外部访问与服务器本机访问结论不同

现象：

- 从当前执行环境访问 `http://SERVER_IP:18080` 不稳定
- 但在服务器本机：

```bash
curl http://127.0.0.1:18080/health
```

- 返回正常

结论：

- 服务本身已经正常监听 `127.0.0.1:18080`
- 如果外部设备访问异常，优先排查本地网络、路由、主机防火墙或内网可达性

## 结论

对于这台 `Rocky Linux 10.1`：

- 不推荐优先走 Docker 在线部署
- 推荐固定使用：

```bash
SSH_HOST=SERVER_IP SSH_KEY_PATH=~/.ssh/sub2api_rocky bash deploy/push-binary-to-rocky.sh
```

这条路径已经验证可用，并且把本次遇到的网络、构建、数据库认证问题都收敛进脚本里了。
