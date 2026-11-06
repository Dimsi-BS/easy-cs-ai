# CloudStack: templates, first-boot script, and the guest

[← Back to CloudStack](README.md)

Read on 2026-11-06 (docs `latest`, download.cloudstack.org, cloud-init documentation). No instance run.

## Templates and cloud-init

- The admin guide explains how to prepare a template: install `cloud-init`, then `/etc/cloud/cloud.cfg.d/99_cloudstack.cfg` with `datasource_list: [ ConfigDrive, CloudStack, None ]`; password and SSH key reset need `set_passwords` and `ssh` set to `always`.
- It also carries, in the user-data section, this disclaimer: "cloud-init and the cloud-init CloudStack datasource are not supported by Apache CloudStack community." Cloud-init is the project's way to run the post-install script, so the documentation does not back it: **a risk to state, not a blocker**, since the same page says cloud-init "can parse and execute User Data from CloudStack ... as is".
- cloud-init's own datasource page: CloudStack exposes user-data, meta-data, password and SSH key "through the virtual router", at `http://data-server./latest/user-data`; the router is found by the `data-server` host name, then the DHCP lease, then the default gateway; defaults `max_wait` 120 s, `timeout` 50 s.
- **Images**: `download.cloudstack.org/templates/cloud-images/` has `ubuntu/` (with `ubuntu-24.04-server-cloudimg-amd64.img`) and `debian/`; `download.cloudstack.org/templates/debian-13-genericcloud-amd64/` has a qcow2 built by a script of the project (`build-acs-image.sh`, with `SHA512SUMS`) that writes the CloudStack datasource configuration and installs the QEMU guest agent and open-vm-tools. That script sets a default root password (`password`, overridable) and `PermitRootLogin yes`: **an image from there must not be used as is**, and the Ubuntu one was not inspected (format, datasource, patches). Whether the upstream Ubuntu cloud image ships the CloudStack datasource was **not checked**.
- Registering a template is the cloud operator's job: the page **lists** the templates the account may use, it does not import one ([spec](../../docs/spec-cloudstack.md#mapping-to-cloudstack-resources)).

## A shell script as user-data

- cloud-init runs a user-data that starts with `#!` once per instance (in the `scripts-user` stage); for every boot it takes a MIME part `text/x-shellscript-per-boot`.
- CloudStack's side: the UI base64-encodes; the API `userdata` must be, according to the admin guide, "a base64-encoded multi-part MIME message". **Not confirmed**: whether a bare `#!/bin/bash` script, base64-encoded, is accepted and delivered intact. If a MIME wrapper is needed, **the generator's script is the same, wrapped**, and the size budget is a little smaller ([API note](api-resources.md#user-data)).
- Not read: the router's wire format for the user-data (decoded or not).

## Can a VM report to CloudStack?

- The password flow is **guest pull**: the template script calls the virtual router.
- The 4.22 API list shows VM commands to read or reset the user-data, the password and the SSH key, and metrics, but **no guest-agent or guest-reporting command** (the list was read through a summary, so partial). CloudStack's metrics come from the hypervisor (libvirt on KVM).
- So nothing found lets a VM write its state in CloudStack, which supports the [status document read by a service](../../docs/spec-cloudstack.md#reading-the-vms). The QEMU guest agent in the Debian image is for the hypervisor's use, not an API for this project.

## Existing work on AI on CloudStack

- ShapeBlue, "AI, VDI and GPUaaS: Rethinking Infrastructure with Apache CloudStack" (2026-06-22): conceptual, names no LLM stack.
- `createKubernetesCluster` (4.22) takes `nodeofferings` and `nodetemplates` and lists no GPU parameter; running a GPU offering through it is an inference, not tested.
- **No community project that deploys a local-AI stack on CloudStack was found** (GitHub was not searched).

## Not confirmed

The Ubuntu image's datasource; the router's wire format; a bare script versus MIME through the API; the version that added the CloudStack datasource to cloud-init; the 4.23 release notes (not read).

## Sources

- [Templates: cloud-init, admin guide](https://docs.cloudstack.apache.org/en/latest/adminguide/templates/_cloud_init.html)
- [User data and metadata, admin guide](https://docs.cloudstack.apache.org/en/latest/adminguide/virtual_machines.html)
- [cloud-init: CloudStack datasource](https://docs.cloud-init.io/en/latest/reference/datasources/cloudstack.html)
- [cloud-init: user-data scripts](https://docs.cloud-init.io/en/latest/explanation/format/user-data-script.html)
- [CloudStack cloud images](https://download.cloudstack.org/templates/cloud-images/), [Debian 13 template build](https://download.cloudstack.org/templates/debian-13-genericcloud-amd64/)
- [Password management in templates](https://docs.cloudstack.apache.org/en/latest/adminguide/templates/_password.html)
- [API reference 4.22](https://cloudstack.apache.org/api/apidocs-4.22/)
- [ShapeBlue: AI, VDI and GPUaaS](https://www.shapeblue.com/ai-vdi-and-gpuaas-rethinking-infrastructure-with-apache-cloudstack/)
