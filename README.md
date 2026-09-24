<div align="center">
<h1><img src="./pic/logo/readme-logo.png" alt="Scivane Logo" width="54" height="54" align="absmiddle" />&nbsp;&nbsp;Scivane</h1>

**Your AI Agent for Research Paper Reading**

[![macOS](https://img.shields.io/badge/macOS-Apple%20Silicon-111111.svg)](#getting-started)
[![Language](https://img.shields.io/badge/Language-中文%20%2F%20English-1f4d3a.svg)](#getting-started)
[![LLM API](https://img.shields.io/badge/LLM%20API-OpenAI%20·%20Anthropic%20·%20Gemini-111111.svg)](#getting-started)
[![License: AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-111111.svg)](LICENSE)

</div>

---

## About Scivane

Scivane is your AI agent for reading research papers. By bringing paper reading, AI interaction, and research tools together in one place, it keeps your reading and exploration closely connected to the original text. Beyond answering questions and analyzing papers in context, the agent can independently search for related literature, retrieve open-source code, and help you understand the underlying methods, turning each paper into a dedicated research project you can continue to explore.

![Scivane app preview](./pic/readme-app.png)

## Getting Started

Scivane requires a Mac with Apple Silicon and the Xcode Command Line Tools for building the application.

```bash
git clone https://github.com/akatsuky999/Scivane-macos.git
cd Scivane-macos
make app
```

## Setup Guide

Scivane doesn't ship a prebuilt installer, so you build it once on your own Mac. You need an Apple Silicon Mac (M1 or later), macOS 14 or later, and a network that can reach GitHub.

### 1 · Install the Command Line Tools

Open **Terminal**, run the command below, and click **Install** in the dialog. You only need the Command Line Tools, not the full Xcode.

```bash
xcode-select --install
```

### 2 · Build

```bash
git clone https://github.com/akatsuky999/Scivane-macos.git
cd Scivane-macos
make app
```

When you see `完成 → …/Desktop/Scivane.app` (“完成” means “done”), the app is on your Desktop.

### 3 · Add an API Key

Open Scivane, press <kbd>⌘</kbd> <kbd>,</kbd>, and go to **Models**. The app comes with three cards: OpenRouter, DeepSeek, and OpenAI. Expand one, paste your API key, click **Save Key** and **Test Connection**, then click the circle on the left of the card to make it the default.

For Claude or Gemini, click **＋ New Card** → **Custom**, choose the Anthropic or Google Gemini protocol, and use `https://api.anthropic.com` or `https://generativelanguage.googleapis.com` as the base URL.

### 4 · Local OCR (Optional)

You only need it to convert PDFs into Markdown. The first time you click **Start OCR**, follow the prompt to install it (about a 2.2 GB download).

### Updating

Quit Scivane, then run:

```bash
cd ~/Scivane-macos && git pull && make app
```

### Troubleshooting

- **Slow downloads or network errors**: Terminal needs to reach GitHub and PyPI. If you use a proxy, run `export https_proxy=http://127.0.0.1:<port>` first, then run `make app` again.
- **The error mentions `Swift tools version 6.0`**: your Command Line Tools are too old. Update them in System Settings → General → Software Update.
- **The build stops with `请先退出 Scivane 再打包`** (“quit Scivane before building”): press <kbd>⌘</kbd> <kbd>Q</kbd> to quit the app, then try again.

## License

Scivane is released under the [GNU AGPL-3.0](LICENSE) license. It uses PyMuPDF for PDF processing, which is also distributed under the AGPL-3.0 license.

---


[简体中文](README.zh-CN.md)

