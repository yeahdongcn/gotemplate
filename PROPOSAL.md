# 项目申报书：gotemplate

MoonBit 黑客松 2026 · 11 月赛 · 新项目申报

- 仓库：<https://github.com/yeahdongcn/gotemplate>
- 许可证：Apache-2.0
- 申报人 GitHub：[@yeahdongcn](https://github.com/yeahdongcn)

## 项目简介

Go 标准库 `text/template` 模板语言的 MoonBit 实现。Helm、`kubectl -o go-template`、`docker --format`、Prometheus 告警模板用的都是这套语法。有了它，MoonBit 写的命令行工具和云原生组件可以直接复用用户已经熟悉的模板。

## 为什么选这个题

- **生态里没有。** 2026-11-11 检索了 mooncakes.io 上全部 3,725 个模块：Jinja 风格（minijinja、moonjinja）、Pug、Tera 风格的模板引擎都已存在，Go 模板、Helm、sprig 相关的一个都没有。
- **需求真实。** Go 模板是云原生工具链的通用配置语言。MoonBit 生态里已经有 Kubernetes 客户端、OCI 镜像工具和 Compose 实现，渲染这类模板是自然的下一步。
- **可以客观验收。** 语义由 Go 官方文档定义，并且有参考实现可以逐条对照，“做得对不对”不靠主观判断。

## 现在做到哪了（v0.1.0）

- 文本、动作、注释，`{{-` 和 `-}}` 的空白裁剪。
- 管道、变量声明与赋值、`$`、字段链、括号表达式。
- 字面量：布尔、整数（十进制、十六进制、八进制、二进制、下划线）、浮点数（含十六进制浮点）、字符、字符串、原始字符串、`nil`。
- `if` / `else if` / `else`，`with` / `else with`，`range`（列表、按键排序的映射、整数，支持 `break` 和 `continue`）。
- `define`、`template`、`block`。
- 全部内置函数：`and`、`or`、`not`、`len`、`index`、`slice`、`print`、`printf`、`println`、`html`、`js`、`urlquery`、`eq`、`ne`、`lt`、`le`、`gt`、`ge`。
- `printf` 的动词、标志、宽度和精度；浮点数按 Go 的方式精确舍入。
- 自定义函数，以及 Go 的 `missingkey=error` 选项。
- 带行号的解析错误，以及执行错误。

纯 MoonBit 实现，不用 FFI，在 `wasm`、`wasm-gc`、`js`、`native` 四个后端上测试通过。

## 怎么验证的

仓库里的 `tools/oracle` 是一个小的 Go 程序。它把 `tools/oracle/cases/*.jsonl` 里的每个用例（一段模板加一份 JSON 数据）交给真实的 `text/template` 执行，记录 Go 是报解析错误、报执行错误，还是输出了什么。MoonBit 的测试重放同一批用例，要求结果一致。

- 现有 1118 条用例，与 Go 1.27 全部一致。
- 另有 7 条与 Go 有意不同的行为，单独放在 `known-differences.jsonl`，README 的“Differences from Go”一节逐条说明。测试会确认它们仍然不同，清单不会过期。
- CI 在每次推送时检查编译警告和格式，在四个后端上跑测试，并用 Go 重新生成期望结果，与仓库里提交的不一致就失败。
- 出错的用例只比较错误的类别（解析错误还是执行错误），错误信息的措辞没有逐字对照。

## 11 月剩下的计划

| 内容 | 验收方式 |
| --- | --- |
| 发布到 mooncakes.io | 能用 `moon add yeahdongcn/gotemplate` 安装 |
| 常用的 sprig 函数子集（字符串、默认值、列表、字典等），放在独立的子包里 | 用真实的 sprig 库生成期望结果，逐条对照 |
| 一个读入模板文件和 JSON 数据的命令行工具 | 有端到端测试 |
| 把一致性用例补到 1500 条以上，重点是真实的 Helm chart 片段 | CI 通过 |

本期不做：`html/template` 的上下文自动转义；依赖 Go 反射的能力（结构体方法、通道、函数类型的值）。

## AI 使用说明

这个项目的代码、测试和文档主要由 AI 编程助手（Claude）生成，选题也是由它检索生态后提出、由申报人确认的。质量把控的方式是差分测试：每一个行为都要和真实的 Go 对照一致才算完成，对照不一致的改动不会合入。

实现只参考 Go 的公开文档和参考实现的可观察行为，没有包含 Go 的源码。
