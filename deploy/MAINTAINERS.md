# 构建与交付 phamseek

这份文档给我们自己,不给合作方。发给他们的是 [INSTALL.md](INSTALL.md)(英文,他们照着一步步操作的那份)。

---

## 这里有什么

| 文件 | 在哪跑 | 用途 |
|---|---|---|
| [preflight.sh](preflight.sh) | 目标机 | 只读健康检查;打印报告、写出 `preflight.json`,退出码 0/1/2(参数错误是 3) |
| [pack_offline.sh](pack_offline.sh) | 我们的机器,联网 | 构建路线 B 的离线包 |
| [apptainer/phamseek.def](apptainer/phamseek.def) | 我们的机器 | 容器定义;直接用路线 B 的 payload |
| [apptainer/build_sif.sh](apptainer/build_sif.sh) | 我们的机器 | 准备输入并执行 `apptainer build` |
| [db_package.sh](db_package.sh) | 我们的机器 | 给数据库分卷、算校验和、记录功能指纹 |
| [db_verify.sh](db_verify.sh) | 目标机 | 四道 gate 验证;随每个数据库包一起发出 |
| [offline.config](offline.config) | 目标机 | Nextflow 加固配置,用 `-c` 叠加 |
| [assets/smoke_contigs.fna](assets/smoke_contigs.fna) | 两边 | gate 4 用的那份固定输入,12 条序列 |

---

## 唯一不能破的一条

`pixi.lock` 是「交付哪些软件」的唯一事实来源。三条路线全部由它推导,不依赖任何别的东西:

- 路线 A 用 `pixi install --frozen` 直接解析它。
- 路线 B 用 `pixi-pack` 打包完全相同的那批 locked 包。
- 路线 C **直接用路线 B 的 payload**。容器从不自己求解环境 —— 会重新求解的容器让 lock 文件形同虚设。

一旦发现自己在跑不带 `--frozen` 的 `pixi install`,或往 Apptainer 的 `%post` 里加了 `conda install`,
立刻停手:三条路线已经悄悄分叉了。

---

## 架构策略

开发与验证在 linux-aarch64(DGX Spark)上进行。合作方的 workstation 是 linux-64。`pixi.lock` 同时
收了这两个平台,两边都能解析出环境。

**我们不做交叉构建。** 不用 qemu,不做跨架构 CI。`pixi-pack --create-executable` 会嵌入一个必须与
目标平台匹配的 `pixi-unpack` 二进制,而 Apptainer 只支持本机构建。每个架构在它自己的机器上构建。
[build_sif.sh](apptainer/build_sif.sh) 碰到不匹配的 `--platform` 会直接拒绝,而不是产出一个坏镜像。

---

## 部署当天:构建 linux-64 产物

以下命令在**任何一台联网的 x86_64 Linux 机器**上跑。这套流程还没有实际执行过 —— 执行过的是 aarch64
版本,唯一的区别就是平台参数。

```bash
# --- 0. 装工具(每台机器一次)---------------------------------------------
curl -fsSL https://pixi.sh/install.sh | bash
export PATH="$HOME/.pixi/bin:$PATH"
pixi global install pixi-pack

# --- 1. 取仓库 --------------------------------------------------------------
git clone https://github.com/rujinlong/nf-phamseek.git
cd nf-phamseek

# --- 2. 按 lock 文件把环境装出来,绝不重新求解 ------------------------------
#     必需,因为 pack_offline.sh 要用这个 nextflow 预取插件。
pixi install --frozen

# --- 3. 路线 B:离线包 ------------------------------------------------------
./deploy/pack_offline.sh --platform linux-64
#     -> dist/phamseek-offline-v0.2.0-linux-64/
#     -> dist/phamseek-offline-v0.2.0-linux-64.tar.zst        (~1.2 GB)
#        机器上没有 zstd 时回退成 .tar.gz
#     -> dist/phamseek-offline-v0.2.0-linux-64.tar.zst.sha256

# --- 4. 路线 C:容器 --------------------------------------------------------
./deploy/apptainer/build_sif.sh --platform linux-64
#     -> ~/singularity/phamseek-0.2.0-x86_64.img              (~1.5 GB)
#     -> ~/singularity/phamseek-0.2.0-x86_64.img.sha256

# --- 5. 证明离线包在无网络下能装上 ------------------------------------------
#     发货前在 x86_64 上重做一遍气隙测试。不要跳过:
#     aarch64 上那次缺 CA store 的失败就是它抓出来的。
apptainer build /tmp/deb12.sif docker://debian:12-slim
cp -a dist/phamseek-offline-v0.2.0-linux-64 /tmp/ag/bundle
apptainer exec --net --network=none --cleanenv \
  -B /tmp/ag:/tmp/ag \
  -B /etc/ssl/certs:/etc/ssl/certs:ro \
  /tmp/deb12.sif \
  bash -c 'export HOME=/tmp/ag/home; mkdir -p $HOME
           bash /tmp/ag/bundle/install.sh /tmp/ag/phamseek
           source /tmp/ag/phamseek/activate.sh
           nextflow -version && kraken2 --version'

# --- 6. 验证容器 ------------------------------------------------------------
apptainer exec --cleanenv ~/singularity/phamseek-0.2.0-x86_64.img kraken2 --version
apptainer exec --cleanenv \
  -B /path/to/databases:/db:ro \
  ~/singularity/phamseek-0.2.0-x86_64.img \
  kraken2 --db /db/inphared_7Apr2026 --confidence 0.02 \
          --output /dev/null --report /dev/stdout \
          /opt/phamseek/pipeline/deploy/assets/smoke_contigs.fna
```

`--net --network=none` 是真气隙:只剩 loopback,DNS 解析失败,而且不需要 root。非特权的
`unshare -rn` 在我们的机器上**用不了** —— AppArmor 的
`kernel.apparmor_restrict_unprivileged_userns=1` 会拦下它。

---

## 打包数据库

```bash
# 小库,用来给 pipeline 本身做冒烟测试
./deploy/db_package.sh \
    --db-dir /home/allen/data2/db/kraken2/inphared_7Apr2026 \
    --name inphared_7Apr2026 \
    --out /mnt/nas26/outbox --volume-size 2G \
    --source "INPHARED 7 Apr 2026 cultured phage genomes + ICTV taxonomy"

# 生产库
./deploy/db_package.sh \
    --db-dir /home/allen/data2/db/kraken2/inphared_decoy \
    --name inphared_decoy \
    --out /mnt/nas26/outbox --volume-size 2G --threads 16 \
    --source "INPHARED 7 Apr 2026 + bacteria/plasmid/human decoy"
#   level 自动选择:7.7 GiB -> zstd -3
```

几条要紧的:

- **`--level` 现在按数据库大小自动选**,正常情况下不要手动指定:大于 2 GiB 用 3,否则用 19。kraken2 的
  hash table 几乎不可压缩,7.7 GB 的库用 level 19 要多烧约一小时 CPU,却几乎省不下空间。选定的 level
  和理由会打印在每次运行的开头。
- **收件方是机构时一律加 `--sign`。** 校验和证明完整性,只有签名能证明它出自谁手,而医院信息安全部门要的是
  后者。公钥走另一条渠道发。**尚未启用 —— 见「已知缺口」。**
- **`--no-host-metadata`** 从 manifest 里去掉我们的主机名与源目录绝对路径,用于收件方把内部路径视为
  信息泄露的场合。
- **只打包已封存的构建,绝不打包还在变动的目录。** manifest 和 tar 是对同一批数据的两趟独立扫描;
  数据库若能在两趟之间发生变化,包本身就是自相矛盾的,接收侧的 gate 3 会莫名其妙失败。
- 压缩侧和解压侧都用 `--long=31`。解压侧不加,zstd 会**拒绝**大窗口帧并报
  "Frame requires too much memory for decoding" —— 这是解码器本身的限制,但报错看起来和数据损坏一模一样。

发货前一律先走一遍接收侧路径,验证自己的包:

```bash
./deploy/db_verify.sh --package-dir /mnt/nas26/outbox/inphared_decoy_YYYYMMDD \
                      --dest /tmp/verify-scratch
```

---

## 目标机上预期的数据库布局

`--db_dir` 是一个根目录,每个数据库占一个子目录。**这个布局是固定的:**

```
<db_dir>/
├── kraken2/<db_name>/   hash.k2d, opts.k2d, taxo.k2d   必需(推荐 inphared_decoy)
├── host/                minimap2 CHM13v2 .mmi 索引     必需
├── genomad_db/          v0.2 预留 —— 缺失是正常的
└── checkv/              v0.2 预留 —— 缺失是正常的
```

[preflight.sh](preflight.sh) 能识别三种布局:上面这个根目录、扁平的 `<db_dir>/kraken2/`、以及直接
指向一个 kraken2 数据库目录。它会报告自己识别出的是哪一种。查找用 `find -L`,这样即使数据库目录是
指向另一个卷的符号链接也能遍历进去 —— 我们自己的数据库就是这么放的,不加 `-L` 时 find 会静默地
什么都找不到。

这几档严重级别是刻意定的:**缺 `host/` 报 WARN**(host depletion 默认开启,但 `--skip_host_removal true`
是一条真实可用的退路),而**缺 `genomad_db/` 与 `checkv/` 报 INFO** —— 只有 Tier 1,它们不存在
才是预期状态,报 warning 会让合作方去找根本还用不上的数据库。

---

## 脚本里写死的实测默认值

部署层有两个数字,都来自实测而不是惯例。任何一个要改,下表列出的所有位置都得一起改。

| 值 | 出现在哪 | 依据 |
|---|---|---|
| `--confidence 0.02` | [db_package.sh](db_package.sh) 与 [db_verify.sh](db_verify.sh) 的 gate 4;[INSTALL.md](INSTALL.md) 里有说明 | 短读惯用的 0.10 在 ONT 上要付出灵敏度代价:read identity 95% 时损失 15 个百分点,87% 时损失 29 个。kraken2 自己的默认值 0 则单个 k-mer 命中就下 taxon 判定。ONT pilot 数据:[p0126-kraken2phage/results/ont_pilot/](file:///home/allen/github/rujinlong/p0126-kraken2phage/results/ont_pilot/) |
| `PHAMSEEK_PROD_DB_GB=8` | [preflight.sh](preflight.sh),仅在没给 `--db-dir` 时使用 | `uhgv_heldout_decoy`(磁盘 11 GB)实测峰值 RSS 10.8 GB,即常驻内存与库大小大致 1:1。7.7 GB 加余量取整到 8。给了 `--db-dir` 时 preflight 直接测真实数据库,不用这个值。 |

gate 4 逐条精确比对 taxid,所以 confidence 值已经固化进每一份 `SMOKE_EXPECTED.tsv`。改动它会让所有
已经发出的数据库包失效 —— 重新验证时它们会在 gate 4 失败。改了就得重新打包。

## 新增 Nextflow 插件

[pack_offline.sh](pack_offline.sh) 靠 grep [nextflow.config](../nextflow.config) 里的
`id 'name@version'` 发现插件,并把每个都预取进离线包的 `NXF_HOME`。两条规则:

- **必须钉版本。** 不带版本的 `id 'nf-schema'` 匹配不上那条 grep,不会被预取,到目标机上以下载
  失败告终。
- **改动插件列表后重跑 [pack_offline.sh](pack_offline.sh)。** 离线包带的是构建当时存在的那批插件。

框架 jar 本身不需要预取:bioconda 的 `nextflow` 包在 `$PREFIX/share/nextflow/dist` 下自带
`nextflow-<ver>-one.jar`,启动器不会去下载。已用干净的 `NXF_HOME` 验证过 —— 不会生成 `framework/`
或 `capsule/` 目录。

---

## 已知缺口

记录下来而不是修掉,免得下一个人重新踩一遍。

- **`--db_dir` 的解析比上面那张布局图浅一层,preflight 会放行而 pipeline 会失败。**
  [preflight.sh](preflight.sh) 会用 `find -L` 钻进 `<db_dir>/kraken2/<db_name>/` 找到数据库并报 PASS,
  但 pipeline 把 `--db_dir` 直接解析成 `<db_dir>/kraken2` 并就地检查 `hash.k2d`
  ([utils_phamseek_pipeline/main.nf](../subworkflows/local/utils_phamseek_pipeline/main.nf) 里的
  `resolveDatabases()` 与 `resolveKraken2Db()`),不会再向下一层。按 [INSTALL.md](INSTALL.md) 的布局
  装好后再传 `--db_dir`,会报 "kraken2 database ... is incomplete: hash.k2d is missing"。当前可靠的
  绕法是显式传
  `--kraken2_db <db_dir>/kraken2/<db_name>`。真正的修法二选一:让 pipeline 也做 preflight 那套单一
  子目录解析,或把布局收敛成 `.k2d` 直接放在 `kraken2/` 下 —— 后者要同步改 [INSTALL.md](INSTALL.md)
  与已发出的数据库包说明。
- **数据库包还没有签名。** `--sign <key-id>` 已实现,会对 `MANIFEST.tsv` 与 `SHA256SUMS.volumes` 产出
  detached armored 签名,并导出一份公钥,但还没有指定密钥。签名宣示的是署名责任,所以用哪把密钥、
  以什么身份发布,由用户决定。**必须在首次正式发布前选定密钥** —— 医院信息安全要的是真实性,而校验和只
  提供完整性。在那之前,[db_package.sh](db_package.sh) 每次运行都会打印一条警告。
- **preflight 里没有端到端的 pipeline 冒烟测试。** preflight 验证的是机器,不是这次安装本身。一个
  `--deep` 模式 —— 强制断网、用极小的 fixture 跑一遍交付的 pipeline —— 能把「这台机器看着没问题」变成
  「这套安装确实在这里跑通过」。这是剩下的改进里价值最高的一项。
- **geNomad 与 CheckV 数据库只检查存在与否。** 工具与数据库的版本兼容性没有验证。正确的修法是照搬
  kraken2 那一套:打包时记录每个工具在固定 fixture 上的输出,接收时重新核对。
- **打包出的环境里有一个失效的符号链接**(`tensorflow/libtensorflow.so.2`)。它在普通
  `pixi install` 出来的环境里一模一样地存在,所以来自上游 conda 包,不是打包造成的。依赖 tensorflow 的
  geNomad 运行正常。不要加「不允许断链」的检查:那会把一个能正常工作的安装判成失败。
