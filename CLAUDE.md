# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 这是什么

`rujinlong/nf-phamseek` —— 一条 Nextflow DSL2 流程,在低生物量临床样本(血浆 / 脑脊液)的
Oxford Nanopore 宏基因组里检出噬菌体。**v0.1 只做 read 级(Tier 1)**:QC → kraken2 →
两级去宿主 → 报告。组装层(flye / geNomad / CheckV)**刻意不接线**,`--mode full` 直接带解释报错。

所有输出都带 `NOT FOR CLINICAL DIAGNOSIS`。改动报告措辞时不要弱化它。

## 语言约定(本仓库特有,别"统一")

| 位置 | 语言 |
|---|---|
| 源码、注释、日志与错误信息、`README.md`、`deploy/INSTALL.md`、`deploy/MAINTAINERS.md` | 英文 |
| `docs/`、`CHANGELOG.md`、`CITATIONS.md`、本文件 | 简体中文(专业名词保留英文) |

README 面向外部用户与 GitHub 访客,是英文的;`docs/` 面向本组与合作方,是中文的。
**不要把其中任何一侧"改成一致"**。

## 常用命令

```bash
# 只走接线:不碰数据库、不跑工具、不拉镜像(最快的回归测试)
nextflow run . -profile test,nocontainer -stub --outdir /tmp/phamseek_stub

# 极小的真实运行(需要一个真数据库)
nextflow run . -profile test,apptainer --db_dir <db> --outdir /tmp/phamseek_test

# 生产运行
nextflow run . -profile apptainer --input samplesheet.csv --db_dir <db> --outdir results

# 看某个 profile 最终解析成什么(调 profile 时的第一手段)
nextflow config . -profile test,docker

# 构建容器镜像(context 必须是仓库根)
docker buildx build -f docker/Dockerfile -t jinlongru/nf-phamseek:dev .

# lint(与 CI 的 lint job 等价)
shellcheck -S warning deploy/*.sh deploy/apptainer/*.sh
python3 -m compileall -q bin/
pixi lock --check --dry-run          # ⚠ 少了 --dry-run 会就地重写 pixi.lock
```

**只重跑某一个 process**:没有 `-entry` 这种东西可用(本流程只有一个 entry workflow)。做法是
`-resume` + 让那个 process 的输入或 script 变化;要强制只重算它,删掉它的 work 目录再 `-resume`。
`nextflow log <run_name> -f process,workdir` 能列出每个 task 的 work 目录。

**跑单个校验分支**:CI 里的负例测试就是普通的 stub 运行加一个参数,例如
`nextflow run . -profile test,nocontainer -stub --mode full`(应当失败并解释)。

## 软件来源 / profile

默认就是 **apptainer**,而且是在 `profiles{}` **之外**声明的(`nextflow.config` 顶层
`apptainer.enabled = true` + `process.container`)。这是刻意的:写成 `standard` profile 的话,
任何人只要传了 `-profile test` 就会把它顶掉,静默退回"用 PATH 上的随便什么工具"—— 而那正是
最不该静默发生的时刻,因为运行会成功,报告里记的却是宿主机的版本。

| profile | 软件来自 |
|---|---|
| 不给 / `apptainer` / `singularity` / `docker` / `podman` | `docker.io/jinlongru/nf-phamseek:v<version>` |
| `pixi` | 仓库内 `.pixi/` 的锁定环境,经 `beforeScript` + `pixi shell-hook` 激活 |
| `nocontainer` | 已在 `PATH` 上的工具 |

**Nextflow 至今没有原生 pixi 支持**:`process.pixi` 的 PR(nextflow-io/nextflow#6157)被关,
改推通用 `package` 指令(#6342),后者也在 2026-02 停摆关闭。已对 Nextflow 26.04 复核过,
不要再去找 `process.pixi`。用 `beforeScript` + `shell-hook` 而不是只往 `PATH` 塞 `bin/`,是因为
后者会漏掉 `LD_LIBRARY_PATH` 等 activation 变量。

**镜像里只有工具**,没有流程源码、没有数据库。版本号是 `nextflow.config` 顶部一个 `def
phamseek_version`,`manifest.version` 与镜像 tag 共用它 —— 别把两处拆开写。

## 架构:数据怎么流

```
samplesheet ──▶ PIPELINE_INITIALISATION ──▶ PHAMSEEK ──▶ PIPELINE_COMPLETION
                (校验 + 解析数据库)          (workflows/phamseek.nf)
```

`workflows/phamseek.nf` 是唯一的编排层,7 个 `modules/local/*.nf` 都是 local module
(没有 nf-core module,没有 `modules.json`)。

**顺序上唯一反直觉的一点:kraken2 跑在去宿主之前**。一遍分类同时产出分类谱和第一级去宿主,
不额外花代价。改顺序会让整条流程的资源模型失效。

**两级去宿主不是冗余设计,是两种不同的保证**:
- `HOST_SPLIT_L1` 复用已经算好的 kraken2 结果,删掉 `--host_taxid` 子树 —— **这是真删除**;
  kraken2 的 decoy 只改标签,不删任何东西。
- `HOST_DEPLETION_L2` 用 minimap2 把剩下的比对宿主参考,`-f 4` 只留完全没比上的。
  数据库不认识的人源 read 只有这一级能删掉。
- `--skip_host_removal` **只关第二级**,第一级永远跑。

四个容易被后人改坏的地方,每个都在源码里有注释,这里只给索引:

| 位置 | 不变量 |
|---|---|
| `workflows/phamseek.nf` 的 `ch_report_in` | `join(remainder: true)` 之后**断言 8 个字段**。若 Nextflow 改了补位语义而这里改成位置解构,level-2 stats 会静默滑进 bracken 槽位,报告拿错文件且哪里都不报错。 |
| `modules/local/phamseek_report.nf` | 两个 optional input 用**不同**占位符文件(`NO_BRACKEN` / `NO_L2STATS`)且 `stageAs` 到**不同目录**。共用一个 `NO_FILE` 是 launch 期硬报错。判断有无用 shell 的 `basename`,不是 Groovy 的 `.name`。 |
| `modules/local/phamseek_summary.nf` | 收到的 JSON 数少于 `ch_samplesheet.count()` 就**报错退出**。少一个样本的汇总表比没有汇总表更危险 —— 读的人分不清"没测"和"阴性"。 |
| `KRAKEN2_READS` / `DB_MANIFEST` | `maxForks 1`。kraken2 整库载入内存,并发两个就是双倍内存,而且并不更快(第二个样本直接命中 page cache)。 |

`DB_MANIFEST.out.manifest.first()` 里的 `.first()` 是把单值转成 value channel,好让报告
process **每个样本跑一次**而不是全程只跑一次。删掉它会静默只出一份报告。

## 配置分层

```
nextflow.config          params 默认值 · 版本 def · 容器默认值 · profiles · manifest · check_max()
  └─ conf/base.config    按 label 的资源(process_single/low/medium/high/kraken2)
  └─ conf/modules.config 只放字面量 ext.args;publishDir 在各 module 里(见 INV-NF-03)
  └─ conf/test.config    -profile test:测试 samplesheet + 放宽的阈值
deploy/offline.config    用 -c 叠加,关掉所有会联网的 Nextflow 功能
```

`nextflow_schema.json` 是 `--help` 与参数校验(nf-validation 1.1.3)的来源。**加 params
必须同时改 `nextflow.config` 与 `nextflow_schema.json`**,否则 `validateParameters()` 会把它
当成未知参数。

### 严格 config/script parser(Nextflow ≥ 26.04 的默认)

**⚠ 如果你的 shell 里有 `NXF_SYNTAX_PARSER=v1`,你看不到这一节说的任何错误。** 它强制回到
旧解析器,本地全绿而 CI 全红 —— 本仓库就是这样带着一个当前 Nextflow 根本解析不了的
`def check_max()` 通过了所有本地测试的。改配置或 `.nf` 之后,**至少跑一次
`env -u NXF_SYNTAX_PARSER nextflow run . -profile test,nocontainer -stub`**。

`nextflow.config` 里**不允许任何顶层 `def`**(变量或函数都不行),放在文件哪个位置都不行;
报错是误导性的 `Variable declarations cannot be mixed with config statements`,而函数还会先报
`Unexpected input: '('`。于是:

- 需要跨 config scope 共享的值**只能走 `params` 命名空间**(`pipeline_version`、
  `trace_timestamp` 就是这样,并在 schema 里标 `hidden`)。
- `check_max()` 已经删除,改用 **`process.resourceLimits`**(Nextflow 24.04+,这也是
  `nextflowVersion` floor 是 24.04 的原因)。它写成**闭包**而不是字面 map:字面 map 在
  `profiles{}` 之前就求值完了,`-profile test` 把 `params.max_cpus` 改成 4 也顶不上去
  —— 实测过,不是推测。
- pixi 的 shell-hook 字符串直接内联在 `pixi` profile 里。

`.nf` 脚本侧,严格 parser 另外禁掉了四样本仓库原本在用的东西:

| 不允许 | 改成 |
|---|---|
| `import org.yaml.snakeyaml.Yaml` | 内联全限定名 `new org.yaml.snakeyaml.Yaml()` |
| `new byte[2]` 之类数组构造 | 用 List(本仓库改成两次 `stream.read()`) |
| `def f = { ... }` 之后 `f(...)` 调用 | 声明成 module-level function |
| `publishDir "${params.outdir}/${meta.id}/..."` | `publishDir path: { "..." }`(闭包才惰性求值,否则 `No such variable: meta`) |

### 布尔参数不能在命令行上关掉

`--skip_bracken false` 会被 nf-validation 拒掉(`expected type: Boolean, found: String`)
—— 命令行传进来的是字符串。默认 `true` 的开关只能经 `-params-file` 关闭。CI 的对应负例
因此走 params 文件;直接用命令行形式会「通过」,但是因为错误的原因通过的。

### INV-NF-* 编号是外部索引

源码注释里的 `INV-NF-01/02/03/04/05/18` 指向
[~/vpipe/docs/INVARIANTS.md](file:///home/allen/vpipe/docs/INVARIANTS.md),**不在本仓库内**。
本仓库实际用到的几条:

- **01** `include` 只允许在文件顶层。
- **02** `output:` 用精确文件名不用 glob;**例外**是 merge 步骤的 `input:` 可以用收集 glob。
- **03** 配置的 `process{}` / `trace{}` / `report{}` / `timeline{}` / `dag{}` 块里不读 `params.X`。
  这就是 `publishDir` 写在 module 里而不是 `conf/modules.config` 里的原因。⚠ 它原文说的补救
  「改用文件级 `def`」在严格 parser 下**已经不可行**(见上节),本仓库改用 `params` 命名空间
  加惰性闭包。
- **04** `params{}` 块内不自引用其他 `params.Y`(构造期未完成)。数据库路径因此在
  `resolveDatabases()` 里解析,不在 params 里拼。
- **05** `check_max()` 只在 `conf/base.config` 调用。
- **18** 同一 process 的多个 optional input 不能共用一个占位符文件名。

## 交付层 `deploy/`

四条安装路线,共享同一份 `pixi.lock`:

- **A** `pixi install --frozen`(联网主机)
- **B** `deploy/pack_offline.sh` 出的 pixi-pack 离线包(气隙主机),自带一个 `bin/phamseek` 壳
  ——**那是安装包内的启动器,不是本仓库的入口**,仓库里已经没有这个文件了。
- **C** `deploy/apptainer/build_sif.sh` + `phamseek.def`,把 B 的 payload 做成自包含 `.sif`
  (含流程源码、Nextflow、预取的插件),`apptainer run` 直接跑。
- **D** 本次新增的发布镜像,由 CI 构建;工具在镜像里,流程和 Nextflow 在宿主机上。

C 与 D 都是 Apptainer 镜像但用法完全不同,改动其中一个时别顺手"统一"另一个。

`deploy/preflight.sh` 是只读体检脚本,给出 PASS/WARN/FAIL 并推荐路线;它接受**嵌套与扁平
两种** kraken2 数据库布局,`descendIntoSingleDatabase()` 必须与它保持一致 —— 曾经不一致过,
结果是 preflight 全绿、流程却报 `hash.k2d is missing`。

## CI

- `.github/workflows/ci.yml` —— stub 运行(Nextflow 23.10.0 与最新版两档)+ 负例校验 + shellcheck。
- `.github/workflows/docker.yml` —— 先验 `pixi lock --check --dry-run`,再在 `ubuntu-24.04`
  与 `ubuntu-24.04-arm` 上**各自原生构建**,按 digest 推送,最后单独一个 job 合成多架构
  manifest。不用 QEMU:模拟执行 conda 包的 post-link 脚本会把十几分钟变成几小时。
  需要仓库 secrets `DOCKER_USER` / `DOCKER_PASSWORD`。
  推 `main` 出 `:edge`,推 `v*` tag 出 `:vX.Y.Z` 并移动 `:latest`。

## 已知陷阱

- **`native` 是 Groovy 保留字**,不能当 profile 名。用了它,报错会是 `Unexpected input: '{'`
  并指向几十行之前的 `profiles {` —— 一个指向无辜代码的语法错误。本仓库用 `nocontainer`。
- **`KRAKEN2_DB_PATH`** 常年躺在生信人的 shell profile 里,会被 task 继承,并且优先于相对
  `--db` 路径。每个调 kraken2 的 module 都先 `unset` 它再传绝对路径,别删掉那行。
- **`.mmi` 索引里存着建索引时的 preset**,minimap2 加载时会静默采用索引里的参数而不是命令行
  给的。宿主索引必须用 `map-ont` 建。
- **判断数据库有没有 decoy,必须查数据库自身的 taxonomy**(`kraken2-inspect`),绝不能看某个
  样本的 kraken2 report —— report 只列拿到 reads 的 taxa,于是一个带 human decoy 的库在分析
  一个没有人源 read 的样本时 report 里根本没有 9606 节点。照 report 反推,恰好在去宿主最成功
  的样本上判反。
- **bracken 默认关闭**,因为它的模型假设读长固定而 ONT 不满足。打开时必须给
  `--bracken_read_length`,没有安全默认值,给错只会产出看着合理的错数字。
- **`docs/learning-hub/` 不进 git**(`.gitignore` 里),它由 `scripts/render_hub.py` 生成,
  内嵌本机的 `file://` 绝对路径。别把它加回来。
- **改了计算相关代码后不要只看退出码**:stub 运行只验接线,不验数值。
