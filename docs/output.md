# 输出

```
<outdir>/
  summary/
    phamseek_report.html        先读这个
    phamseek_summary.tsv        每个样本、每个 taxon 各一行
    database_manifest.tsv       是哪个数据库产出了这批结果
  <sample_id>/
    qc/                         nanoq 统计、两级去宿主、read 诊断
    kraken2/                    kraken2 report(有 bracken 时也在这里)
    clean_reads/                去宿主后的 FASTQ
    report/                     单样本 TSV 和 JSON
  pipeline_info/                执行 trace、timeline、软件版本
```

`clean_reads/` **只有**在第二级去宿主真的跑过时才会写出。用了 `--skip_host_removal` 就完全
不产出无宿主 FASTQ,因为这样一次运行的输出不可对外共享。

---

## 怎么读一条判定

每一行都是一个**候选**。v0.1 没有组装、没有 geNomad、没有 CheckV,因此没有任何结果经过独立
方法确认。判定等级只说明这一行离报告下限有多远 —— 仅此而已。

| 判定 | 含义 |
|---|---|
| `candidate_passes_abundance_screen` | reads ≥ `--min_reads` 且 RPM ≥ `--min_rpm`。它通过了一次筛查;这不是诊断,也不是关于生物学丰度的陈述。 |
| `candidate_low_abundance` | reads ≥ `--min_reads`,但 RPM 低于 `--min_rpm`。 |
| `candidate_contamination_suspected` | 同一次运行的 no-template control 里也有它。无法排除污染。 |
| `below_threshold` | 低于 `--min_reads`。仍然打印 —— 不会有东西被悄悄丢掉。 |
| `not_detected` | 病毒子树里一个拿到 reads 的 taxon 都没有,整个样本只输出这一行。这**不是**「不存在」的证据。 |

有 taxon 但全部低于 `--min_reads` 时,输出的是若干 `below_threshold` 行,不会再出现
`not_detected`。

`candidate_contamination_suspected` 只在运行级汇总里产生,因为只有那一步才同时看得到样本和
对照;而且只有本来已经过线的行才降级,`below_threshold` 行保持原判定,只加 `also_in_ntc`
标记。单样本 TSV 保留该行原本的丰度判定。

## 列

单样本 TSV 与运行级汇总 TSV 的列不完全相同:前者带 leaf 状态和 bracken 结果,后者带对照
比较。下表的「出现于」指明每一列在哪份文件里。

| 列 | 出现于 | 说明 |
|---|---|---|
| `reads` | 两者 | **直接**分配到该节点的 reads,没有重复计数。各行相加等于病毒 clade 总数减去直接停在 Viruses 根节点(10239)上的那部分 —— 根节点本身不出行。 |
| `reads_clade` | 单样本 | 该节点整个 clade 的 reads,即包含所有后代。 |
| `rank`、`is_leaf` | `rank` 两者;`is_leaf` 单样本 | `is_leaf=FALSE` 表示 kraken2 的 LCA 停在了这个数据库所能提供的最具体节点之上。rank 代码在不同数据库之间会变,leaf 状态不会,所以筛选用的是后者。 |
| `rpm_nonhost` | 两者 | 每百万**非宿主** reads 的 reads 数。 |
| `pct_nonhost` | 两者 | 同一比值的百分数形式。 |
| `nonhost_denominator` | 两者 | 那个 RPM 背后的分母,等于送进 kraken2 的全部 reads 减去 kraken2 判为 *Homo sapiens* clade 的 reads —— 也就是第一级之后的数量,**不扣**第二级比对再删掉的部分。**必须和 RPM 一起读。** 血浆和脑脊液里非宿主占比很小,RPM 因而虚高:700 条非宿主 reads 里的 191 条就是 272,857 RPM,而这对绝对载量什么也没说。 |
| `ntc_enrichment` | 汇总 | 样本 RPM 与对照 RPM 之比,计算前两者各加 1 RPM 偏移。只有该 taxon 确实出现在对照里时才报,否则为 `NA`。它是背景信息,永远不是判定阈值。 |
| `bracken_est_reads`、`bracken_fraction` | 单样本 | bracken 重估的丰度。bracken 默认关闭,此时两列为空。 |
| `evidence` | 两者 | v0.1 恒为 `read_only`。 |
| `flags` | 两者 | 见下。 |
| `not_for_clinical_diagnosis` | 两者 | 恒为 `TRUE`。 |

## 标记(flags)

| 标记 | 含义 |
|---|---|
| `plasmid_mge_ambiguity_risk` | 数据库没有质粒 decoy 序列。预期约 37% 的质粒来源序列会被判成噬菌体。 |
| `plasmid_decoy_unverified` | 无法确定数据库的质粒 decoy 内容,因此假阳性率未知:可能低到 ≤0.4%,也可能高到约 37%。这和「知道没有」不是一回事,和「安全」也不是一回事。 |
| `lca_stopped_above_most_specific_rank` | reads 停在了内部节点上。近缘物种之间共享的序列常见如此,嵌合 read 也会造成这种情况。 |
| `also_in_ntc` | 该 taxon 出现在本次运行的 no-template control 里。只在运行级汇总里产生。 |
| `negative_control_sample` | 这一行属于一个对照样本。 |
| `none` | 这一行没有任何标记。该列不留空。 |
| `no_taxon_passed_reporting_thresholds` | 只出现在 `not_detected` 那一行上。 |

## 去宿主

每个样本两个文件,一级一个,文件名都带样本前缀。

`<sample_id>.host_removal_l1.tsv` —— kraken2 那一级。`host_taxid_in_db=FALSE` 表示数据库里没有
人源 decoy 序列,所以这一级什么也没去掉,全部落到第二级。这是支持的用法,只是更慢。

`<sample_id>.host_removal_l2.tsv` —— minimap2 那一级。凡是能比对上宿主参考的 read 一律删除,
只有完全比不上的才留下。minimap2 以 `--secondary=no` 运行,supplementary 比对同样使这条 read
出局,所以只要一条 read 的某个片段比对上,整条 read 就被删掉。

第一级去掉一大批之后,第二级去除数接近零,这是预期中的健康结果:比对器没找到分类器漏掉的
东西。

### 已知限度

两级都不能证明人源序列残留为零。能同时逃过两级的序列有:短到两种方法都无法起始(seed)的
片段;错误率高、低复杂度或来自重复区的 reads;与 CHM13 差异过大或在 CHM13 里根本没有的人源
序列(群体特异插入、结构变异、alternate haplotype);以及人源片段小到让非人源部分主导了分类
和比对的嵌合 read。把去除数当作「做了多少工作」的证据,不要当作「不存在」的证明。

## 嵌合诊断

**这些是非特异的辅助信号。它们不是嵌合率。**

在模拟的跨域嵌合上,把真实嵌合率提到 30%,落到 root 的比例也只从 0.16% 动到 0.70%。kraken2
会把嵌合 read 判给贡献 k-mer 更多的那一段,而不是把判定抬到 root,所以 root 比例读不出嵌合
read 的数量。

| 指标 | 它指示什么 |
|---|---|
| `pct_at_root` | kraken2 只能放到 root 的 reads。 |
| `pct_at_internal_node` | 被放在可得的最具体节点之上的 reads。 |
| `pct_multitaxon_kmers` | k-mer 来自两个或更多 taxa 的 reads。 |
| `lift_distance_hist` | 每条 read 落在最具体节点之上几层。`0` = 落在叶子上。比单看 root 比例信息量更大。 |
| `dominant_kmer_fraction_hist` | 每条 read 内部 k-mer 支持度的分布。高错误率 reads 上会整体左移。 |

跨域嵌合在**两个方向**上都造成危害:同一次模拟里,34.7% 的噬菌体+人源嵌合被判为病毒
(假阳性),而 62.9% 被判为人源,把真实的噬菌体序列埋进了宿主那一堆。近缘噬菌体之间的嵌合
对监控更不利,因为它们会**抬高**表观病毒占比(92.7% 判为病毒),因而对任何「总体病毒百分比」
式的检查都是隐形的。

ONT 假象倒不构成假阳性来源:模拟的垃圾 read 和随机 read 有 95.9% 未分类,只有 0.27% 被判为
病毒。不需要为它们加任何过滤。

## 参考库覆盖度

单样本 JSON 里的 `pct_unclassified` 可间接反映数据库对该样本的覆盖程度。该值偏高时,限制
因素可能在数据库而不在样本。

它只是代理指标。直接的测量方式 —— geNomad 判为病毒的 contig 中被 kraken2 留作未分类的比例 ——
需要组装层,而 v0.1 没有实现。

## 数据库清单

`summary/database_manifest.tsv` 钉死了具体是哪个数据库:路径、标签、confidence、kraken2 版本、
各 `.k2d` 文件的大小与 mtime、其中两个小文件的校验和,以及有哪些 bracken k-mer 分布可用。
任何结果都必须结合产出它的那个数据库来解释。

它同时按类别记录 decoy 内容:

| 键 | 含义 |
|---|---|
| `db_has_decoy_declared` | 操作者声明的值:`auto`、`true` 或 `false`。 |
| `decoy_detection_method` | `kraken2-inspect`、`shipped-inspect.txt` 或 `unavailable`。 |
| `decoy_human`、`decoy_bacterial`、`decoy_plasmid` | `detected`、`absent` 或 `unknown`。 |
| `decoy_*_pct` | 检出时,该类占数据库 minimizer 的比例。 |

分成三类而不是一个开关,是因为它们的可知程度不一样:人和细菌有稳定的 taxid,而「质粒」没有
统一节点,只能靠 taxid 45202 或名字以 `plasmid` 开头的节点来匹配。只有**质粒**这一类决定假
阳性提示的措辞,因为 37.4% → ≤0.4% 这个结果说的正是它。

检测读的是数据库自身的 taxonomy,绝不是某个样本的 kraken2 report —— report 只列出拿到 reads
的 taxa,所以一个带 decoy 的库在分析没有人源 reads 的样本时,report 里根本不会出现人源节点。

声明 `false` 却检出了任一类 decoy、或声明 `true` 却三类一个都没检出时,报告开头会给出明确的
不一致警告,并按声明执行。它不会悄悄选一边:一条措辞笃定却建立在错误前提上的提示,比没有
提示更糟。

## 为什么阴性不等于阴性

recall 取决于参考库里有没有近邻:存在 ≥80% ANI 近邻时约 96%,不存在时约 50%。read 级数字比
contig 级低 5-34 个百分点。precision 是样本组成的函数,不是分类器的属性 —— 同一个数据库在
VLP virome 上约 99.9%,在 bulk 宏基因组上保守下界约 82%。

所以一个 `not_detected` 的意思是「在这些设置下、用这个数据库,没有检出」。
