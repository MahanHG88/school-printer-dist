# School Printer - download mirror (v1.7.5)

Built files for **https://print.mahanmirzaee.com**, served through jsDelivr so installs are fast where
print.mahanmirzaee.com is slowed down (e.g. inside Iran). Nothing here is secret: it is exactly what the website
publishes. Every installer checks the SHA-256 of each file it downloads.

- Windows (PowerShell): `irm https://cdn.jsdelivr.net/gh/MahanHG88/school-printer-dist@v1.7.5/install-ir.ps1 | iex`
- macOS / Linux: `curl -fsSL https://cdn.jsdelivr.net/gh/MahanHG88/school-printer-dist@v1.7.5/install-ir.sh | sudo bash`

`app/web/pdf*.js` is pdf.js by Mozilla (Apache-2.0), included unmodified.
