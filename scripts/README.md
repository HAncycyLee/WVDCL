# Fact Check Tools API 小批采集

采集脚本：`collect_factcheck_sample.ps1`。需要PowerShell 7或更高版本，无须安装Python或第三方包。

这是已完成小批采集所用脚本的可复用版本。默认配置最多6次请求、每次10条，不翻页、不重试；请求失败、认证失败或限流均保存状态，401/403/429或网络失败时停止。不会下载核查文章全文或社交平台帖子，不生成真假标签。

## 1. 准备本地密钥

在Google Cloud项目中启用Fact Check Tools API，并创建限制为该API的密钥。参考[Google官方说明](https://developers.google.com/fact-check/tools/api/)。

在仓库根目录首次创建本地配置，以下命令不会覆盖已有密钥文件：

```powershell
if (-not (Test-Path -LiteralPath '.env')) {
    Copy-Item -LiteralPath '.env.example' -Destination '.env'
}
```

编辑`.env`，将占位值替换为真实密钥：

```dotenv
GOOGLE_FACTCHECK_API_KEY=replace_with_your_google_factcheck_api_key
```

真实密钥仅保存在本地`.env`。该文件被Git忽略；不要放进查询JSON、命令行或提交记录。脚本通过请求头传递密钥，不把它放进请求URL，也不将请求头写入日志。

## 2. 先离线检查

在仓库根目录运行：

```powershell
pwsh -NoProfile -File ./scripts/collect_factcheck_sample.ps1 -ValidateOnly
```

该模式只检查查询配置和运行目录，不读取密钥、不调用API、不创建采集目录。成功时输出`plan_valid: true`、`requests_sent: 0`。

## 3. 执行小批采集

```powershell
pwsh -NoProfile -File ./scripts/collect_factcheck_sample.ps1
```

默认读取`configs/factcheck.sample.example.json`，生成带UTC时间与随机后缀的新运行ID。配置包含两个英文核查来源、两个英文关键词和两个中文关键词，仅作数据探查示例。

可以指定自己的配置与运行ID：

```powershell
pwsh -NoProfile -File ./scripts/collect_factcheck_sample.ps1 -PlanPath ./configs/factcheck.sample.example.json -RunId sample-001
```

每个运行ID只能使用一次。已有输出目录时脚本拒绝执行，防止覆盖数据或重复调用。固定上限为6次请求、每页10条；修改关键词时仍需满足这些限制。

## 4. 产物

- `data/raw/<运行ID>/<查询ID>.json`：各次请求的原始响应正文。
- `outputs/<运行ID>/run-plan.json`：本次查询和限制。
- `outputs/<运行ID>/requests.jsonl`：状态、参数、返回数、响应SHA256及失败信息。
- `outputs/<运行ID>/collection-summary.json`：总请求数、成功/失败数和主张出现记录数。

这些目录的生成内容默认不进入Git。当前脚本只采集JSON并记录请求，不生成CSV，也不做语义去重或人工标注。API原评级和日期需后续核验，语言过滤参数不等于主张正文语言；检索结果不是完整事件总体。

## 5. 离线验证

```powershell
pwsh -NoProfile -File ./tests/test-collect-factcheck-sample.ps1
```

检查配置上限、分页禁止、重复/不安全查询ID、非官方服务地址和已存在运行目录；不使用真实密钥、不发外部API请求。测试产物写入被忽略的`outputs/`目录。
