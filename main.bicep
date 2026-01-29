@description('Azure region for deployment')
param location string = resourceGroup().location

@description('VM name (lowercase letters, numbers, and hyphens)')
param vmName string = 'ghrunner-ubuntu'

@description('VM size')
param vmSize string = 'Standard_DS2_v2'

@description('Admin username for the VM')
param adminUsername string = 'azureuser'

@description('SSH public key for the admin user (e.g., from ~/.ssh/id_rsa.pub)')
@secure()
param adminSshPublicKey string

@description('Whether to create/attach a public IP for the VM (for SSH). If false, VM will be private only.')
param enablePublicIp bool = true

@description('CIDR(s) allowed to SSH (comma-separated). Ignored if enablePublicIp=false. Use cautiously.')
param sshAllowCidrs array = [
  '0.0.0.0/0'
]

@description('Name of the VNet to create')
param vnetName string = '${vmName}-vnet'

@description('Address prefix for VNet')
param vnetAddressPrefix string = '10.10.0.0/16'

@description('Subnet name')
param subnetName string = 'default'

@description('Address prefix for subnet')
param subnetAddressPrefix string = '10.10.1.0/24'

@description('Labels to apply to the GitHub runner (comma-separated string).')
param runnerLabels string = 'self-hosted,linux,x64,azure'

@description('GitHub scope URL for the runner (repo or org). Example (repo): https://github.com/your-org/your-repo  Example (org): https://github.com/your-org')
param githubScopeUrl string

@description('GitHub registration token for the scope above. Use a short-lived registration token, NOT a PAT.')
@secure()
param githubRunnerRegistrationToken string

@description('Set to true to install GitHub Actions runner on the VM via cloud-init.')
param installGithubRunner bool = true

@description('Runner working directory on the VM')
param runnerWorkDir string = '/actions-runner/_work'

@description('Ubuntu image definition')
param imagePublisher string = 'Canonical'
@description('Offer for Ubuntu LTS')
param imageOffer string = '0001-com-ubuntu-server-jammy'
@description('SKU for Ubuntu LTS')
param imageSku string = '22_04-lts'
@description('Version for Ubuntu image')
param imageVersion string = 'latest'

var nsgName = '${vmName}-nsg'
var pipName = '${vmName}-pip'
var nicName = '${vmName}-nic'
var vmComputerName = vmName

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: subnetAddressPrefix
          networkSecurityGroup: {
            id: nsg.id
          }
        }
      }
    ]
  }
}

resource nsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: nsgName
  location: location
  properties: {
    securityRules: [
      // SSH inbound (optional via public IP)
      for (cidr, i) in sshAllowCidrs: {
        name: 'Allow-SSH-${i}'
        properties: {
          priority: 100 + i
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: cidr
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
        }
      }
    ]
  }
}

resource publicIp 'Microsoft.Network/publicIPAddresses@2023-11-01' = if (enablePublicIp) {
  name: pipName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: nicName
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: enablePublicIp ? {
            id: publicIp.id
          } : null
          subnet: {
            id: vnet.properties.subnets[0].id
          }
        }
      }
    ]
  }
}

var cloudInit = '''
#cloud-config
package_update: true
package_upgrade: true
packages:
  - curl
  - jq
  - tar
  - unzip
  - git
  - systemd
users:
  - name: ${adminUsername}
    ssh_authorized_keys:
      - ${adminSshPublicKey}
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
    groups: [adm, sudo]
    shell: /bin/bash

write_files:
  - path: /opt/ghrunner-install.sh
    permissions: '0755'
    owner: root:root
    content: |
      #!/usr/bin/env bash
      set -euo pipefail

      RUNNER_VERSION="2.319.1"
      RUNNER_DIR="/actions-runner"
      WORK_DIR="${runnerWorkDir}"
      LABELS="${runnerLabels}"
      SCOPE_URL="${githubScopeUrl}"
      REG_TOKEN="${githubRunnerRegistrationToken}"

      if [[ -z "$SCOPE_URL" || -z "$REG_TOKEN" ]]; then
        echo "Missing SCOPE_URL or REG_TOKEN"; exit 1
      fi

      mkdir -p "$RUNNER_DIR" "$WORK_DIR"
      cd "$RUNNER_DIR"

      arch=$(uname -m)
      case "$arch" in
        x86_64) pkg="actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz" ;;
        aarch64) pkg="actions-runner-linux-arm64-${RUNNER_VERSION}.tar.gz" ;;
        *) echo "Unsupported arch: $arch"; exit 1 ;;
      esac

      curl -fSL -o $pkg https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/$pkg
      tar xzf $pkg
      rm -f $pkg

      ./bin/installdependencies.sh

      # Configure runner (ephemeral = false by default; set as needed)
      ./config.sh --unattended \
        --url "$SCOPE_URL" \
        --token "$REG_TOKEN" \
        --labels "$LABELS" \
        --work "$WORK_DIR" \
        --replace

      # Install as a service and start
      ./svc.sh install
      ./svc.sh start

runcmd:
  - [ bash, -c, "/opt/ghrunner-install.sh > /var/log/ghrunner-install.log 2>&1" ]
'''

resource vm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: vmName
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: vmComputerName
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: adminSshPublicKey
            }
          ]
        }
      }
      // cloud-init via customData (base64)
      customData: base64(cloudInit)
    }
    storageProfile: {
      imageReference: {
        publisher: imagePublisher
        offer: imageOffer
        sku: imageSku
        version: imageVersion
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
        diskSizeGB: 64
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
  }
  identity: {
    type: 'SystemAssigned'
  }
}

@description('Public IP address (if created)')
output publicIpAddress string = enablePublicIp ? publicIp.properties.ipAddress : 'no-public-ip'
@description('Private IP address')
output privateIpAddress string = nic.properties.ipConfigurations[0].properties.privateIPAddress
