# Source packet

You are given a set of documentation excerpts. Each is printed once, with its
identifier and what metadata is known about it.

## Research question

Assess what these sources actually establish about what is permitted, restricted or required: which restrictions changed, which survived a change and still apply, which exceptions hold only within a named scope, and where a correct answer depends on a source that is no longer current.

---

## 1400190c
product: Kubernetes | version_label: v1.25 | date: 2022-08-25

Changes to the Pod Security Standards

The Pod Security Standards,
which Pod Security admission enforces, have been updated with support for the new Pod OS
field. In v1.25 and later, if you use the Restricted policy, the following Linux-specific restrictions will no
longer be required if you explicitly set the pod's .spec.os.name field to windows:

* Seccomp - The seccompProfile.type field for Pod and container security contexts

* Privilege escalation - The allowPrivilegeEscalation field on container security contexts

* Capabilities - The requirement to drop ALL capabilities in the capabilities field on containers

## 534f6251
product: Kubernetes | version_label: v1.37 / Pod Security Standards | date: 2026-09

Another important change, made in Kubernetes v1.25 is that the Restricted policy
has been updated to use the pod.spec.os.name field. Based on the OS name, certain policies that are specific
to a particular OS can be relaxed for the other OS.

OS-specific policy controls

Restrictions on the following controls are only required if .spec.os.name is not windows:

* Privilege Escalation

* Seccomp

* Linux Capabilities

## 5d8d355d
product: Kubernetes | version_label: v1.36 / Upgrade notes | date: 2026-05

Policy behaviour across upgrades

The behaviour of certain policy-related controls has been adjusted over time. Some restrictions that
applied broadly in earlier releases now apply more narrowly, and a small number of settings are
evaluated differently depending on how the cluster has been configured. Administrators are advised to
review the applicable settings before and after an upgrade, since the effective outcome may differ
from what the previous configuration produced. Where behaviour is unclear, confirm against the
configuration in use rather than assuming continuity.

## 9a850f58
product: Kubernetes | version_label: v1.37 / Pod Security Standards | date: 2026-09

| Seccomp (v1.19+) | |
Seccomp profile must be explicitly set to one of the allowed values. Both the Unconfined profile and the absence of a profile are prohibited. This is Linux only policy in v1.25+ (spec.os.name != windows)

Restricted Fields

* spec.securityContext.seccompProfile.type

* spec.containers[*].securityContext.seccompProfile.type

* spec.initContainers[*].securityContext.seccompProfile.type

* spec.ephemeralContainers[*].securityContext.seccompProfile.type

Allowed Values

* RuntimeDefault

* Localhost

The container fields may be undefined/nil if the pod-level
spec.securityContext.seccompProfile.type field is set appropriately.
Conversely, the pod-level field may be undefined/nil if _all_ container-
level fields are set. |

## d689b13a
product: Kubernetes | version_label: v1.24 / PodSecurityPolicy | date: 2022-04

## Policy Order

In addition to restricting pod creation and update, pod security policies can
also be used to provide default values for many of the fields that it
controls. When multiple policies are available, the pod security policy
controller selects policies according to the following criteria:

1. PodSecurityPolicies which allow the pod as-is, without changing defaults or
   mutating the pod, are preferred.  The order of these non-mutating
   PodSecurityPolicies doesn't matter.
2. If the pod must be defaulted or mutated, the first PodSecurityPolicy
   (ordered by name) to allow the pod is selected. [...] During update operations (during which mutations to pod specs are disallowed)
only non-mutating PodSecurityPolicies are used to validate the pod.

## d8c4412b
product: Kubernetes | version_label: v1.37 / Pod Security Standards | date: 2026-09

| HostProcess | |
Windows Pods offer the ability to run HostProcess containers which enables privileged access to the Windows host machine. Privileged access to the host is disallowed in the Baseline policy.
Feature state:
Stable since Kubernetes v1.26

Restricted Fields

* spec.securityContext.windowsOptions.hostProcess

* spec.containers[*].securityContext.windowsOptions.hostProcess

* spec.initContainers[*].securityContext.windowsOptions.hostProcess

* spec.ephemeralContainers[*].securityContext.windowsOptions.hostProcess

Allowed Values

* Undefined/nil

* false

## f5bfd0f3
product: Kubernetes | version_label: v1.25 | date: 2022-08-25

In Kubernetes v1.23 and earlier, the kubelet didn't enforce the Pod OS field.
If your cluster includes nodes running a v1.23 or older kubelet, you should explicitly
pin Restricted policies
to a version prior to v1.25.

---
(no fur