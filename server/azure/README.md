# Azure VM Public IP Rotation Runbook

This PowerShell script is designed to be used as a runbook in an Azure Automation Account. Its purpose is to rotate the public IP address of a virtual machine by detaching and deleting the old public IP, creating a new one, and attaching it to the VM's network interface.

## Prerequisites

Before running this script, you must configure the necessary permissions for the Azure Automation Account.

### Assign Network Contributor Role

The Automation Account's managed identity needs permissions to manage network resources within the target resource group.

1.  Navigate to the **Resource Group** in the Azure portal that contains your VM and network interfaces.
2.  Go to **Access control (IAM)**.
3.  Click **Add** > **Add role assignment**.
4.  Select the **Network Contributor** role.
5.  In the **Members** tab, select `Managed identity` and then click **Select members**.
6.  Choose your subscription and then select the **Automation Account** you will use to run the script.
7.  Click **Review + assign** to grant the permissions.

## Usage in Azure Automation

1.  **Create a Runbook:** In your Automation Account, create a new PowerShell runbook.
2.  **Add Script Content:** Copy the content of `azure-update-pip.ps1` and paste it into the runbook editor.
3.  **Customize Variables:** Before running, update the variables at the beginning of the script (`$rgName`, `$vmName`, `$nicName`, etc.) to match your specific Azure resource names.
4.  **Publish:** Save and publish the runbook.
5.  **Schedule (Optional):** To run this script periodically, you can add a schedule to the runbook from the "Schedules" section of the runbook's resources. This is useful for rotating the IP on a regular basis.

## Script Parameters

The script is currently configured with hardcoded variables. You will need to modify these directly in the script to match your environment:

*   `$rgName`: The name of the resource group.
*   `$vmName`: The name of the virtual machine.
*   `$nicName`: The name of the network interface.
*   `$pipName`: The name of the public IP address resource.
*   `$vnetName`: The name of the virtual network.
*   `$vsubnetName`: The name of the subnet.
*   `$ipconfigName`: The name of the IP configuration on the NIC.
*   `$location`: The Azure region where the resources are located.
