# SecurePaq Central Manager

A centralized web-based management tool for HP computer updates on a Local Area Network (LAN).

## Features
- **Centralized Web Dashboard:** Monitor multiple HP systems from a single web interface.
- **Remote Inventory:** Automatically discover Model, Serial, Platform ID, and BIOS versions of remote machines.
- **Update Discovery:** Identify available BIOS and SoftPaq updates (Firmware, Drivers) for each platform.
- **Remote Deployment:** Deploy updates to remote systems using HP CMSL and WMI.
- **Modern UI:** Built with web technologies giving a clean, professional dark-mode experience.
- **Installer:** Comes with an Inno Setup script for easy standalone deployment.

## Repository Structure
- `scripts/`: The main PowerShell web server application, frontend assets (`public/`), and installer configuration.
- `Modules/`: Required HP CMSL PowerShell modules.

## Getting Started
Run `build.ps1` inside the `scripts` folder to generate the `securepaq-web-server.exe` daemon and create a final deployment installer using Inno Setup.
