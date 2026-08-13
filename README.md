# Infermion CLI Releases

This repository is the public distribution home for the Infermion CLI and TUI. It contains
generated installer channels, release metadata, checksums, SBOMs, Sigstore bundles, portable SLSA
provenance, and links to native release artifacts for macOS, Linux, and Windows.

The Infermion platform source repository remains private and is not mirrored here.

## Install

For macOS or Linux:

```bash
curl -fsSL https://www.infermion.com/install | sh
```

For Windows PowerShell:

```powershell
irm https://www.infermion.com/install.ps1 | iex
```

The default installer selects the latest stable release. Before the first stable release, it
selects the latest beta and clearly identifies it as a beta installation.

Repository contents are generated and updated by Infermion's protected release workflow.
