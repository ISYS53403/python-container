@description('The name of the Managed Cluster resource.')
param clusterName string = 'flaskAppAKS'

@description('The location of the Managed Cluster resource.')
param location string = resourceGroup().location

@description('Optional DNS prefix to use with hosted Kubernetes API server FQDN.')
param dnsPrefix string = 'flaskapp'

@description('Disk size (in GB) to provision for each of the agent pool nodes. This value ranges from 0 to 1023. Specifying 0 will apply the default disk size for that agentVMSize.')
@minValue(0)
@maxValue(1023)
param osDiskSizeGB int = 0

@description('The number of nodes for the cluster.')
@minValue(1)
@maxValue(50)
param agentCount int = 3

@description('The size of the Virtual Machine.')
param agentVMSize string = 'Standard_D2s_v3'

@description('User name for the Linux Virtual Machines.')
param linuxAdminUsername string = 'azureuser'

@description('Configure all linux machines with the SSH RSA public key string. Your key should include three parts: "ssh-rsa AAAAB3Nz..snip...UcyupgH azureuser@linuxvm"')
param sshRSAPublicKey string

@description('The name of the ACR resource.')
param acrName string = 'flaskappacr${uniqueString(resourceGroup().id)}'

@description('The DNS zone name for your application')
param dnsZoneName string = 'flask-app-demo.com'

@description('The hostname for your Flask application')
param appHostname string = 'flask-app'

@description('Enable addon for http application routing')
param httpApplicationRoutingEnabled bool = true

// Azure Container Registry
resource acr 'Microsoft.ContainerRegistry/registries@2021-09-01' = {
  name: acrName
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: true
  }
}

// Define DNS Zone
resource dnsZone 'Microsoft.Network/dnsZones@2018-05-01' = {
  name: dnsZoneName
  location: 'global'
  properties: {}
}

// AKS Cluster with HTTP Application Routing Add-on
resource aks 'Microsoft.ContainerService/managedClusters@2022-06-01' = {
  name: clusterName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    dnsPrefix: dnsPrefix
    agentPoolProfiles: [
      {
        name: 'agentpool'
        osDiskSizeGB: osDiskSizeGB
        count: agentCount
        vmSize: agentVMSize
        osType: 'Linux'
        mode: 'System'
      }
    ]
    linuxProfile: {
      adminUsername: linuxAdminUsername
      ssh: {
        publicKeys: [
          {
            keyData: sshRSAPublicKey
          }
        ]
      }
    }
    addonProfiles: {
      httpApplicationRouting: {
        enabled: httpApplicationRoutingEnabled
      }
    }
    networkProfile: {
      loadBalancerSku: 'standard'
      networkPlugin: 'kubenet'
    }
  }
}

// Give AKS access to pull images from ACR
resource acrPullRole 'Microsoft.Authorization/roleAssignments@2020-04-01-preview' = {
  name: guid(resourceGroup().id, aks.id, 'acrpull')
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '7f951dda-4ed3-4680-a7ca-43fe172d538d'
    ) // ACR Pull role
    principalId: aks.properties.identityProfile.kubeletidentity.objectId
    principalType: 'ServicePrincipal'
  }
  scope: acr
}

// We removed the DNS A record here because we can't directly link it to the AKS cluster
// The DNS records will be managed by either:
// 1. The HTTP Application Routing addon (automatically)
// 2. ExternalDNS controller (installed after deployment)

output controlPlaneFQDN string = aks.properties.fqdn
output acrLoginServer string = acr.properties.loginServer
output applicationDnsName string = '${appHostname}.${dnsZoneName}'
output httpApplicationRoutingZone string = httpApplicationRoutingEnabled
  ? aks.properties.addonProfiles.httpApplicationRouting.config.HTTPApplicationRoutingZoneName
  : ''
