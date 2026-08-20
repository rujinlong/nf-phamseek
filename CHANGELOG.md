# 变更日志

## v0.1.0

第一个可用版本。对低生物量临床样本的 Oxford Nanopore reads 做 read 级(Tier 1)分析。

- 标准 Nextflow 入口:`nextflow run rujinlong/nf-phamseek`。
- 软件来源四选一,用 `-profile` 切:`apptainer`(默认)、`docker`、`pixi`、`nocontainer`。
- 依赖由 pixi 钉死(`pixi.lock`,含 linux-64 与 linux-aarch64)。容器镜像
  `jinlongru/nf-phamseek` 由 GitHub Actions 从同一份 lock 原生构建 amd64 与 arm64 两个架构
  并推上 Docker Hub,所以容器、pixi 与离线包三条路线拿到的是同一个解出来的环境。
- Samplesheet 校验:唯一性、可读性、非空、`.gz` 文件的 gzip 魔数、platform 与 sample-type 词表;
  FASTQ 相对路径相对 samplesheet 自身解析。
- 用 chopper 与 nanoq 做 QC,过滤前后各测一次。
- kraken2 以 `--confidence 0.02` 对每条 read 跑一遍。
- 两级 host depletion:先删 kraken2 子树,再用 minimap2 比对 CHM13v2。两级各自报告移除数量。
- bracken 可选,默认关闭 —— 它的模型假设读长固定,而 ONT 读长可变,这个假设从构造上就不成立;
  即使显式开启,数据库缺 k-mer 分布时也会带警告跳过。
- 每样本的 TSV/JSON,以及一份 run 级的自包含 HTML 报告,不依赖任何外部资源。
- 嵌合体诊断,明确标注为非特异的辅助信号。
- 数据库 manifest,把产出每份结果的数据库钉死记录。
- `--mode full`(assembly tier)直接带解释报错,而不是跑一半。
