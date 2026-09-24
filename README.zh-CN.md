<div align="center">

[English](README.md)

<h1><img src="./pic/logo/readme-logo.png" alt="Scivane 标志" width="54" height="54" align="absmiddle" />&nbsp;&nbsp;Scivane</h1>

**你的 AI 论文阅读智能体**

[![macOS](https://img.shields.io/badge/macOS-Apple%20Silicon-111111.svg)](#开始使用)
[![界面](https://img.shields.io/badge/界面-中文%20%2F%20English-1f4d3a.svg)](#开始使用)
[![LLM API](https://img.shields.io/badge/LLM%20API-OpenAI%20·%20Anthropic%20·%20Gemini-111111.svg)](#开始使用)
[![License: AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-111111.svg)](LICENSE)


</div>

---

## Scivane：

你的 AI 论文阅读智能体。Scivane 以论文为中心，将文献阅读、AI 交互与研究工具整合于一体，让阅读与思考始终围绕原文展开。Agent 不仅能够结合论文上下文进行深入分析，还能自主检索相关文献、获取开源代码并辅助理解，让每一篇论文都成为可以持续探索的独立研究项目。

---

## 你会用它做的事

- **在本机读完论文。** PDF 和图片在这台 Mac 上整理成正文。阅读组件按需安装，不装也能导入 Markdown、阅读和提问。
- **对着这一篇提问。** 模型看到的是已经整理好的正文，章节、表格和公式还在，讨论和你正在看的是同一份材料。
- **在这篇里把事做完。** 改正文、把论文代码取下来、用表格数据作图，结果留在这个项目里。
- **改动留在这一篇里。** 查资料可以走网络。项目目录以外的文件不会被改。

---

## 开始使用

需要 Apple 芯片的 Mac，以及 Xcode 命令行工具（用来编译）。

```bash
git clone https://github.com/akatsuky999/Scivane-macos.git
cd Scivane
make app
```

打开桌面上的 `Scivane.app`。第一次打包会下载 App 自带的 Python，体积不大。若系统拦住未签名的应用，在访达里对它右键，选择「打开」。

然后做三件事：

1. 在设置里填上你自己的模型。支持常见的对话接口，密钥留在这台 Mac 的钥匙串里。
2. 导入一篇 PDF，或直接打开已有的 Markdown。
3. 要识别 PDF 时，按 App 里的提示装上本地阅读组件（大约 2 GB，装一次）。不装，阅读和问答照常。

---

## 读一篇论文

导入之后先建成项目，再确认正文。确认过的正文才会参与问答，避免模型拿着一份不对的稿子作答。

打开项目里的一段对话，就可以问这一篇。需要动手时，让它改 Markdown、把代码放到项目里，或把表里的数字画成图。侧栏里每篇论文各自独立，互不混在一起。

---

## 现在的边界

- 只提供 Apple 芯片上的 macOS 应用。仓库给的是源码，用 `make app` 打到桌面。
- 模型由你自己提供。提问会把这篇的正文发给你填写的服务，请先看那家的隐私条款。
- 能做的事集中在这一篇：阅读、改正文、取代码、作图。

---

## 许可证

Scivane 以 [GNU AGPL-3.0](LICENSE) 发布。阅读 PDF 用的是 PyMuPDF，它以 AGPL-3.0 提供，所以本程序也用这一许可。
