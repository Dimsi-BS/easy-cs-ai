# Apache CloudStack (integration research)

[← Back to search](../README.md)

**Role:** the cloud the [CloudStack integration](../../docs/spec-cloudstack.md) targets. **License:** Apache 2.0. Unlike the other findings, CloudStack is not a component the project installs: these notes check **how the page and the monitoring of the spec can be built on it**.

Research done on **2026-11-06**, from the CloudStack documentation (`latest`, which is ahead of the 4.22 release), the API reference of 4.20 and 4.22, and the `main` branch of `apache/cloudstack`. **No CloudStack instance was run**: everything below is read, not tried. Each note says what was **not** confirmed; those are the first things to test on a real instance (see [what to try first](#what-to-try-first)).

## Notes

| Note | Question |
| --- | --- |
| [UI extension](ui-extension.md) | How can a page be added to the CloudStack UI, and how does it authenticate? |
| [API and resources](api-resources.md) | User-data, tags, annotations, metrics, networks, GPU and compute offerings |
| [Guest and templates](guest-and-templates.md) | cloud-init templates, running a script at first boot, and whether a VM can report to CloudStack |

## What this changes in the spec

| Premise of the spec | Found |
| --- | --- |
| A UI plugin mechanism may exist | **Yes, a simple one**: `plugins` in the UI's `config.json` shows an HTML page or any URL in an **iframe**, no rebuild. No postMessage, no session handed over; what the iframe can read of the user's session is unconfirmed. A real Vue page needs a build of the UI (a fork-like change) |
| Tags to mark the resources | **Yes**, `createTags`, on VMs, volumes, networks, security groups, firewall and port-forwarding rules, public IPs, and more. Service offerings and NICs are not taggable. Key and value limits **not confirmed** |
| The size limit of the user-data is 32 KB | **After base64**, so about **24 KB of script**, not 32. Over HTTP GET only a few KB pass: the page needs POST |
| A stored user-data could hold the configuration | `registerUserData` exists (4.18), and **annotations** can be attached to a `USER_DATA`, a VM, an SSH key pair… Both are candidates; neither is tested |
| The VM cannot report to CloudStack | **Confirmed as far as read**: no guest-to-cloud channel found, metrics come from the hypervisor. The [status document](../../docs/spec-cloudstack.md#the-status-document) read by a service stays the way to see inside a VM |
| CloudStack metrics of a VM through the API | `listVirtualMachinesMetrics` and `listVirtualMachinesUsageHistory` (CPU, memory, disk, network); **12 hours** of history by default, collected every minute |
| GPU compute offerings | In the **service offering** (GPU card, profile, count), KVM; `deployVirtualMachine` has no GPU parameter |
| Ubuntu 24.04 cloud-init templates | The CloudStack project publishes cloud images, and the docs explain how to enable the CloudStack datasource; but cloud-init support is **"not supported by the community"**, in the docs' words |

## What to try first

On a CloudStack 4.21 or later test instance, in this order, because each result can change the architecture:

1. A `plugins` entry pointing at a page served from the management server's webapp directory: does the page see the user's session (`sessionkey` cookie) and may it call `/client/api` itself? This decides whether the page needs its own authentication ([open question of the spec](../../docs/spec-cloudstack.md#open-questions)).
2. `deployVirtualMachine` by POST with a shell script of about 24 KB as user-data on an Ubuntu 24.04 cloud image: does it run at first boot, with what encoding (bare script or MIME)?
3. Tag key and value limits, and annotations on a `USER_DATA` (size, who may call).
4. `listVirtualMachinesMetrics` and the usage history on a KVM VM: the memory figures, and whether the guest agent is needed for them.
5. Reachability of port 443 on each kind of network the target cloud uses.
