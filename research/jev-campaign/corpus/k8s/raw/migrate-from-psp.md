Migrate from PodSecurityPolicy to the Built-In PodSecurity Admission Controller

This page describes the process of migrating from PodSecurityPolicies to the built-in PodSecurity
admission controller. This can be done effectively using a combination of dry-run and audit and
warn modes, although this becomes harder if mutating PSPs are used.

Before you begin

Your Kubernetes server must be at or later than version v1.22.

To check the version, enter kubectl version.

If you are currently running a version of Kubernetes other than
1.37, you may want to switch to viewing this
page in the documentation for the version of Kubernetes that you
are actually running.

This page assumes you are already familiar with the basic Pod Security Admission
concepts.

Overall approach

There are multiple strategies you can take for migrating from PodSecurityPolicy to Pod Security
Admission. The following steps are one possible migration path, with a goal of minimizing both the
risks of a production outage and of a security gap.

* Decide whether Pod Security Admission is the right fit for your use case.

* Review namespace permissions

* Simplify & standardize PodSecurityPolicies

* Update namespaces

* Identify an appropriate Pod Security level

* Verify the Pod Security level

* Enforce the Pod Security level

* Bypass PodSecurityPolicy

* Review namespace creation processes

* Disable PodSecurityPolicy

0. Decide whether Pod Security Admission is right for you

Pod Security Admission was designed to meet the most common security needs out of the box, and to
provide a standard set of security levels across clusters. However, it is less flexible than
PodSecurityPolicy. Notably, the following features are supported by PodSecurityPolicy but not Pod
Security Admission:

* Setting default security constraints - Pod Security Admission is a non-mutating admission
controller, meaning it won't modify pods before validating them. If you were relying on this
aspect of PSP, you will need to either modify your workloads to meet the Pod Security constraints,
or use a Mutating Admission Webhook
to make those changes. See Simplify & Standardize PodSecurityPolicies below for more detail.

* Fine-grained control over policy definition - Pod Security Admission only supports
3 standard levels.
If you require more control over specific constraints, then you will need to use a
Validating Admission Webhook
to enforce those policies.

* Sub-namespace policy granularity - PodSecurityPolicy lets you bind different policies to
different Service Accounts or users, even within a single namespace. This approach has many
pitfalls and is not recommended, but if you require this feature anyway you will
need to use a 3rd party webhook instead. The exception to this is if you only need to completely exempt
specific users or RuntimeClasses, in which case Pod
Security Admission does expose some
static configuration for exemptions.

Even if Pod Security Admission does not meet all of your needs it was designed to be complementary
to other policy enforcement mechanisms, and can provide a useful fallback running alongside other
admission webhooks.

1. Review namespace permissions

Pod Security Admission is controlled by labels on
namespaces.
This means that anyone who can update (or patch or create) a namespace can also modify the Pod
Security level for that namespace, which could be used to bypass a more restrictive policy. Before
proceeding, ensure that only trusted, privileged users have these namespace permissions. It is not
recommended to grant these powerful permissions to users that shouldn't have elevated permissions,
but if you must you will need to use an
admission webhook
to place additional restrictions on setting Pod Security labels on Namespace objects.

2. Simplify & standardize PodSecurityPolicies

In this section, you will reduce mutating PodSecurityPolicies and remove options that are outside
the scope of the Pod Security Standards. You should make the changes recommended here to an offline
copy of the original PodSecurityPolicy being modified. The cloned PSP should have a different
name that is alphabetically before the original (for example, prepend a 0 to it). Do not create the
new policies in Kubernetes yet - that will be covered in the Rollout the updated
policies section below.

2.a. Eliminate purely mutating fields

If a PodSecurityPolicy is mutating pods, then you could end up with pods that don't meet the Pod
Security level requirements when you finally turn PodSecurityPolicy off. In order to avoid this, you
should eliminate all PSP mutation prior to switching over. Unfortunately PSP does not cleanly
separate mutating & validating fields, so this is not a straightforward migration.

You can start by eliminating the fields that are purely mutating, and don't have any bearing on the
validating policy. These fields (also listed in the
Mapping PodSecurityPolicies to Pod Security Standards
reference) are:

* .spec.defaultAllowPrivilegeEscalation

* .spec.runtimeClass.defaultRuntimeClassName

* .metadata.annotations['seccomp.security.alpha.kubernetes.io/defaultProfileName']

* .metadata.annotations['apparmor.security.beta.kubernetes.io/defaultProfileName']

* .spec.defaultAddCapabilities - Although technically a mutating & validating field, these should
be merged into .spec.allowedCapabilities which performs the same validation without mutation.

Caution:
Removing these could result in workloads missing required configuration, and cause problems. See
Rollout the updated policies below for advice on how to roll these changes
out safely.

2.b. Eliminate options not covered by the Pod Security Standards

There are several fields in PodSecurityPolicy that are not covered by the Pod Security Standards. If
you must enforce these options, you will need to supplement Pod Security Admission with an
admission webhook,
which is outside the scope of this guide.

First, you can remove the purely validating fields that the Pod Security Standards do not cover.
These fields (also listed in the
Mapping PodSecurityPolicies to Pod Security Standards
reference with "no opinion") are:

* .spec.allowedHostPaths

* .spec.allowedFlexVolumes

* .spec.allowedCSIDrivers

* .spec.forbiddenSysctls

* .spec.runtimeClass

You can also remove the following fields, that are related to POSIX / UNIX group controls.

Caution:
If any of these use the MustRunAs strategy they may be mutating! Removing these could result in
workloads not setting the required groups, and cause problems. See
Rollout the updated policies below for advice on how to roll these changes
out safely.

* .spec.runAsGroup

* .spec.supplementalGroups

* .spec.fsGroup

The remaining mutating fields are required to properly support the Pod Security Standards, and will
need to be handled on a case-by-case basis later:

* .spec.requiredDropCapabilities - Required to drop ALL for the Restricted profile.

* .spec.seLinux - (Only mutating with the MustRunAs rule) required to enforce the SELinux
requirements of the Baseline & Restricted profiles.

* .spec.runAsUser - (Non-mutating with the RunAsAny rule) required to enforce RunAsNonRoot for
the Restricted profile.

* .spec.allowPrivilegeEscalation - (Only mutating if set to false) required for the Restricted
profile.

2.c. Rollout the updated PSPs

Next, you can rollout the updated policies to your cluster. You should proceed with caution, as
removing the mutating options may result in workloads missing required configuration.

For each updated PodSecurityPolicy:

* Identify pods running under the original PSP. This can be done using the kubernetes.io/psp
annotation. For example, using kubectl:

PSP_NAME="original" # Set the name of the PSP you're checking for
kubectl get pods --all-namespaces -o jsonpath="{range .items[?(@.metadata.annotations.kubernetes\.io\/psp=='$PSP_NAME')]}{.metadata.namespace} {.metadata.name}{'\n'}{end}"

* Compare these running pods against the original pod spec to determine whether PodSecurityPolicy
has modified the pod. For pods created by a workload resource
you can compare the pod with the PodTemplate in the controller resource. If any changes are
identified, the original Pod or PodTemplate should be updated with the desired configuration.
The fields to review are:

* .metadata.annotations['container.apparmor.security.beta.kubernetes.io/*'] (replace * with each container name)

* .spec.runtimeClassName

* .spec.securityContext.fsGroup

* .spec.securityContext.seccompProfile

* .spec.securityContext.seLinuxOptions

* .spec.securityContext.supplementalGroups

* On containers, under .spec.containers[*] and .spec.initContainers[*]:

* .securityContext.allowPrivilegeEscalation

* .securityContext.capabilities.add

* .securityContext.capabilities.drop

* .securityContext.readOnlyRootFilesystem

* .securityContext.runAsGroup

* .securityContext.runAsNonRoot

* .securityContext.runAsUser

* .securityContext.seccompProfile

* .securityContext.seLinuxOptions

* Create the new PodSecurityPolicies. If any Roles or ClusterRoles are granting use on all PSPs
this could cause the new PSPs to be used instead of their mutating counter-parts.

* Update your authorization to grant access to the new PSPs. In RBAC this means updating any Roles
or ClusterRoles that grant the use permission on the original PSP to also grant it to the
updated PSP.

* Verify: after some soak time, rerun the command from step 1 to see if any pods are still using
the original PSPs. Note that pods need to be recreated after the new policies have been rolled
out before they can be fully verified.

* (optional) Once you have verified that the original PSPs are no longer in use, you can delete
them.

3. Update Namespaces

The following steps will need to be performed on every namespace in the cluster. Commands referenced
in these steps use the $NAMESPACE variable to refer to the namespace being updated.

3.a. Identify an appropriate Pod Security level

Start reviewing the Pod Security Standards and
familiarizing yourself with the 3 different levels.

There are several ways to choose a Pod Security level for your namespace:

* By security requirements for the namespace - If you are familiar with the expected access
level for the namespace, you can choose an appropriate level based on those requirements, similar
to how one might approach this on a new cluster.

* By existing PodSecurityPolicies - Using the
Mapping PodSecurityPolicies to Pod Security Standards
reference you can map each
PSP to a Pod Security Standard level. If your PSPs aren't based on the Pod Security Standards, you
may need to decide between choosing a level that is at least as permissive as the PSP, and a
level that is at least as restrictive. You can see which PSPs are in use for pods in a given
namespace with this command:

kubectl get pods -n $NAMESPACE -o jsonpath="{.items[*].metadata.annotations.kubernetes\.io\/psp}" | tr " " "\n" | sort -u

* By existing pods - Using the strategies under Verify the Pod Security level,
you can test out both the Baseline and Restricted levels to see
whether they are sufficiently permissive for existing workloads, and chose the least-privileged
valid level.

Caution:
Options 2 & 3 above are based on existing pods, and may miss workloads that aren't currently
running, such as CronJobs, scale-to-zero workloads, or other workloads that haven't rolled out.

3.b. Verify the Pod Security level

Once you have selected a Pod Security level for the namespace (or if you're trying several), it's a
good idea to test it out first (you can skip this step if using the Privileged level). Pod Security
includes several tools to help test and safely roll out profiles.

First, you can dry-run the policy, which will evaluate pods currently running in the namespace
against the applied policy, without making the new policy take effect:

# $LEVEL is the level to dry-run, either "baseline" or "restricted".
kubectl label --dry-run=server --overwrite ns $NAMESPACE pod-security.kubernetes.io/enforce=$LEVEL

This command will return a warning for any existing pods that are not valid under the proposed
level.

The second option is better for catching workloads that are not currently running: audit mode. When
running under audit-mode (as opposed to enforcing), pods that violate the policy level are recorded
in the audit logs, which can be reviewed later after some soak time, but are not forbidden. Warning
mode works similarly, but returns the warning to the user immediately. You can set the audit level
on a namespace with this command:

kubectl label --overwrite ns $NAMESPACE pod-security.kubernetes.io/audit=$LEVEL

If either of these approaches yield unexpected violations, you will need to either update the
violating workloads to meet the policy requirements, or relax the namespace Pod Security level.

3.c. Enforce the Pod Security level

When you are satisfied that the chosen level can safely be enforced on the namespace, you can update
the namespace to enforce the desired level:

kubectl label --overwrite ns $NAMESPACE pod-security.kubernetes.io/enforce=$LEVEL

3.d. Bypass PodSecurityPolicy

Finally, you can effectively bypass PodSecurityPolicy at the namespace level by binding the fully
privileged PSP
to all service
accounts in the namespace.

# The following cluster-scoped commands are only needed once.
kubectl apply -f privileged-psp.yaml
kubectl create clusterrole privileged-psp --verb use --resource podsecuritypolicies.policy --resource-name privileged

# Per-namespace disable
kubectl create -n $NAMESPACE rolebinding disable-psp --clusterrole privileged-psp --group system:serviceaccounts:$NAMESPACE

Since the privileged PSP is non-mutating, and the PSP admission controller always
prefers non-mutating PSPs, this will ensure that pods in this namespace are no longer being modified
or restricted by PodSecurityPolicy.

The advantage to disabling PodSecurityPolicy on a per-namespace basis like this is if a problem
arises you can easily roll the change back by deleting the RoleBinding. Just make sure the
pre-existing PodSecurityPolicies are still in place!

# Undo PodSecurityPolicy disablement.
kubectl delete -n $NAMESPACE rolebinding disable-psp

4. Review namespace creation processes

Now that existing namespaces have been updated to enforce Pod Security Admission, you should ensure
that your processes and/or policies for creating new namespaces are updated to ensure that an
appropriate Pod Security profile is applied to new namespaces.

You can also statically configure the Pod Security admission controller to set a default enforce,
audit, and/or warn level for unlabeled namespaces. See
Configure the Admission Controller
for more information.

5. Disable PodSecurityPolicy

Finally, you're ready to disable PodSecurityPolicy. To do so, you will need to modify the admission
configuration of the API server:
How do I turn off an admission controller?.

To verify that the PodSecurityPolicy admission controller is no longer enabled, you can manually run
a test by impersonating a user without access to any PodSecurityPolicies (see the
PodSecurityPolicy example), or by verifying in
the API server logs. At startup, the API server outputs log lines listing the loaded admission
controller plugins:

I0218 00:59:44.903329 13 plugins.go:158] Loaded 16 mutating admission controller(s) successfully in the following order: NamespaceLifecycle,LimitRanger,ServiceAccount,NodeRestriction,TaintNodesByCondition,Priority,DefaultTolerationSeconds,ExtendedResourceToleration,PersistentVolumeLabel,DefaultStorageClass,StorageObjectInUseProtection,RuntimeClass,DefaultIngressClass,MutatingAdmissionWebhook.
I0218 00:59:44.903350 13 plugins.go:161] Loaded 14 validating admission controller(s) successfully in the following order: LimitRanger,ServiceAccount,PodSecurity,Priority,PersistentVolumeClaimResize,RuntimeClass,CertificateApproval,CertificateSigning,CertificateSubjectRestriction,DenyServiceExternalIPs,ValidatingAdmissionWebhook,ResourceQuota.

You should see PodSecurity (in the validating admission controllers), and neither list should
contain PodSecurityPolicy.

Once you are certain the PSP admission controller is disabled (and after sufficient soak time to be
confident you won't need to roll back), you are free to delete your PodSecurityPolicies and any
associated Roles, ClusterRoles, RoleBindings and ClusterRoleBindings (just make sure they don't
grant any other unrelated permissions).

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

Last modified April 15, 2023 at 6:38 PM PST: fix minor typo permision -> permission (5ed63def8a)
