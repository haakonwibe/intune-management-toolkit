# App Dependency Manager (Azure Function)

🛠️ An Azure Function App to manage application dependencies for Intune device assignments.

## 📄 Files

- **run.ps1**  
  Main function logic that handles incoming requests and manages app dependency operations.

- **requirements.psd1**  
  Lists the required PowerShell modules for the Function App runtime.

- **host.json**  
  Configuration settings for the Azure Functions runtime (version, extension bundles, and managed dependencies).

## ⚙️ Usage

- Deploy the folder contents as an Azure PowerShell Function App
- Ensure that the required modules specified in `requirements.psd1` are available
- Customize `run.ps1` to fit specific dependency management needs
- Azure-managed dependencies are enabled in `host.json`

## 🔒 License

MIT — free to use, modify, and share.
