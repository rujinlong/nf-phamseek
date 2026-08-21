#!/usr/bin/env python3
"""Render the phamseek learning hub.

Re-runnable: rebuilds both the HTML and its sidecar manifest from the structured
content below, so a later --update reads the manifest rather than scraping HTML.

    python3 scripts/render_hub.py
"""
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, os.path.expanduser("~/.configure/skills/_atlas_core"))
import learning_html as L  # noqa: E402

REPO = Path("/home/allen/github/rujinlong/nf-phamseek")
BENCH = Path("/home/allen/github/rujinlong/p0126-kraken2phage")
OUT = REPO / "docs/learning-hub"
SLUG = "phamseek-hub"
F = "html_assets"
OUT.mkdir(parents=True, exist_ok=True)
(OUT / F).mkdir(exist_ok=True)


def f(p, label=None):
    """Local file link, absolute so it survives being opened from anywhere."""
    return f'<a href="file://{REPO}/{p}">{label or p}</a>'


def fb(p, label=None):
    """Link into the benchmark repo that phamseek is derived from."""
    return f'<a href="file://{BENCH}/{p}">{label or p}</a>'


# ---------------------------------------------------------------- §1 DAG
DAG = '''graph TD
  A["起点: p0126 测出了 kraken2 检测 phage 的能力边界<br/>结论要交付给临床实验室"]
  B["初始设计: 按默认假设做<br/>Illumina PE + 肠道样本 + UHGV 库"]
  C["读合作方 retreat 材料<br/>三个前提全错"]
  D["平台修正: ONT 单端 cDNA<br/>chopper/nanoq 换掉 fastp, minimap2 换 -ax map-ont"]
  E["库选型翻转: UHGV 是肠道 DNA virome<br/>对血浆无用 → INPHARED + decoy"]
  F["ONT 先导: 错误率主导灵敏度<br/>confidence 锁死 0.02"]
  G["嵌合按来源分层: 双向危害<br/>且 root 比例不能当嵌合率读数"]
  H["架构定案: pixi.lock 是依赖 SSOT<br/>容器/pixi/离线包三条路线同一个环境"]
  I["两级 host depletion<br/>分类只改标签, 删除必须是真的"]
  J["db_has_decoy 改 auto<br/>查库自身 taxonomy, 不查样本 report"]
  K["交付层三个静默坑<br/>CA 证书 / Nextflow plugin / login shell"]
  L["范围定案: Tier 1 only<br/>--mode full 明确报错不留半成品"]
  M["交付后上游变了: Nextflow 26.04<br/>命令行值全变 String, 两道防线缺一不可"]
  N["结果要有人看得懂: Krona 只画非宿主<br/>但 root 与 plasmid 一条都不能丢"]

  A -->|"结论怎么变成<br/>别人能跑的东西?"| B
  B -->|"动手前先读<br/>他们自己的材料"| C
  C -->|"平台不是 Illumina"| D
  C -->|"样本不是肠道"| E
  D -->|"短读的调参<br/>还成立吗?"| F
  F -->|"他们自陈的痛点<br/>是 chimeric reads"| G
  E -.->|"库定了"| H
  G -.->|"参数定了"| H
  H -->|"合规底线:<br/>删除必须是真的"| I
  I -.->|"报告要说清<br/>库里有没有 decoy"| J
  H -.->|"离线安装的<br/>隐藏联网点"| K
  I -.-> L
  J -.-> L
  K -.-> L
  L -->|"交付之后<br/>上游自己变了"| M
  L -->|"表格看不出<br/>样本里有什么"| N'''

CHAIN_LEAD = """<p><b>一句话主线</b>:把一个 benchmark 结论变成能在别人机器上跑的东西,
最大的风险不是工程实现,而是<b>你以为的场景不是真实场景</b>。这条链上最贵的一步是第三步 ——
读合作方自己的材料,发现平台、样本、参考库三个前提<b>全都错了</b>。
后面所有参数与架构决策,都是从那次修正长出来的。</p>"""

# ---------------------------------------------------------------- §2 steps
STEPS = [
    ("① 起点:结论已经有了,但没人能用",
     "why",
     f"{fb('README.md', 'p0126')} 测清楚了 kraken2 检测 phage 的能力边界 —— 参考库里有没有近邻决定一切、"
     "decoy 正交地解决质粒假阳性、contig 级数字都是上界。但这些结论住在一个 11 GB 的 benchmark 仓库里,"
     "<b>合作方无法直接使用</b>。要交付的不是数字,是一条能在他们机器上跑、且把这些边界条件写进报告的 pipeline。"),

    ("② 按默认假设做了初始设计 —— 后来证明三条全错",
     "warn",
     "在没读合作方材料前,默认假设是:Illumina paired-end、肠道/粪便样本、UHGV 同域库(因为 p0126 就是这么测的)。"
     "samplesheet 按双端写、QC 用 fastp、组装用 megahit、默认库指向 <code>uhgv_heldout_decoy</code>。"
     "<b>这一步的价值在于它错得足够彻底,值得记下来</b>:benchmark 的测试条件不等于部署条件,"
     "把前者当后者是最容易犯、也最贵的错。"),

    ("③ 读 retreat 材料:平台、样本、参考库三个前提同时崩了",
     "why",
     "合作方是 TUM Institute of Virology 的诊断实验室。他们的实际配置是:"
     "<b>Oxford Nanopore</b>(不是 Illumina)、<b>血浆与脑脊液的 cell-free RNA</b>(不是粪便)、"
     "而且<b>已经在用 Kraken2 PlusPF</b>(不是从零开始)。"
     "他们自陈的痛点是短 cDNA 片段 ligation 造成的 <b>chimeric reads</b>。"
     "<br><br>于是定位也变了:不做替换,做<b>并行的 phage 增强层</b> —— "
     "PlusPF 的 viral 部分是 RefSeq viral,真核病毒够用但 phage 覆盖稀疏,那正是可以补的一维。"),

    ("④ 平台修正:长读不是短读的加长版",
     "how",
     "samplesheet 从双端改单端(<code>sample_id,fastq,platform,sample_type</code>);"
     "QC 从 fastp 换成 <code>chopper</code> + <code>nanoq</code>;"
     "比对预设从 <code>-ax sr</code> 换成 <code>-ax map-ont</code>;"
     "组装器从 megahit 换成 flye(但始终没接线,见第 ⑫ 步)。"
     "<br><br>⚠ 一个容易漏的:<code>.mmi</code> 索引里存着建索引时的 <code>-k</code>/<code>-w</code>/"
     "<code>-H</code>,加载时<b>这三个会覆盖命令行给的值</b>(minimap2 会打一条 WARNING,但很容易被刷过去)。"
     "其余比对参数仍按命令行生效。所以索引要用与比对同一 preset 建,否则你以为在跑 "
     "<code>map-ont</code>,minimizer 却是别的 preset 的。"),

    ("⑤ 库选型翻转:「同域」里的『域』是随场景变的",
     "why",
     "UHGV 是人肠道 DNA virome 目录,对血浆/CSF 的 cell-free RNA 基本无用。"
     "INPHARED 覆盖临床病原菌(<i>Staphylococcus</i> / <i>Pseudomonas</i> / <i>Klebsiella</i> / "
     "<i>E. coli</i>)的培养 phage,才是这个场景要找的东西。默认库因此从 "
     "<code>uhgv_heldout_decoy</code>(11 G)改为 <code>inphared_decoy</code>(7.7 G)。"
     "<br><br>这不与 p0126 的结论矛盾 —— 那里说的是<b>库必须匹配目标生态位</b>,"
     "而生态位换了,匹配方向就反过来。"),

    ("⑥ 库大小买的是灵敏度,不是延迟",
     "how",
     "实测三个库(939 M / 3.9 G / 11 G):分类 100k read pairs 分别 0.298 / 0.316 / <b>0.339 秒</b> —— "
     "库放大 11 倍只慢 14%;而峰值 RAM 是 1.2 / 4.1 / 10.8 GB,<b>近似 1:1</b>"
     "(本机 DGX Spark aarch64 实测,warm page cache)。"
     "机制上 kraken2 的 k-mer 查询是<b>均摊近 O(1)</b> 的哈希查表,与库中条目数基本无关;"
     "实际延迟仍受缓存命中、内存带宽与一次性装库时间影响。"
     "<br><br>⇒ 在这个量级范围内,<b>「小库更快」几乎没有收益,而 RAM 是硬约束</b>。"
     "<code>preflight.sh</code> 因此把 RAM 做成硬门槛,且<b>按你实际要用的那个库算</b>:"
     "给了 <code>--db-dir</code> 就用该库的真实体积 + 4 GB headroom 判 PASS/WARN/FAIL;"
     "没给才退回一个规划性基线(默认库 <code>inphared_decoy</code> 的 8 GiB),"
     "用来回答「这台机器大概装得下吗」。换 11 GB 的库,门槛自动跟着抬到约 15 GB。"),

    ("⑦ ONT 先导:短读的调参直觉在这里不适用",
     "why",
     "把 confidence 从 0.02 提到 0.10,短读只掉 3.5 点,ONT 在 95% identity 下掉 15 点、"
     "87% 下掉 <b>29 点</b>。机制是:kraken2 的 confidence 衡量的是"
     "<b>「支持所标 clade 的 k-mer 占该序列 k-mer 的比例」</b>,"
     "而高错误率会打断大量 k-mer、直接压低这个比值。"
     "长读靠<b>更多 k-mer 提供的统计冗余</b>把损失补回来一部分,"
     "而收紧阈值恰恰把这部分冗余一起砍掉。"
     f"<br><br>⇒ <b>默认锁死 <code>--confidence 0.02</code></b>,并在 schema 的 help_text 里写清理由,"
     f"免得后人以为是随手定的。实测见 {fb('results/ont_pilot/identity_sweep.tsv')}。"),

    ("⑧ 嵌合:危害是双向的,而且合并指标看不见",
     "warn",
     "按 read 的真实来源分层后:跨 domain 嵌合 <b>34.7% 被整条计为 viral</b>"
     "(其中的 human 片段一起进了 viral 丰度)、<b>63.0% 被计为 human</b>(phage 片段静默丢失),"
     "<b>只有 0.70% 到达 root</b>。"
     "<br><br>而同源嵌合(phage+phage)的检出率反升到 92.7%,两个方向一抵消,"
     "总体「percent viral」几乎不动。<b>⇒ 报告里的 chimera 诊断必须标注为非特异性辅助信号</b>,"
     "不能让读者当成嵌合率读数;要真实嵌合率需要 split-mapping。"),

    ("⑨ 架构:用户不需要知道底下是 Nextflow",
     "how",
     "依赖 SSOT 是 <code>pixi.toml</code> + <code>pixi.lock</code>(双平台解析,"
     "部署时对方 <code>pixi install</code> 直接可用不必重新 solve);编排是 Nextflow DSL2,"
     f"入口就是标准的 <code>nextflow run rujinlong/nf-phamseek</code>。"
     f"同一份 lock 还喂给 {f('docker/Dockerfile')},所以容器、pixi 与离线包三条路线"
     "拿到的是同一个解出来的环境。"
     "<br><br>Nextflow 与 pixi 的接线用 <code>beforeScript</code> + <code>pixi shell-hook</code> —— "
     "不用 Nextflow 的 <code>conda</code> 指令(语义与 pixi 重叠、易误判),"
     "也不只把 <code>bin/</code> 塞进 PATH(会漏掉 <code>LD_LIBRARY_PATH</code> 等 activation 变量)。"),

    ("⑩ 两级 host depletion:分类不是删除",
     "why",
     "kraken2 的 human decoy 一遍就能标出 <b>99.56%</b> 的 human read(0.34 秒),"
     "但<b>标记不等于删除</b> —— 没删的 read 仍会进 assembly、进中间文件、进报告。"
     "临床数据的合规底线是<b>真删且可审计</b>。"
     "<br><br>所以设计成两级:L1 用 kraken2 的分类结果删掉 9606 子树(秒级、去掉 99.56%),"
     "L2 用 minimap2 对剩下的约 0.44% 做精确比对兜底。两级各自的去除比例都写进报告。"
     "<code>--l2_input</code> 默认 <code>all_nonhuman</code>(viral read 也过 L2),"
     "堵住「human read 被误判为 viral 就绕过去宿主」这个洞 —— 实测只多约 5% 工作量。"),

    ("⑪ db_has_decoy:问库里有什么,必须查库",
     "why",
     "报告需要知道参考库里有没有 decoy(有才能说质粒假阳性被压住了)。"
     "直觉做法是看样本的 kraken2 report 里有没有 taxid 9606 —— <b>这是错的,而且错得最隐蔽</b>:"
     "report 只列<b>有 read 落上</b>的 taxon。实测含 human decoy 的库跑 700 条纯 phage read,"
     "report 里 9606 <b>一条都没有</b>;库自身 taxonomy 却有 38,029 个节点。"
     "<br><br>照 report 判会得出「库里没有 decoy」,<b>恰好在 host depletion 最成功的样本上出错</b>。"
     "正解是 <code>kraken2-inspect</code> 查库自身,分 human / bacterial / plasmid 三类分别报;"
     "探测不到的报 <code>unknown</code> 并打 flag,<b>不猜</b>。"),

    ("⑫ 范围收敛:只做 Tier 1",
     "how",
     "assembly + geNomad + CheckV 全部不做,<code>--mode full</code> 直接报错。三条理由:"
     "① ONT 要换 flye,是独立的一大块;② 目标场景 coverage 极低"
     "(合作方的 <i>Coxiella</i> 案例只有 0.3% genome coverage),大概率拼不出;"
     "③ 他们已验证的路径本来就是 <b>kraken2 lead detection → mapping/BLAST 确证</b>,不是组装。"
     "<br><br><b>报错而不是留半成品</b> —— 一条跑通但结果不可信的路径,比一个明确的「未实现」危险得多。"),

    ("⑬ 交付之后,上游自己变了:命令行的值全成了 String",
     "warn",
     "Nextflow 26.04 起,命令行上的每个值都以 <b>String</b> 交给 pipeline;25.10 及以前由 launcher "
     "转成原生类型(四个版本实测:24.10.5 与 25.10.0 给 Integer/Boolean/Double,26.04.3 与 26.04.6 全给 String)。"
     "这不是插件的锅,而且到 26.04.6 仍未修。"
     "<br><br>后果一:<b>Groovy 认为非空字符串为真</b>,于是 <code>--skip_host_removal false</code> 会"
     "<b>静默跳过</b>第二级去宿主 —— 而参数摘要里明明印着 <code>false</code>。临床数据上这是本流程能犯的最严重的错误。"
     "⇒ 布尔参数一律经 <code>asBool()</code> 访问函数读,<b>绝不写 <code>if (params.some_boolean)</code></b>。"
     "<br><br>后果二:schema 里声明为 integer/number/boolean 的参数会被<b>直接拒</b>,等于命令行根本设不了。"
     "nf-validation 的 <code>validationLenientMode</code> 曾补偿这点(把字符串转成声明类型再校验),"
     "但 <b>nf-schema 的同名开关是反方向的</b> —— 它让「声明为 string」的参数接受别的标量,开着也救不了。"
     "⇒ schema 改写成 <code>\"type\": [\"integer\", \"string\"]</code> + <code>pattern</code>,"
     "主类型放第一位(<code>--help</code> 只显示 <code>type[0]</code>)。"
     "<br><br>⚠ 代价:<code>minimum</code>/<code>maximum</code> 只作用于 number 实例,对字符串不生效 ——"
     "唯一有范围的 <code>--kraken2_confidence</code> 因此改在 <code>validateMode()</code> 里手工查。"),

    ("⑭ Krona:把最该被看见的那部分留在图里",
     "how",
     "报告是表格,回答不了「这个样本里到底有什么」。Krona 图补上这一维,每样本一张 + 全 run 一张,"
     "自包含 HTML(Krona 2.8.1 内联 JS、logo 用 data URI,离线可开)。"
     "<br><br><b>只画非宿主子树</b> —— 血浆/CSF 里约 82% 的已分类 read 是 <i>Homo sapiens</i>,"
     "画进去会把其余一切压成看不见的细丝;去掉它也让图与 <code>--min_rpm</code> 用同一个分母。"
     "<br><br>⚠ 真正的坑在转换器:<code>kreport2krona.py</code> 的 <code>--intermediate-ranks</code> "
     "<b>默认是关的</b>,关着时它只保留 D/P/C/O/F/G/S 七个标准 rank,把落在别处的 read <b>整行跳过</b>。"
     "实测 330 个非宿主 read 里丢 74 个,而那 74 个正是落在 <code>root</code>(嵌合信号)与 "
     "<code>plasmids</code>(假阳性主因)上的 —— <b>默认设置恰好抹掉了这份数据里最该被看见的两类混淆源</b>,"
     "只留下干净漂亮的病毒分支。"
     "<br><br>⇒ 加 <code>--intermediate-ranks</code>,并在同一步做<b>计数守恒检查</b>:"
     "图里的总数必须等于过滤后 report 第 3 列之和,不等就 <code>exit 1</code>。"
     "<code>-stub</code> 验不出这类问题 —— 假数据上守恒平凡成立。"),
]

# ---------------------------------------------------------------- §5 decisions
DECISIONS = [
    ["不 merge 合作方的 PlusPF,改成并行跑两个库",
     "两个已建好的 kraken2 binary 库不能直接拼(<code>hash.k2d</code> 无法合并);"
     "重建需要原始 FASTA,而 PlusPF 是预建索引没有。",
     "并行跑、结果层合并 —— 不破坏他们现有流程。两个库共享 RefSeq 等来源、并不独立,"
     "所以这是<b>结果互证</b>而非统计意义上的交叉验证。库加载是分钟量级,跑两遍完全可接受。"],
    ["不做 assembly",
     "低生物量场景 coverage 太低,组装拼不出;且合作方已验证的路径不是组装。",
     "<code>--mode full</code> 明确报错并解释原因,不留可跑但不可信的半成品。"],
    ["bracken 默认关闭,且开关叫 run_bracken 而不是 skip_bracken",
     "bracken 从「一个固定读长」的 k-mer 分布重估丰度,而 ONT 读长本质可变 —— "
     "假设被构造性地违反。原默认值 150 是短读值,对 ONT 是错的。"
     "而旧名 <code>skip_bracken=true</code> 意味着开启要打 <code>--skip_bracken false</code>,"
     "一个必须写全的双重否定。",
     "<code>run_bracken</code> 默认 false,裸 <code>--run_bracken</code> 即开;"
     "<code>bracken_read_length</code> 无默认值,不给就在 <code>validateMode()</code> 中止。"
     "<b>旧名显式报错而不是被忽略</b> —— 被忽略的话 bracken 会在用户以为打开了的情况下保持关闭。"
     "极性约定:默认关的叫 <code>run_*</code>,默认开的叫 <code>skip_*</code>,两者都不必打 false。"],
    ["--l2_input 默认 all_nonhuman",
     "若只让「非 human 非 viral」的 read 过 L2,则一条被误判为 viral 的 human read 就绕过了去宿主 —— "
     "临床数据不能留这种旁路。",
     "viral read 也过 L2。实测代价只有约 5%(L2 负载本就由非 human 非 viral 的 read 主导)。"],
    ["--help 自己渲染,不交给 schema 插件",
     "严格 parser 下裸 <code>--help</code> 到 params 是 String <code>\"true\"</code>,"
     "而<b>每个</b> nf-schema 版本都把 String 读成「显示叫这个名字的参数的帮助」——"
     "于是插件找不到名为 true 的参数、<b>一个字都不印、pipeline 照常开跑</b>。"
     "用户要的是帮助,拿到的是一次运行,而且没有任何信号说明它坏了。",
     "关掉 <code>validation.help.enabled</code>,自己从同一份 <code>nextflow_schema.json</code> 渲染。"
     "把那个 String 当<b>特性</b>用:<code>\"true\"</code> 印全部,其它字符串当参数名查 ——"
     "<code>--help kraken2_confidence</code> 于是名副其实,两种 parser 下都工作。"],
    ["Krona 只画非宿主,但保留所有中间 rank",
     "画全部的话 82% 是 <i>Homo sapiens</i>,其余压成看不见的细丝;"
     "而 <code>kreport2krona.py</code> 的默认设置又会把落在非标准 rank 上的 read 静默丢掉 ——"
     "实测 330 里丢 74,且丢的正是 <code>root</code> 与 <code>plasmids</code> 这两类混淆源。",
     "先按缩进删掉 host 子树再转换,并显式加 <code>--intermediate-ranks</code>;"
     "同一步做<b>计数守恒检查</b>,图里总数与过滤后 report 第 3 列之和不等就 <code>exit 1</code>。"],
]

# ---------------------------------------------------------------- §6 apply
APPLY_ROWS = [
    ["p0126-kraken2phage(方法学地基)", "★★★ 直接派生",
     "phamseek 的每个默认值都能追溯到那里的一个实测数字",
     f"改参数前先读 {fb('docs/COLLAB-CLINICAL-PLAN.md', 'COLLAB-CLINICAL-PLAN.md')} 的边界条件"],
    ["TUM Virology 诊断实验室(交付对象)", "★★★ 进行中",
     "FUO 队列 15→50 例,ONT + 血浆/CSF cell-free RNA",
     "先 preflight 确认 RAM 能与 PlusPF 共存,再在 NTC 上验证污染背景模型"],
    ["p0101 BTEX groundwater virome", "★★",
     "<b>非肠道生态位、无同域参考库</b> —— 换个库就能复用整条 pipeline",
     "换 <code>--db_dir</code>;但要预期 recall 落在 50% 量级,并读库盲区诊断"],
    ["p0105 / p0106 大样本 virome(262 / ~280 样本)", "★★",
     "大样本需要秒级筛查,而 kraken2 恰恰不是瓶颈",
     "复用 Tier 1;注意给 kraken2 设 <code>maxForks</code>,并发会按库大小成倍吃 RAM"],
    ["pc028e3 Avian Virome Database", "★★",
     "建库时的 decoy 化与 taxid 设计可直接照搬",
     f"参考 {fb('scripts/build_decoy_db.py')} 的 DECOYS 与 taxid 分配"],
    ["任何要交付给外部机构的 pipeline", "★★ 方法可迁移",
     "三档交付 + 数据库外置 + preflight 的模式与 phage 无关",
     f"照搬 {f('deploy/')} 整层;INSTALL.md 是英文的,可直接给对方"],
]

# ---------------------------------------------------------------- §7 curriculum
CURRICULUM = [
    ("必修", "ONT 错误模型与 basecalling 版本",
     "read identity 主导 kraken2 灵敏度,87% 与 99% 差一倍以上",
     "从 dorado 的 simplex/duplex 模型差异读起"),
    ("必修", "低生物量测序的污染控制(kitome / NTC)",
     "血浆与 CSF 里试剂背景常常盖过真实信号",
     "Salter 2014 的 kitome 论文 + 你自己的 NTC 数据"),
    ("必修", "pixi 与 conda 生态的关系",
     "依赖 SSOT 是整个交付方案的地基",
     "pixi.toml / pixi.lock 的语义,以及 pixi-pack 的重定位机制"),
    ("必修", "Nextflow 版本间的行为变化,尤其命令行参数的类型",
     "26.04 起命令行值全变 String,一条 <code>if (params.flag)</code> 就能静默改变行为",
     "在两个 Nextflow 世代上各跑一遍参数矩阵,别只测当前版本"),
    ("进阶", "Nextflow 的 stub 语义与其局限",
     "<code>-stub</code> 不渲染 script 块,也会短路提前 return 的初始化逻辑 —— 全绿证明不了什么",
     "读本 repo 的 <code>validateMode()</code> 与 <code>resolveDatabases()</code> 的分工"),
    ("进阶", "chimera 检测与 split-mapping",
     "root 比例不是嵌合率代理,拿真实嵌合率只能靠 split-mapping",
     "从 minimap2 的 supplementary alignment 语义读起"),
    ("进阶", "容器与宿主环境的边界",
     "%environment 覆盖不到 login shell,这类问题只在别人机器上暴露",
     "apptainer 的 env 注入顺序 + /etc/profile.d 的作用时机"),
    ("应用", "诊断项目的 LoD 与稀释系列设计",
     "临床方最关心的数字,本项目尚未覆盖",
     "从 CLSI 的 LoD 指南 + spike-in 矩阵设计读起"),
    ("应用", "临床 NGS 的合规要求",
     "host read 必须真删且可审计,不是技术选择而是底线",
     "GDPR 下人类遗传数据的处理要求"),
]

# ---------------------------------------------------------------- §9 flashcards
CARDS = [
    ("交付一条 pipeline 给外部实验室,最大的风险是什么?",
     "<b>你以为的场景不是真实场景。</b> 本项目在读合作方材料前,三个前提全错:"
     "平台以为是 Illumina(实际 ONT)、样本以为是粪便(实际血浆/CSF cell-free RNA)、"
     "参考库以为用 UHGV(实际该用 INPHARED)。"
     "<br><br>工程实现的错误改起来是分钟量级,场景假设的错误会让整条 pipeline 白做。"
     "<b>动手前先读对方自己的材料</b>,比任何架构讨论都值钱。"),

    ("kraken2 的 human decoy 已经能标出 99.56% 的 human read,为什么还要第二级 minimap2?",
     "因为<b>分类只改标签,不删序列</b>。被标记的 read 仍然在文件里,会进 assembly、"
     "进中间产物、进报告。临床数据的合规底线是<b>真删且可审计</b>。"
     "<br><br>两级的分工:L1 秒级去掉 99.56%,L2 只需处理剩下的约 0.44%(工作量降到 1/200)"
     "并做精确比对兜底。两级各自的去除比例都写进报告。"
     "<br><br>⚠ 0.44% 在一个 50M reads 的样本里仍是约 22 万条 —— 不能只做 L1。"),

    ("要知道一个 kraken2 库里有没有 human decoy,能不能看样本的 kraken2 report?",
     "<b>不能,而且错的方向最危险。</b> report 只列有 read 落上的 taxon。"
     "实测:含 human decoy 的库跑 700 条纯 phage read,report 里 taxid 9606 一条都没有;"
     "库自身 taxonomy 却有 38,029 个节点。"
     "<br><br>照 report 判会得出「库里没有 decoy」——<b>恰好在 host depletion 最成功的样本上出错</b>。"
     "正解是 <code>kraken2-inspect</code> 查库自身。"
     "<br><br>可迁移原则:样本级输出是「参考数据 ∩ 样本」的交集,"
     "<b>用交集反推全集,在交集为空时必然错</b>,而交集为空往往正是系统工作良好的标志。"),

    ("ONT 上 <code>--confidence</code> 该怎么设?为什么不能沿用短读的经验?",
     "<b>锁 0.02,不要调高。</b> 短读上 0.02→0.10 只掉 3.5 点,ONT 在 95% identity 下掉 15 点、"
     "87% 下掉 29 点。"
     "<br><br>机制:confidence 是「匹配 k-mer 占比」。高错误率本就压低了这个比例"
     "(35-mer 在 5% 错误率下完全无错的概率仅约 17%),长读靠重叠 k-mer 补偿,"
     "而收紧阈值会把补偿一起削掉。"
     "<br><br>⚠ 低于 0.02 的取值本项目未测,所以这不是「越低越好」。"),

    ("为什么宁可让 <code>--mode full</code> 报错,也不留一条能跑的组装路径?",
     "因为<b>一条跑通但结果不可信的路径,比一个明确的「未实现」危险得多</b>。"
     "<br><br>目标场景是低生物量(合作方的 <i>Coxiella</i> 案例只有 0.3% genome coverage),"
     "组装大概率拼不出东西;而用户看到有输出就会去解读它。"
     "明确报错 + 解释原因,让人知道该走哪条路(kraken2 lead → mapping/BLAST 确证)。"),

    ("bracken 为什么默认关闭?开关为什么叫 run_bracken 而不是 skip_bracken?",
     "它从「一个固定读长」的 k-mer 分布重估丰度,而 ONT 读长本质可变 —— <b>假设被构造性地违反</b>。"
     "原来的默认值 150 是短读值,对 ONT 直接是错的。"
     "<br><br>名字则是<b>极性问题</b>:<code>skip_bracken=true</code> 意味着开启要打 "
     "<code>--skip_bracken false</code> —— 一个必须写全的双重否定,而且从 Nextflow 26.04 起"
     "那个 <code>false</code> 以 String 到达,不经 <code>asBool()</code> 就会被 Groovy 读成真。"
     "改名后裸 <code>--run_bracken</code> 即开,<b>无法被写反</b>。"
     "<br><br>约定:默认关的叫 <code>run_*</code>,默认开的叫 <code>skip_*</code>。"
     "旧名现在<b>显式报错</b>而不是被忽略 —— 被忽略的话 bracken 会在用户以为打开了的情况下保持关闭。"),

    ("同一条 pipeline 在 Nextflow 25.10 上跑得好好的,升到 26.04 后 <code>--skip_host_removal false</code> 却静默跳过了去宿主。为什么?",
     "<b>26.04 起命令行上的每个值都以 String 交给 pipeline</b>,25.10 及以前由 launcher 转成原生类型。"
     "四个版本实测:24.10.5 / 25.10.0 给 Integer、Boolean、Double;26.04.3 / 26.04.6 全给 String。"
     "这是上游行为变化,到最新版仍未修。"
     "<br><br>而 <b>Groovy 认为非空字符串为真</b>,于是 <code>\"false\"</code> 求值为 <b>真</b> ——"
     "参数摘要里印着 <code>false</code>,行为却是「跳过」。"
     "<br><br>两道防线缺一不可:① 布尔一律经 <code>asBool()</code> 访问函数读,"
     "<b>绝不写 <code>if (params.some_boolean)</code></b>;"
     "② schema 里数值/布尔参数声明成 <code>[\"integer\", \"string\"]</code> + <code>pattern</code>,"
     "否则 <code>validateParameters()</code> 直接拒掉,命令行根本设不了。"
     "<br><br>⚠ 别指望 nf-schema 的 <code>lenientMode</code> —— 它与 nf-validation 的同名开关"
     "<b>方向相反</b>(它让「声明为 string」的参数接受别的标量),开着也救不了。"),

    ("把 kraken2 report 转成 Krona 图,退出码 0、图也画得很漂亮。还需要检查什么?",
     "<b>检查有没有 read 被悄悄丢掉。</b> <code>kreport2krona.py</code> 的 "
     "<code>--intermediate-ranks</code> 默认是关的,关着时它只保留 D/P/C/O/F/G/S 七个标准 rank,"
     "把落在其它节点上的 read <b>整行跳过</b>,不警告、不计数。"
     "<br><br>实测:330 个非宿主 read 丢掉 74 个,而那 74 个是 <code>root</code>(38 条,嵌合信号)、"
     "<code>cellular organisms</code>(1 条)与 <code>plasmids</code>(35 条,phage 假阳性主因)。"
     "<b>默认设置恰好抹掉了这份数据里最该被看见的两类混淆源</b>,只留下干净的病毒分支 ——"
     "读图的人会得出比数据支持的更强的结论。"
     "<br><br>判据是<b>守恒</b>:图里 read 总数必须等于过滤后 report 第 3 列(每个节点自身的 reads)之和,"
     "不等就让这一步 <code>exit 1</code>。"
     "<br><br>可迁移原则:凡「换一种表示」的转换工具(report → 图/表/另一种格式),"
     "都要先问<b>「它默认丢什么」</b>,并用一个守恒量把它钉住。<code>-stub</code> 验不出来 ——"
     "假数据上守恒平凡成立。"),

    ("离线安装一个 conda 环境,有哪两个「不联网也会炸」的点?",
     "① <b><code>pixi-unpack</code> 没有系统 CA 信任库就 panic</b> —— 它启动时无条件构造 "
     "reqwest client,精简镜像里没装 <code>ca-certificates</code> 就在解第一个包之前死掉,"
     "而 Rust backtrace 完全不提证书。"
     "<br><br>② <b>Nextflow 的 plugin 要预取</b>(<code>nf-schema</code> 等首次运行会联网下载),"
     "但 framework/capsule jar <b>不用</b> —— bioconda 的 nextflow 包自带。两者常被一起误当成要预取的。"
     "<br><br>验证气隙的正确方法:<code>apptainer exec --net --network=none</code>,"
     "并先跑 <code>getent hosts github.com</code> 确认解析失败 —— 否则「离线测试通过」"
     "可能只是它偷偷联网成功了。"),

    ("容器里 <code>apptainer exec img kraken2</code> 能跑,但 <code>bash -lc 'kraken2'</code> 报 command not found,为什么?",
     "<code>%environment</code> 注入的是容器进程的<b>初始环境</b>,而 login shell 会 source "
     "<code>/etc/profile</code>,后者用 <code>PATH=...</code> <b>直接赋值</b>(不是追加),"
     "把容器前置的路径整个冲掉。"
     "<br><br>修法:除 <code>%environment</code> 外,还要在 <code>%post</code> 里写一个 "
     "<code>/etc/profile.d/*.sh</code>,用幂等的 case 判断避免重复前置。"
     "<br><br>⚠ 为什么容易漏:<code>%test</code> 块和日常 <code>exec &lt;cmd&gt;</code> 都走非 login shell,"
     "全绿;只有别人用了 <code>bash -l</code> 才炸,而那时人已经在对方机器上了。"),
]

# ---------------------------------------------------------------- §10 glossary
GLOSS = {
    "Tier 1 / Tier 2": "phamseek 的两级分析。Tier 1 是 read level(QC → kraken2 → 两级去宿主 → "
                       "Krona 图 → 报告),只实现了这一级;Tier 2 是 assembly → geNomad → CheckV,预留未实现。",
    "两级 host depletion": "L1 用 kraken2 的分类结果删 human(秒级、99.56%),"
                           "L2 用 minimap2 对剩余约 0.44% 做精确比对兜底。分类只改标签,删除必须是真的。",
    "decoy": "参考库里加入的三类非 phage 序列:human(CHM13v2)、bacterial(GTDB 肠道菌)、"
             "plasmid(mob_suite NCBI)。给 LCA 一个「正确的去处」——"
             "plasmid decoy 把质粒假阳性从 37.4% 压到 ≤0.4%,human decoy 让 L1 去宿主成为可能,"
             "三类各自独立探测、独立报告。",
    "db_has_decoy auto": "用 kraken2-inspect 读库自身 taxonomy 来判定 decoy 组成,"
                         "分 human / bacterial / plasmid 三类分别报。绝不从样本 report 反推。",
    "chimeric read": "两段来源不同的序列在文库制备时被连成一条。ONT cDNA 文库里由短片段 ligation 或 "
                     "Phi29 扩增前的 spacer 串联造成。",
    "confidence": "kraken2 的判定阈值,语义是「匹配 k-mer 占比」。ONT 上高错误率本就压低这个比例,"
                  "所以短读常用的 0.10 会砍掉大量真阳性。phamseek 锁 0.02。",
    "pixi": "依赖管理器,单个静态二进制,免 root,装进自包含目录,不碰既有 conda 安装。"
            "phamseek 的依赖 SSOT 是 pixi.toml + pixi.lock。",
    "pixi-pack": "把 pixi 环境打成离线自解压包。⚠ 目标机没有 ca-certificates 会直接 panic。",
    "preflight": "部署前的目标机体检:arch、glibc、RAM(对照将被整个载入内存的库)、"
                 "磁盘、既有 conda 泄漏的环境变量、外网可达性、数据库完整性。",
    "NTC (no-template control)": "无模板对照。低生物量样本里区分真实信号与试剂背景的前提;"
                                 "phamseek 的 samplesheet 有 sample_type 列可标记它。",
    "cell-free RNA (cfRNA)": "血浆或脑脊液中游离的 RNA 片段。临床 NGS 用它做病原体检测,"
                             "特点是极低微生物量、极高 human 背景。",
    "run_bracken / skip_krona": "布尔参数的极性约定:默认关的叫 run_*(裸 --run_x 即开),"
                                "默认开的叫 skip_*(裸 --skip_x 即关)。两者都不需要在后面打 false ——"
                                "而从 Nextflow 26.04 起打 false 本身就是危险的,因为那个值以 String 到达。",
    "Krona / Pavian": "同一份 kraken2 结果的两个视图,但工作方式完全不同。Krona 是<b>真正的流程步骤</b>,"
                      "产出自包含 HTML(非宿主子树,含 root 与 plasmids)。Pavian <b>不是步骤</b> ——"
                      "它是流程外跑的 R/Shiny 应用,所谓集成就是把每个样本的 report 再 publish 一份到 "
                      "summary/pavian/,外加一份 README。绝不为它把 R 和 Shiny 拖进容器。",
    "库盲区诊断": "报告里的一项指标:kraken2 未分类但落在 viral 特征上的比例。"
                  "用来区分「真阴性」与「参考库不覆盖」—— 没有它,用户无从判断没检出意味着什么。",
}

# ---------------------------------------------------------------- sections
sections = [
    L.box(
        L.callout("link",
            "把下面这段贴给浏览器里的 AI,让它当这页的导师:<br><br>"
            "<i>「你是生信 pipeline 工程与临床交付方向的导师。请先通读本页全部内容,然后:"
            "(1) 用三句话复述 §1 推导链的主线,重点说清第 ③ 步为什么是整条链最贵的一步;"
            "(2) 针对 §2 中我指定的任一步,解释『为什么必须走到下一步』,并举一个反例说明"
            "如果不这么做会在部署当天出什么事;"
            "(3) §3 的两条原理请用具体数字讲,不要泛泛而谈;"
            "(4) 最后帮我把 §6 的项目连接扩展到我手上的具体数据集上,并指出我最可能踩的坑。"
            "全程中文,专业名词保留英文。」</i>",
            label="🤖 给浏览器 AI 的导师提示") +
        L.callout("warn",
            "<b>本页讲的是「怎么把一个 benchmark 结论变成能交付的东西」。</b>"
            "方法学本身(检出率、假阳性、能力边界怎么测出来的)在 "
            f"{fb('docs/learning-hub/kraken2-phage-detection-hub.html', 'p0126 的 learning hub')},"
            "两页互补:那边讲「结论怎么来」,这边讲「结论怎么落地」。"),
        h2="§0 · 怎么用这页", anchor="use"),

    L.box(CHAIN_LEAD + L.mermaid(DAG) +
          L.callout("why",
              "<b>读图要点</b><br>"
              "<b>实线</b>=前一步直接逼出下一步(有因果);<b>虚线</b>=并列约束汇入同一个决策点 —— "
              "比如 H(架构)是「库定了」和「参数定了」共同的下游,而 L(范围收敛)是 I/J/K 三条约束"
              "汇合的结果,不是任何单一一步推出来的。<br><br>"
              "两处值得注意:第 ③ 步是<b>唯一分叉出两条边</b>的节点 —— 读一次材料同时推翻了"
              "平台假设(→④)与样本假设(→⑤);而工程决策(⑨⑩⑪⑫)<b>全部排在场景修正之后</b>,"
              "这不是巧合:<b>在场景没确定前做的架构决策,大概率要重做</b>(第 ② 步就是代价)。"),
          h2="§1 · 推导链总图", anchor="chain"),

    L.box("".join(L.callout(kind, body, label=title) for title, kind, body in STEPS) +
        L.figure(f"{F}/fig_cli_string_trap.jpg",
                 caption="同一条命令在两个 Nextflow 世代上给出不同的行为,而参数摘要两边都印 "
                         "<code>false</code>。两道防线各挡一半:访问函数管「读进来的值」,"
                         "schema 的双类型声明管「值能不能进来」——<b>缺任何一道都会静默出错</b>。") +
        L.figure(f"{F}/fig_krona_dropped_ranks.jpg",
                 caption="两侧画的是同一份 report,差别只在转换器丢不丢非标准 rank。"
                         "丢掉的 74 条不是随机一批,而是落在 <code>root</code>(嵌合信号)与 "
                         "<code>plasmids</code>(假阳性主因)上的 —— "
                         "<b>默认设置恰好抹掉了这份数据里最该被看见的两类混淆源</b>。") +
          L.figure(f"{F}/ont_pilot.png",
                   caption="第 ⑦⑧ 步的实测依据:左,错误率主导灵敏度,confidence 阈值的代价远大于短读;"
                           "右,按 read 真实来源分层后,跨 domain 嵌合被分到两侧,到 root 的只有 0.70%。"
                           "这两张图直接决定了 phamseek 的默认参数与报告措辞。") +
          L.callout("link",
              f"实现:{f('workflows/phamseek.nf')} · {f('nextflow.config')} · "
              f"{f('subworkflows/local/utils_phamseek_pipeline/main.nf')}<br>"
              f"实测依据:{fb('scripts/ont_pilot.sh')} · "
              f"{fb('results/ont_pilot/identity_sweep.tsv')} · "
              f"{fb('results/ont_pilot/chimera_stratified.tsv')}",
              label="🔗 相关文件"),
          h2="§2 · 推导链逐步详解", anchor="steps"),

    L.box(
        "<p><b>原理一:分类不是删除。</b>这条决定了 host depletion 必须做两级。</p>" +
        L.figure(f"{F}/fig_two_level_depletion.jpg",
                 caption="同一个含 human decoy 的库,两种用法给出的保证完全不同:"
                         "只分类的话 99.56% 的 human read 被打上 taxid 9606 的标签,但它们<b>还在文件里</b>,"
                         "会继续流向下游;两级设计则用这个标签驱动真正的删除,"
                         "再让 minimap2 对剩下的约 0.44% 做精确兜底。两级的去除比例都写进报告。") +
        "<p>为什么不能只做 L2(直接全量 minimap2)?因为那要对整个 read 池做比对,"
        "而临床样本里 human 占绝对多数 —— L1 把工作量降到 <b>1/200</b>。"
        "为什么不能只做 L1?因为 " + L.term("0.44% 的残留", "kraken2 未分类或误分的 human read") +
        "在一个 50M reads 的样本里仍是约 22 万条,而合规要求的是<b>真删且可审计</b>。</p>" +
        L.callout("warn",
            "<code>--l2_input</code> 默认 <code>all_nonhuman</code>,连 viral read 也过 L2。"
            "这是<b>刻意的</b>:否则一条被误判为 viral 的 human read 就绕过了去宿主。"
            "实测代价只有约 5%,而留一个合规旁路的代价无法估量。") +
        "<hr style='margin:1.6em 0;border:0;border-top:1px solid #e5e7eb'>"
        "<p><b>原理二:问「参考库里有什么」必须查库本身。</b>"
        "这条决定了 <code>db_has_decoy</code> 的实现方式。</p>" +
        L.figure(f"{F}/fig_query_the_database.jpg",
                 caption="样本 report 是「库 ∩ 样本」的交集。含 human decoy 的库跑纯 phage 样本时,"
                         "交集里根本不会出现 human 节点 —— 用交集反推全集,"
                         "<b>恰好在 host depletion 最成功的样本上给出相反的答案</b>。"
                         "正解是用 kraken2-inspect 查库自身 taxonomy,三类 decoy 分别报。") +
        "<p>这条原理的适用面远超本项目:<b>凡是问「某个参考数据/模型<i>里</i>有什么」,"
        "都必须查那个数据本身</b>。同类误用包括:用 profiler 输出反推数据库覆盖度、"
        "用比对结果反推索引内容、用命中列表反推 panel 设计。</p>" +
        L.callout("link",
            f"实现:{f('modules/local/db_manifest.nf')} · "
            f"{f('bin/phamseek_report.py')}<br>"
            f"机制的 benchmark 侧记录:{fb('CLAUDE.md', 'p0126 CLAUDE.md 的分析纪律')}",
            label="🔗 相关文件"),
        h2="§3 · 两条核心原理", anchor="principle"),

    L.box(
        L.figure(f"{F}/delivery-architecture.jpg",
                 caption="三档交付路线都从同一份 pixi.lock 派生,软件完全一致;"
                         "参考数据库永远走另一条路,运行时只读挂载。"
                         "决定走哪条路的只有两个问题:目标机能上网吗、有没有 container runtime。") +
        L.callout("how",
            "<b>档 1 · <code>pixi install</code> 直装</b> —— 主推。pixi 是单个静态二进制,免 root,"
            "装进自包含目录,不碰对方既有的 conda。<code>pixi.lock</code> 已含 linux-64 完整解析,"
            "对方直接 install 不必重新 solve。<br><br>"
            "<b>档 2 · <code>pixi-pack</code> 离线自解压包</b> —— 无外网时用。"
            "⚠ 目标机必须有 <code>ca-certificates</code>,否则 <code>pixi-unpack</code> 在解第一个包之前 panic。<br><br>"
            "<b>档 3 · apptainer SIF</b> —— 有 container runtime 时的最强隔离。"
            "⚠ <code>%environment</code> 覆盖不到 login shell,必须另写 <code>/etc/profile.d/</code>。",
            label="🚚 三档交付") +
        L.callout("warn",
            "<b>数据库永远外置</b>,由 <code>--db_dir</code> 指向宿主目录,进容器时 <code>--bind</code> 只读挂载。"
            "只需要 <code>kraken2/</code> 与 <code>host/</code> 两个子目录;"
            "<code>genomad_db/</code> 与 <code>checkv/</code> 属于未实现的 assembly tier,"
            "缺失时 preflight 只给 INFO 不给 WARN。") +
        L.callout("link",
            f"{f('deploy/INSTALL.md', 'INSTALL.md(英文,给合作方)')} · "
            f"{f('deploy/MAINTAINERS.md')} · {f('deploy/preflight.sh')} · "
            f"{f('deploy/pack_offline.sh')} · {f('deploy/apptainer/phamseek.def')}",
            label="🔗 相关文件"),
        h2="§4 · 交付架构", anchor="delivery"),

    L.box(
        L.table(["决策", "为什么", "怎么做的"], DECISIONS) +
        L.callout("warn",
            "<b>共同的模式</b>:这几条都不是「哪个更好」的技术选择,而是<b>「错了会怎样」的风险选择</b>。"
            "报错优于半成品、显式优于默认、合规优于省 5% 算力 —— "
            "因为部署之后,错误的发现成本会高一个数量级。"),
        h2="§5 · 关键决策", anchor="decisions"),

    L.box(
        L.callout("how",
            "<b>核心连接技术:参考库外置 + 单命令封装。</b>"
            "phamseek 的 pipeline 本身与「phage」耦合很浅 —— 换一个 kraken2 库、"
            "换一个 host 索引,同一条流程就能服务另一个生态位。"
            "真正沉淀下来的是<b>交付层</b>(preflight / 离线包 / 容器 / 数据库分卷校验),"
            "那一整层与生物学无关,可以整体搬走。",
            label="🔧 核心连接技术") +
        L.table(["项目", "相关度", "通过哪个技术点连接", "立刻能做什么"], APPLY_ROWS) +
        L.callout("learn",
            "<b>两个值得推进的方向</b><br><br>"
            "① <b>LoD 与 spike-in 矩阵</b> —— 诊断项目最关心的数字,本项目完全没碰。"
            "在阴性 plasma/CSF 背景里加已知 phage/病原体,交叉 abundance × 错误率 × 读长 × 嵌合比例,"
            "以高质量 mapping 为 truth 测检出限。<b>连接点</b>:直接决定这条 pipeline 能否进临床流程,"
            "是投诊断类期刊(<i>J Clin Microbiol</i> / <i>Clin Infect Dis</i>)的必要材料。<br><br>"
            "② <b>phage 作为污染判别的正交证据</b> —— 真实菌血症可能伴随该菌的 phage 信号,"
            "而试剂背景不易产生这种一致性。<b>但这条判据两个方向都有反例</b>"
            "(菌株无 prophage / prophage 沉默 / 抗菌治疗后信号消失;反向则有游离 phage、肠道易位、"
            "试剂自带 phage 核酸),<b>必须先在已知阳性与已知阴性上测敏感性与特异性</b>。"
            "<b>连接点</b>:若成立,这是低生物量宏基因组学的一个通用工具,不限于 phage 领域。"),
        h2="§6 · ★ 连接到用户的项目", anchor="apply"),

    L.box(
        "".join(
            L.collapsible(f"{tier} · {item}",
                          f"<p><b>为什么学</b>:{why}</p><p><b>从哪起步</b>:{start}</p>")
            for tier, item, why, start in CURRICULUM),
        h2="§7 · 额外要补的知识", anchor="learn"),

    L.box(
        L.callout("link",
            f"<b>本 repo</b><br>"
            f"{f('README.md')} · {f('docs/usage.md')} · {f('docs/output.md')} · "
            f"{f('deploy/INSTALL.md', 'INSTALL.md(英文)')} · {f('deploy/MAINTAINERS.md')}<br><br>"
            f"<b>方法学地基</b><br>"
            f"{fb('README.md', 'p0126 主报告')} · "
            f"{fb('docs/HANDOFF.md', 'p0126 HANDOFF')} · "
            f"{fb('docs/COLLAB-CLINICAL-PLAN.md', '临床交付计划')} · "
            f"{fb('docs/learning-hub/kraken2-phage-detection-hub.html', 'p0126 learning hub')}<br><br>"
            f"<b>合作方材料</b><br>"
            f"{fb('docs/from-collaborator/HS-retreat_3.md', 'retreat 幻灯(已转 md)')} · "
            f"{fb('docs/from-collaborator/draft-reply-2026-08-07.md', '回信草稿')}",
            label="📁 文档") +
        L.callout("link",
            '<a href="file:///home/allen/brain/wiki/atlas/portfolio.yaml">portfolio.yaml</a> · '
            '<a href="file:///home/allen/vpipe/docs/INVARIANTS.md">vpipe INVARIANTS(Nextflow 铁律)</a> · '
            '<a href="file:///home/allen/vpipe/docs/METHODOLOGY_LESSONS.md">vpipe METHODOLOGY_LESSONS</a> · '
            '<a href="file:///home/allen/vpipe/docs/RUNBOOK.md">vpipe RUNBOOK(离线部署两个坑)</a>',
            label="🌐 知识库") +
        L.callout("warn",
            "<b>红线</b>:phamseek 是 research-use-only,<b>不得用于临床诊断</b>;"
            "报告里每个阳性都是需要正交确证的 candidate;"
            "ONT 先导只支持条件结论,<b>不能反推真实样本的绝对嵌合率</b>,也没测 LoD;"
            "<code>--confidence</code> 与数据库包是耦合的 —— 改阈值会让已发出的库包在重新校验时 gate 4 失败。"),
        h2="§8 · 知识库枢纽", anchor="kb"),

    L.box("".join(L.flipcard(q, a) for q, a in CARDS),
          h2="§9 · 间隔重复卡片", anchor="recall"),

    L.box(L.gloss(GLOSS), h2="§10 · 术语表", anchor="gloss"),
]

html = L.page(
    title="phamseek:把 benchmark 结论变成能交付的 pipeline",
    subtitle="ONT 临床宏基因组的 phage 检测 · 从场景修正到可交付",
    lead="一条以「场景假设被推翻」为转折点的推导链 —— 三个前提(平台、样本、参考库)"
         "在读完合作方材料后同时崩塌,后面所有参数与架构决策都是从那次修正长出来的。",
    sections=sections,
    libs=["mermaid", "katex"],
    progress=True,
    layout="grid",
)
(OUT / f"{SLUG}.html").write_text(html)

manifest = {
    "slug": SLUG,
    "title": "phamseek:把 benchmark 结论变成能交付的 pipeline",
    "subtitle": "ONT 临床宏基因组的 phage 检测 · 从场景修正到可交付",
    "lead": "一条以「场景假设被推翻」为转折点的推导链。",
    "created": "2026-08-07", "updated": "2026-08-07",
    "dag": {
        "mermaid": DAG,
        "nodes": ["起点 p0126 结论要交付", "初始设计 按默认假设", "读 retreat 材料 前提全错",
                  "平台修正 ONT 单端", "库选型翻转 INPHARED+decoy", "ONT 先导 confidence 锁 0.02",
                  "嵌合分层 双向危害", "架构 pixi+Nextflow 单命令", "两级 host depletion",
                  "db_has_decoy 查库", "交付层三个坑", "Tier 1 only", "命令行值全是 String"],
        "edges": [["A", "B", "结论怎么变成别人能跑的东西"], ["B", "C", "动手前先读对方材料"],
                  ["C", "D", "平台不是 Illumina"], ["C", "E", "样本不是肠道"],
                  ["D", "F", "短读调参还成立吗"], ["F", "G", "他们自陈痛点是 chimeric reads"],
                  ["E", "H", "参数定了怎么装到别人机器"], ["G", "H", "参数定了怎么装到别人机器"],
                  ["H", "I", "临床数据合规底线"], ["I", "J", "报告怎么知道库里有没有 decoy"],
                  ["H", "K", "离线安装真的不联网吗"], ["J", "L", "范围收到多大不留半成品"],
                  ["K", "L", ""]],
    },
    "steps": [{"title": t, "kind": k, "body": b} for t, k, b in STEPS],
    "principle": "两条。① 分类不是删除 —— kraken2 给 read 打标签这一操作本身不移除任何序列,"
                 "而临床合规要求的是真删且可审计;这是操作语义与合规边界的问题,"
                 "两级 host depletion(L1 秒级去 99.56%,L2 精确兜底剩余 0.44%)只是它在本场景下的工程实现。"
                 "② 问「参考库里有什么」必须查库本身 —— 样本 report 是「库 ∩ 样本」的交集,"
                 "用交集反推全集在交集为空时必然错,而交集为空往往正是系统工作良好的标志。",
    "sources": ["README.md", "docs/usage.md", "docs/output.md", "deploy/INSTALL.md",
                "deploy/MAINTAINERS.md",
                "/home/allen/github/rujinlong/p0126-kraken2phage/docs/COLLAB-CLINICAL-PLAN.md"],
    "decisions": [{"decision": d[0], "why": d[1], "how": d[2]} for d in DECISIONS],
    "apply_table": APPLY_ROWS,
    "curriculum": [{"tier": t, "item": i, "why": w, "start": s} for t, i, w, s in CURRICULUM],
    "kb_links": ["README.md", "docs/usage.md", "docs/output.md", "deploy/INSTALL.md",
                 "deploy/MAINTAINERS.md",
                 "/home/allen/github/rujinlong/p0126-kraken2phage/README.md",
                 "/home/allen/github/rujinlong/p0126-kraken2phage/docs/COLLAB-CLINICAL-PLAN.md",
                 "/home/allen/vpipe/docs/INVARIANTS.md",
                 "/home/allen/brain/wiki/atlas/portfolio.yaml"],
    "flashcards": [{"q": q, "a": a} for q, a in CARDS],
    "glossary": GLOSS,
    "figures": [
        {"id": "fig_two_level_depletion", "src": f"{F}/fig_two_level_depletion.jpg",
         "module": "principle",
         "caption": "分类不是删除:同一个 decoy 库,只分类与两级删除给出的保证完全不同",
         "model": "gemini-3-pro-image", "created": "2026-08-07"},
        {"id": "fig_query_the_database", "src": f"{F}/fig_query_the_database.jpg",
         "module": "principle",
         "caption": "样本 report 是库与样本的交集,用交集反推全集在交集为空时必然错",
         "model": "gemini-3-pro-image", "created": "2026-08-07"},
        {"id": "delivery_architecture", "src": f"{F}/delivery-architecture.jpg",
         "module": "delivery",
         "caption": "三档交付从同一份 pixi.lock 派生,数据库永远走另一条路",
         "model": "gemini-3-pro-image", "created": "2026-08-07"},
        {"id": "ont_pilot", "src": f"{F}/ont_pilot.png", "module": "steps",
         "caption": "ONT 上的 identity sweep 与嵌合分层实测,决定了默认参数与报告措辞",
         "model": "matplotlib", "created": "2026-08-07"},
    ],
}
(OUT / f"{SLUG}.hub.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2))
print(f"HTML     -> {OUT}/{SLUG}.html")
print(f"manifest -> {OUT}/{SLUG}.hub.json")
