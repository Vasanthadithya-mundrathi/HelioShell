# HelioShell

An AI-powered terminal intelligence shell that converts natural language into shell commands.

## Features

- **AI Command Generation** - Convert plain English to shell commands using Cerebras (Llama 3.1 8B) or Google Gemini (3.0 Flash)
- **Smart Tool Detection** - Detects 60+ installed tools (nmap, curl, masscan, etc.) and only suggests available commands
- **Multiple Modes** - `shell`, `recon`, `exploit`, `chat`, `code` for different use cases
- **Safety First** - Destructive command detection, confirmation prompts, secure config storage

## Requirements

- bash 4.0+
- python3
- curl
- API key (Cerebras or Google Gemini)

## Quick Start

```bash
./helio.sh --provider cerebras --api YOUR_API_KEY
# or
./helio.sh --provider gemini --api YOUR_API_KEY
```

Then just type natural language commands:
- `find MX records for example.com`
- `use recon` then `scan this domain`
- `heliocode fix this Python error`

## Installation

```bash
chmod +x helio.sh
./helio.sh --install-man          # install man page
ln -s $(pwd)/helio.sh /usr/local/bin/helio  # optional: link to PATH
```

## Modes

| Mode    | Description                        |
|--------|-------------------------------------|
| default | Smart intent detection             |
| shell  | Precise bash/Linux commands         |
| recon  | Passive-first reconnaissance         |
| exploit| Authorized security testing      |
| chat   | Concept explanations              |
| code   | Code writing, debugging, refactoring|

## API Providers

- **Cerebras**: https://cloud.cerebras.ai/
- **Google Gemini**: https://aistudio.google.com/app/apikey

## STATUS

completed full test on cerebras needs to test on gemini API . 

## Authors

Mundrathi Vasanthadithya & Yedla Sai Geethika
## License

MIT
