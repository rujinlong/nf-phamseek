# 使用说明

## 安装

```bash
bin/phamseek install     # 解析锁定的环境;不需要 root
bin/phamseek doctor      # 确认每个工具都在,并报告插件缓存状态
```

`pixi` 是单个静态二进制。它把环境装进本仓库内的 `.pixi/`,不修改也不干扰已有的 conda 安装。
没有网络的主机见 [../deploy/INSTALL.md](../deploy/INSTALL.md)。

## 运行

```bash
bin/phamseek run \
    --input samplesheet.csv \
    --db_dir /path/to/phamseek_db \
    --db_label uhgv_inphared_decoy_2026-04 \
    --outdir results
```

加 `--resume` 可以从中断处继续,而不是从头重跑。加 `-stub` 可以走一遍接线而不真正执行任何工具。

`bin/phamseek run --help` 会打印每个参数的默认值和帮助文本。

## Samplesheet

带表头行的 CSV。

| 列 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `sample_id` | 是 | —— | 唯一,不含空白字符。会成为输出目录名。 |
| `fastq` | 是 | —— | 绝对路径,或相对于 samplesheet 自身目录。`.fastq`/`.fq`,可带 `.gz`。 |
| `platform` | 否 | `ont` | v0.1 只实现了 `ont`。 |
| `sample_type` | 否 | `sample` | `sample`、`ntc`、`positive_control` 之一。 |

```csv
sample_id,fastq,platform,sample_type
plasma_01,reads/plasma_01.fastq.gz,ont,sample
csf_02,/data/run17/csf_02.fastq.gz,ont,sample
ntc_01,reads/ntc_01.fastq.gz,ont,ntc
```

samplesheet 的每一行在被送进流程之前都会先校验。每个文件都会检查是否存在、可读、非零字节、
扩展名是否合理,`.gz` 文件还会读头两个字节比对 gzip magic number —— 于是扩展名错标、或开头
就已损坏的文件会立刻失败,而不是跑了几步之后才暴露。(这个检查只看文件头,尾部被截断的
gzip 要等工具真的读到那里才会失败。)

### 对照

把 no-template control 标成 `ntc`。phamseek 会给同时出现在对照里的每个 taxon 打上 `also_in_ntc`
标记,把其中已经过线的行降级为 `candidate_contamination_suspected`(本来就是 `below_threshold`
的行保持不变),并报告这个对照实际具备多少检出能力。它绝不扣减对照计数。

一个非宿主 reads 很少甚至没有的对照,不足以为任何 taxon 洗脱污染嫌疑,报告里会写明这一点。

## 数据库

```
<db_dir>/kraken2/    hash.k2d、opts.k2d、taxo.k2d  (+ 可选的 database<N>mers.kmer_distrib)
<db_dir>/host/       chm13v2.mmi                   (或任意 *.mmi / FASTA)
```

两者可以分别用 `--kraken2_db` 和 `--host_index` 单独覆盖。

构建宿主索引 —— preset 必须与 mapping 时用的一致:

```bash
minimap2 -x map-ont -I 8G -t 16 -d <db_dir>/host/chm13v2.mmi chm13v2.fna.gz
```

bracken 默认关闭(`--skip_bracken` 默认为 `true`),因为它的模型假定所有 read 长度一致,而
ONT 从构造上就违反这个假定。kraken2 的 read 计数和由此得到的 RPM 无论如何都会报告,不依赖
bracken。要打开它,必须同时用 `--bracken_read_length` 给出本次运行的 read 长度中位数
(nanoq 会报),否则流程立刻报错中止 —— 不同 ONT 运行之间不存在站得住脚的通用默认值,而一个
取错的 `-r` 只会产出表面合理、实则无效的数字。

即便打开了 bracken,它也需要 kraken2 数据库里有 `database<N>mers.kmer_distrib` 文件。这些文件
缺失时 phamseek 会警告、跳过 bracken,并把这件事记进 `summary/database_manifest.tsv`。

## 关键参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `--mode` | `fast` | `full`(组装层)在 v0.1 未实现,会报错并解释原因。 |
| `--kraken2_confidence` | `0.02` | 不是 kraken2 自己的默认值 0。取 0 时单个 k-mer 命中就足以判定一个 taxon,这让 61% 的人源 contig 和 38% 的干净细菌 contig 看起来像噬菌体。继续调高也去不掉质粒/MGE 假阳性。 |
| `--db_has_decoy` | `auto` | `auto` 读数据库自身的 taxonomy,分别报告人源、细菌、质粒三类 decoy。声明 `false` 却检出任一类 decoy、或声明 `true` 却三类一个都没检出时,报告里会给出明确的不一致警告。三个取值都可直接在命令行上给。 |
| `--min_reads` | `10` | 报告下限。低于它的行仍然打印,标为 `below_threshold`。 |
| `--min_rpm` | `1.0` | 每百万**非宿主** reads。 |
| `--chopper_min_quality` | `10` | 每条 read 的平均 Phred。 |
| `--chopper_min_length` | `200` | 最短 read 长度。 |
| `--skip_bracken` | `true` | bracken 默认关闭,原因见上。设为 `false` 打开时必须同时给 `--bracken_read_length`。 |
| `--bracken_read_length` | 无默认 | 只在 bracken 打开时使用,且此时必填。填本次运行的 read 长度中位数。 |
| `--skip_host_removal` | 关 | 只跳过第二级。见下面的警告。 |
| `--l2_input` | `all_nonhuman` | `nonhuman_nonviral` 会让病毒 reads 绕过比对器:略快,但一条被误判为病毒的人源 read 就此逃过去宿主。 |
| `--max_memory` | `128.GB` | 必须大于 kraken2 数据库体积。 |
| `--max_cpus` | `16` | |

### 关于 `--db_has_decoy`

三态参数,取值 `auto`(默认)、`true`、`false`,三个都能直接在命令行上给。

绝大多数情况保持默认 `auto` 即可 —— 它用 `kraken2-inspect` 读数据库自身的 taxonomy,
比人工声明更可靠,而且探测不到的类别会报 `unknown` 并打 flag,不会替你猜。
只有当你的库用了非常规的 taxid 组织方式、`auto` 报不出来时,才需要显式声明。

### `--skip_host_removal`

它只关掉**比对**这一级;kraken2 的第一级永远会跑。此时去宿主完全依赖数据库恰好认得出什么,
而且根本不会发布任何无宿主 FASTQ。这样一次运行的输出不得离开本机构。这个选项是给开发和
排查数据库覆盖度用的,不是给生产用的。

## 资源

kraken2 会把整个数据库载入内存,所以 phamseek 同一时刻最多跑一个 kraken2 任务
(`maxForks 1`)。并行跑它们会成倍放大内存需求,而且并不会更快:后续样本直接用 page cache,
不必重新从磁盘读库;何况分类本身也不是瓶颈。

把 `--max_memory` 提到数据库体积之上。11 GB 的库峰值约 12 GB。

## 离线运行

除了两步,其余全部离线:

1. `pixi install` 第一次会下载软件包。
2. Nextflow 第一次运行时会把 `nf-validation` 插件下载到 `$NXF_HOME/plugins`。

`bin/phamseek doctor` 会报告插件是否已缓存。一旦缓存好,`bin/phamseek` 会自动设置
`NXF_OFFLINE=true`。在联网机器上预先准备这两样东西的做法见
[../deploy/INSTALL.md](../deploy/INSTALL.md)。

## 排错

| 现象 | 原因 |
|---|---|
| `unable to find kraken2 in $KRAKEN2_DB_PATH` | 从你的 shell 配置继承来的 `KRAKEN2_DB_PATH`。phamseek 会 unset 它并传绝对路径;你看到这条,说明是在流程之外调用了 kraken2。 |
| `kraken2 database ... is incomplete` | 目录里缺 `hash.k2d`、`opts.k2d` 或 `taxo.k2d`。 |
| `No host reference (*.mmi or FASTA) found` | 去构建索引,或者传 `--skip_host_removal` 并接受上面写明的后果。 |
| `--bracken_read_length is required when bracken is enabled` | 打开了 bracken(`--skip_bracken false`)却没给读长。用 nanoq 报的中位 read 长度填上,或者让 bracken 保持关闭。 |
| `expected 8 fields from the report join` | Nextflow 版本变动改变了 `join(remainder: true)` 的补位语义。流程会停下,而不是用可能错位的文件去拼报告。 |
| `expected reports for N sample(s) but found M` | 有样本在分类和出报告之间掉了;汇总步骤拒绝产出一次残缺的运行。 |
| `read order mismatch at record N` | kraken2 不再保持输入顺序,这会让流式的宿主拆分变得不安全。流程停止。 |
