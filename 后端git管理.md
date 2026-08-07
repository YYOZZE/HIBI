# 后端 Git 管理指南

通过 Git 把本地 `backend_jideshi_hibi_app` 的代码同步到服务器，便于后续修改后一键更新，无需反复手动上传文件。

---

## 一、原则说明

- **代码进 Git**：`api_only_app.py`、`requirements.txt`、`Dockerfile`、`.env.example` 等。
- **不进 Git**：`.env`（含 API 密钥）、`__pycache__`。服务器上单独保留一份 `.env`，拉代码时不会被覆盖。

后端目录下已配置 `.gitignore`，会忽略 `.env` 和 Python 缓存。

---

## 二、两种常用方式

### 方式 A：用码云 / GitHub 做中转（推荐）

适合：希望代码有云端备份、多设备可拉取。

1. **在码云或 GitHub 建一个仓库**（可私有），例如命名为 `jideshi_hibi_backend`。
2. **本地把后端目录初始化为 Git 并推送到远程**（若整项目已是 Git 仓库，可只把后端当子目录推到一个独立仓库，见下方「单独为后端建仓库」）。
3. **服务器上克隆该仓库**，首次部署时在服务器上复制 `.env.example` 为 `.env` 并填写密钥。
4. **之后每次改完代码**：本地 `commit` → `push` → 服务器上 `git pull` → 按需重启 Docker 容器。

### 方式 B：本地直接推送到服务器（不经过码云/GitHub）

适合：只有你这台电脑和一台服务器，不想用第三方 Git 平台。

1. **在服务器上创建一个“裸仓库”**（bare repo），例如 `~/jideshi_hibi_backend.git`。
2. **在服务器上再建一个工作目录**，例如 `~/jideshi_hibi_backend`，从裸仓库 `git clone` 或配置 `git worktree` 检出代码。
3. **本地把服务器加为远程**，例如 `git remote add server admin@你的公网IP:~/jideshi_hibi_backend.git`。
4. **之后每次改完代码**：本地 `commit` → `git push server main` → 服务器上在工作目录 `git pull` → 按需重启容器。

下面分别写具体步骤。

---

## 三、方式 A 详细步骤（码云 / GitHub）

### 3.1 单独为后端建一个 Git 仓库（若当前后端只是项目子目录）

在**本机**项目根目录执行：

```powershell
cd C:\ALI_Z14\.TSING_important\Tsingcoop_products\pd\jideshi_hibi\backend_jideshi_hibi_app
git init
git add .
git commit -m "init: 希比智能体后端"
```

在码云 / GitHub 新建仓库（如 `jideshi_hibi_backend`），**不要**勾选“用 README 初始化”。然后添加远程并推送（替换成你的仓库地址）：

```powershell
git remote add origin https://gitee.com/你的用户名/jideshi_hibi_backend.git
# 或 GitHub: git remote add origin https://github.com/你的用户名/jideshi_hibi_backend.git
git branch -M main
git push -u origin main
```

若后端已经在主项目的 Git 里，你也可以用 `git subtree` 或单独复制 `backend_jideshi_hibi_app` 到另一个目录再 `git init` 推送到独立仓库，二选一即可。

### 3.2 服务器上首次克隆

SSH 登录服务器后执行（替换成你的仓库地址）：

```bash
cd ~
git clone https://gitee.com/你的用户名/jideshi_hibi_backend.git jideshi_hibi_backend
cd jideshi_hibi_backend
cp .env.example .env
vi .env   # 填写 MODEL_BASE_URL、MODEL_API_KEY、MODEL_ID、PORT
```

然后按《后端初步部署.md》构建并运行 Docker 即可。

### 3.3 日常更新流程

**本机改完代码后：**

```powershell
cd backend_jideshi_hibi_app
git add .
git commit -m "描述你的修改"
git push origin main
```

**服务器上拉取并重启容器：**

```bash
cd ~/jideshi_hibi_backend
git pull origin main
sudo docker rm -f jideshi_hibi_api
sudo docker build -t jideshi_hibi_api .
sudo docker run -d --name jideshi_hibi_api --restart unless-stopped -p 7861:7861 --env-file .env jideshi_hibi_api
```

若只改了 Python 代码、未改 Dockerfile，可只重启容器（不重新 build）：

```bash
cd ~/jideshi_hibi_backend
git pull origin main
sudo docker restart jideshi_hibi_api
```

注意：**镜像内容不会因 `git pull` 自动更新**，只有重新 `docker build` 后新镜像才包含最新代码；若你希望每次 `git pull` 后都重建镜像，就保留上面带 `docker build` 的那组命令。

---

## 四、方式 B 详细步骤（本地直推服务器）

### 4.1 服务器上建裸仓库和工作目录

SSH 登录服务器后执行：

```bash
cd ~
mkdir -p jideshi_hibi_backend.git
cd jideshi_hibi_backend.git
git init --bare
```

再建工作目录并首次检出（用裸仓库路径）：

```bash
cd ~
git clone ~/jideshi_hibi_backend.git jideshi_hibi_backend
cd jideshi_hibi_backend
```

此时工作目录是空的（因为裸仓库里还没有任何提交），需要等本机第一次 push 之后，再在服务器上执行一次 `git pull`（见下）。

### 4.2 本机后端初始化为 Git 并添加服务器远程

在**本机**执行（把 `你的公网IP` 换成服务器 IP，用户名若不同也改掉）：

```powershell
cd C:\ALI_Z14\.TSING_important\Tsingcoop_products\pd\jideshi_hibi\backend_jideshi_hibi_app
git init
git add .
git commit -m "init: 希比智能体后端"
git branch -M main
git remote add server admin@你的公网IP:~/jideshi_hibi_backend.git
git push -u server main
```

若本机 SSH 用的是密钥且已配置好，会直接推送；否则会提示输入服务器密码。

### 4.3 服务器上工作目录拉取代码并配置 .env

回到**服务器**：

```bash
cd ~/jideshi_hibi_backend
git pull origin main
# 若上面提示 no such ref，可试：git pull server main
cp .env.example .env
vi .env   # 填写大模型等配置
```

然后按《后端初步部署.md》在同一目录构建并运行 Docker。

### 4.4 日常更新流程

**本机：**

```powershell
cd backend_jideshi_hibi_app
git add .
git commit -m "描述修改"
git push server main
```

**服务器：**

```bash
cd ~/jideshi_hibi_backend
git pull server main
# 若改了 Dockerfile 或依赖，需要重新构建；否则只重启即可
sudo docker rm -f jideshi_hibi_api
sudo docker build -t jideshi_hibi_api .
sudo docker run -d --name jideshi_hibi_api --restart unless-stopped -p 7861:7861 --env-file .env jideshi_hibi_api
```

---

## 五、注意事项

1. **`.env` 不要提交**：已写在 `backend_jideshi_hibi_app/.gitignore` 里，服务器上单独保留 `.env`，`git pull` 不会覆盖它。
2. **首次在服务器 clone/拉取后**：务必 `cp .env.example .env` 并编辑，再启动 Docker。
3. **改代码后是否要重新 build**：只改 `api_only_app.py` 且不换依赖时，可以只 `docker restart jideshi_hibi_api`（当前镜像是之前 build 的）；改了 `requirements.txt` 或 `Dockerfile` 后，需要在服务器上重新 `docker build` 再 `docker run`。
4. **直推服务器（方式 B）**：需保证本机能 SSH 到服务器（22 端口、密钥或密码）。若服务器 IP 会变，可改用域名或记得更新 `remote` 地址。

按上述任选一种方式，即可用 Git 管理后端代码并在服务器上通过拉取更新，便于后续持续修改与部署。
