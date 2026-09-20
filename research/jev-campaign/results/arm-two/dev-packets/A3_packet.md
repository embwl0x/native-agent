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

## 506354c6
product: Kubernetes | version_label: v1.37 / Tasks | date: 2026-09

Requiring the baseline Pod Security Standard with namespace labels

This manifest defines a Namespace my-baseline-namespace that:

* Blocks any pods that don't satisfy the baseline policy requirements.

* Generates a user-facing warning and adds an audit annotation to any created pod that does not
meet the restricted policy requirements.

* Pins the versions of the baseline and restricted policies to v1.37.

apiVersion: v1
kind: Namespace
metadata:
name: my-baseline-namespace
labels:
pod-security.kubernetes.io/enforce: baseline
pod-security.kubernetes.io/enforce-version: v1.37

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

## 59a92ca1
product: Kubernetes | version_label: v1.37 / Pod Security Admission | date: 2026-09

Exemptions

You can define exemptions from pod security enforcement in order to allow the creation of pods that
would have otherwise been prohibited due to the policy associated with a given namespace.
Exemptions can be statically configured in the
Admission Controller configuration.

Exemptions must be explicitly enumerated. Requests meeting exemption criteria are ignored by the
Admission Controller (all enforce, audit and warn behaviors are skipped). Exemption dimensions include:

* Usernames: requests from users with an exempt authenticated (or impersonated) username are
ignored.

* RuntimeClassNames: pods and workload resources specifying an exempt runtime class name are
ignored.

* Namespaces: pods and workload resources in an exempt namespace are ignored.

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
