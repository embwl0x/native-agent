Enforce Pod Security Standards with Namespace Labels

Namespaces can be labeled to enforce the Pod Security Standards. The three policies
privileged, baseline
and restricted broadly cover the security spectrum
and are implemented by the Pod Security admission controller.

Before you begin

Pod Security Admission was available by default in Kubernetes v1.23, as
a beta. From version 1.25 onwards, Pod Security Admission is generally
available.

To check the version, enter kubectl version.

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

# We are setting these to our _desired_ `enforce` level.
pod-security.kubernetes.io/audit: restricted
pod-security.kubernetes.io/audit-version: v1.37
pod-security.kubernetes.io/warn: restricted
pod-security.kubernetes.io/warn-version: v1.37

Add labels to existing namespaces with kubectl label

Note:
When an enforce policy (or version) label is added or changed, the admission plugin will test
each pod in the namespace against the new policy. Violations are returned to the user as warnings.

It is helpful to apply the --dry-run flag when initially evaluating security profile changes for
namespaces. The Pod Security Standard checks will still be run in dry run mode, giving you
information about how the new policy would treat existing pods, without actually updating a policy.

kubectl label --dry-run=server --overwrite ns --all \
pod-security.kubernetes.io/enforce=baseline

Applying to all namespaces

If you're just getting started with the Pod Security Standards, a suitable first step would be to
configure all namespaces with audit annotations for a stricter level such as baseline:

kubectl label --overwrite ns --all \
pod-security.kubernetes.io/audit=baseline \
pod-security.kubernetes.io/warn=baseline

Note that this is not setting an enforce level, so that namespaces that haven't been explicitly
evaluated can be distinguished. You can list namespaces without an explicitly set enforce level
using this command:

kubectl get namespaces --selector='!pod-security.kubernetes.io/enforce'

Applying to a single namespace

You can update a specific namespace as well. This command adds the enforce=restricted
policy to my-existing-namespace, pinning the restricted policy version to v1.37.

kubectl label --overwrite ns my-existing-namespace \
pod-security.kubernetes.io/enforce=restricted \
pod-security.kubernetes.io/enforce-version=v1.37

Feedback

Was this page helpful?
Yes
No
Thanks for the feedback. If you have a specific, answerable question about how to use Kubernetes, ask it on
Stack Overflow.
Open an issue in the GitHub Repository if you want to
report a problem
or
suggest an improvement.

Last modified November 05, 2022 at 6:40 PM PST: Update docs for PodSecurityPolicy removal (bb85d62752)
