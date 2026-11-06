# CloudStack: the API for the resources of a topology

[← Back to CloudStack](README.md)

Read on 2026-11-06: API reference of 4.20 and 4.22 (marked), docs `latest`, source of `main` (its "since" may be newer than 4.20). No instance run.

## User-data

- **Limit.** The global setting `vm.userdata.max.length` defaults to **32768**, described as the "max length of vm userdata **after base64 encoding**", with a maximum of 1048576. A script of N bytes weighs about 4N/3 once encoded, so the default allows roughly **24 KB of script**. The generator [warns at 32 KB](../../docs/spec-vm-generator.md#implementation-notes) of script: the figure is too high for the default setting.
- **HTTP method.** The 4.20 reference for `deployVirtualMachine` says GET carries up to 4 KB and POST up to 1 MB (with the setting raised). The register command and the admin guide give other figures (the guide says GET is limited to 2048 bytes and user-data to 32 KB). Conclusion: use **POST**; the exact figures disagree between pages.
- **Parameters** of `deployVirtualMachine` and `updateVirtualMachine`: `userdata` (base64), `userdataid` (a registered user-data), `userdatadetails` (values of the variables of a registered one). A registered one and an inline one together are refused by the design page.
- **`registerUserData`** (source: since 4.18): `name`, `userdata` (base64), `params`, and the account, domain or project. Reads back with `getVirtualMachineUserData` (base64), and `listVirtualMachines` has a `userdata` boolean (not returned by default). **The user-data of a VM can therefore be read through the API by anyone who may read the VM**, which confirms [the rule of the spec](../../docs/spec-script-contract.md#secrets): no secret in it.
- **Delivery**: saved in the config drive and in the virtual router; the guest reads it from the router at `http://data-server./latest/user-data` only if the User Data service is enabled on the network offering.
- **Format**: the API parameter "must be a base64-encoded multi-part MIME message" according to the admin guide, whereas cloud-init runs a bare `#!` script as the user-data. Whether a bare script passes through the API is **not confirmed**: see [guest and templates](guest-and-templates.md).

## Resource tags

- `createTags`: `resourceids`, `resourcetype`, `tags` (key and value map). `listTags` filters by key, value, resource and account. `deleteTags` takes the resource and, optionally, the tags.
- **Taggable** (`main`): UserVm, Template, ISO, Volume, Snapshot, Network, LoadBalancer, PortForwardingRule, FirewallRule, SecurityGroup, SecurityGroupRule, PublicIpAddress, Vpc, NetworkACL, StaticRoute, VMSnapshot, Project, Account, and more. **Not taggable**: Zone, ServiceOffering, DiskOffering, NetworkOffering, Nic, DomainRouter.
- `listVirtualMachines` filters "by tags (key/value pairs)"; the `tags[0].key=` syntax is not on the page (used by the UI, to confirm).
- **Not confirmed**: maximum length of a key and of a value, and number of tags per resource. They matter for the [tags of the spec](../../docs/spec-cloudstack.md#tags) (short values, no configuration).
- A rule or a network is taggable but a **static NAT** or an **SSH key pair** is not in the list read: the spec's "every resource carries tags" needs a fallback for them (a name convention).

## Annotations

`addAnnotation` (`annotation` text, `entityid`, `entitytype`, `adminsonly`) and `listAnnotations`. Entity types include VM, VOLUME, NETWORK, VPC, PUBLIC_IP_ADDRESS, TEMPLATE, **SSH_KEYPAIR**, **USER_DATA**, INSTANCE_GROUP, KUBERNETES_CLUSTER, ZONE. `adminsonly` makes an annotation visible to admins only (not who may call the API). **Not confirmed:** the size limit of the text, the version, and the roles that may call.

A candidate for [where the configuration lives](../../docs/spec-cloudstack.md#where-a-topology-lives): an annotation on the VMs or on a registered user-data, or the registered user-data itself. Untested.

## VM details

`deployVirtualMachine` and `updateVirtualMachine` take `details` (key and value, `extraconfig` refused). Limits and permitted keys **not confirmed** (the docs mention settings that deny or make read-only some details, from a truncated summary: to verify). A possible place for a short marker; not the configuration.

## Metrics

- `listVirtualMachinesMetrics` (4.22): `cputotal`, `diskiopstotal`, `diskread`, `diskwrite`, `memorytotal`, `networkread`, `networkwrite`; `cpuused` and used memory are **not** in that list.
- `listVirtualMachinesUsageHistory` (4.22): per sample `cpuused` (percentage), `memorykbs`, `memoryintfreekbs` (-1 when it cannot be gathered), `memorytargetkbs`, disk IOPS and kilobytes read and written, network read and written, `timestamp`; filters by VM, `startdate`, `enddate`.
- Collection every **60 s** (`vm.stats.interval`), kept **720 minutes** (`vm.stats.max.retention.time`): **12 hours** of history by default, which sets the horizon of any CloudStack-sourced trend in the page.
- KVM figures come from libvirt (the hypervisor). Whether the memory figure needs guest tools: **not confirmed**. The "RAM used" of the spec's [resources against the plan](../../docs/spec-cloudstack.md#what-it-shows) may be better read from the VM's own status document.

## Networks and reaching 443

| Model | To expose a VM | Calls |
| --- | --- | --- |
| Isolated, NAT (default) | A public IP with a port-forwarding rule, static NAT, or a load balancer; the firewall rule is opened by `openfirewall` (default true, except in VPC tiers) | `createPortForwardingRule` (`ipaddressid`, `privateport`, `publicport`, `protocol`, `virtualmachineid`), `enableStaticNat`, `createFirewallRule` |
| Isolated, routed (4.20) | The virtual router no longer does source NAT, static NAT, load balancing or port forwarding; the firewall remains | `createFirewallRule` |
| Shared, with security groups | Rules on the group (in advanced zones, security groups only on KVM) | `authorizeSecurityGroupIngress` (`securitygroupid`, protocol, ports, `cidrlist`) |
| VPC | Network ACLs on the tier | `createNetworkACL` (VPC only) |

An end user cannot use network offerings with `specifyvlan` (shared networks with a VLAN are the admin's). The role needed for each call is **not stated** in the reference: to check on an instance. Port 443 between two VMs of the **same** network needs no rule on an isolated network and may need one with security groups: kind-dependent, which the spec's [mapping](../../docs/spec-cloudstack.md#mapping-to-cloudstack-resources) already says.

## GPU

The GPU is in the **compute offering**: `createServiceOffering` takes `vgpuprofileid`, `gpucount` (with a profile) and `gpudisplay`; the UI shows GPU card, GPU profile (a vGPU type or passthrough) and count, for KVM. **`deployVirtualMachine` has no GPU parameter**: the user picks the offering. KVM uses libvirt PCI passthrough. Live migration and dynamic scaling are not supported for such an instance. The hypervisor list is contradictory (XenServer and KVM, count for KVM only); the version that brought native KVM GPU support (4.21 per a vendor article) is **not confirmed**. The page can therefore only **list** the GPU offerings of the account and match them to the sizing in GPU memory; the card's memory is in the offering's description, not a field, to check.

## Compute offerings and disk

- Fixed, custom constrained (since 4.13: min and max CPU and RAM) and custom unconstrained offerings. `createServiceOffering` has `customized`, `mincpunumber`, `maxcpunumber`, `minmemory`, `maxmemory`, `rootdisksize`.
- `deployVirtualMachine` has `rootdisksize` (GB, template-based deployments only; "analogous to `details[0].rootdisksize`, which takes precedence") and `overridediskofferingid`. The detail keys for a custom CPU and RAM at deployment are **not confirmed**.

## Sources

- [deployVirtualMachine, 4.20](https://cloudstack.apache.org/api/apidocs-4.20/apis/deployVirtualMachine.html), [4.22](https://cloudstack.apache.org/api/apidocs-4.22/apis/deployVirtualMachine.html)
- [`UserDataManager.java`](https://raw.githubusercontent.com/apache/cloudstack/refs/heads/main/api/src/main/java/org/apache/cloudstack/userdata/UserDataManager.java), [`RegisterUserDataCmd.java`](https://raw.githubusercontent.com/apache/cloudstack/refs/heads/main/api/src/main/java/org/apache/cloudstack/api/command/user/userdata/RegisterUserDataCmd.java)
- [User data and metadata, admin guide](https://docs.cloudstack.apache.org/en/latest/adminguide/virtual_machines.html)
- [getVirtualMachineUserData, 4.20](https://cloudstack.apache.org/api/apidocs-4.20/apis/getVirtualMachineUserData.html)
- [`CreateTagsCmd.java`](https://raw.githubusercontent.com/apache/cloudstack/refs/heads/main/api/src/main/java/org/apache/cloudstack/api/command/user/tag/CreateTagsCmd.java), [`ResourceTag.java`](https://raw.githubusercontent.com/apache/cloudstack/refs/heads/main/api/src/main/java/com/cloud/server/ResourceTag.java), [listTags](https://cloudstack.apache.org/api/apidocs-4.20/apis/listTags.html)
- [addAnnotation, 4.20](https://cloudstack.apache.org/api/apidocs-4.20/apis/addAnnotation.html), [listAnnotations](https://cloudstack.apache.org/api/apidocs-4.20/apis/listAnnotations.html)
- [listVirtualMachinesMetrics, 4.22](https://cloudstack.apache.org/api/apidocs-4.22/apis/listVirtualMachinesMetrics.html), [listVirtualMachinesUsageHistory, 4.22](https://cloudstack.apache.org/api/apidocs-4.22/apis/listVirtualMachinesUsageHistory.html), [instance metrics, admin guide](https://docs.cloudstack.apache.org/en/latest/adminguide/virtual_machines.html#instance-metrics), [`StatsCollector.java`](https://github.com/apache/cloudstack/blob/main/server/src/main/java/com/cloud/server/StatsCollector.java)
- [Networking and traffic, admin guide](https://docs.cloudstack.apache.org/en/latest/adminguide/networking_and_traffic.html), [createFirewallRule](https://cloudstack.apache.org/api/apidocs-4.22/apis/createFirewallRule.html), [createPortForwardingRule](https://cloudstack.apache.org/api/apidocs-4.22/apis/createPortForwardingRule.html), [enableStaticNat](https://cloudstack.apache.org/api/apidocs-4.22/apis/enableStaticNat.html), [authorizeSecurityGroupIngress](https://cloudstack.apache.org/api/apidocs-4.22/apis/authorizeSecurityGroupIngress.html), [createNetworkACL](https://cloudstack.apache.org/api/apidocs-4.22/apis/createNetworkACL.html)
- [createServiceOffering, 4.22](https://cloudstack.apache.org/api/apidocs-4.22/apis/createServiceOffering.html), [service offerings, admin guide](https://docs.cloudstack.apache.org/en/latest/adminguide/service_offerings.html)
