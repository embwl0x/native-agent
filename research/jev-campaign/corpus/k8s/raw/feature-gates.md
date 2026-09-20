Feature Gates

This page contains an overview of the various feature gates an administrator
can specify on different Kubernetes components.

See feature stages for an explanation of the stages for a feature.

Overview

Feature gates are a set of key=value pairs that describe Kubernetes features.
You can turn these features on or off using the --feature-gates command line flag
on each Kubernetes component.

How to enable Feature Gates

To enable or disable a feature gate for a particular Kubernetes component, use the
--feature-gates flag.

This flag accepts a comma-separated list of key=value pairs, where each key is a
feature gate name and each value is either true (enable) or false (disable).

Example usage:

kube-apiserver --feature-gates=FeatureName1=true,FeatureName2=false
kubelet --feature-gates=GracefulNodeShutdown=true

Each Kubernetes component supports only the feature gates relevant to its functions.
Use <component> -h to list available feature gates for a specific component.

For detailed instructions on configuring feature gates in your cluster, see
Configure Feature Gates.

Feature gates in Kubernetes v1.37

The following tables are a summary of the feature gates that you can set on
different Kubernetes components.

* The "Since" column contains the Kubernetes release when a feature is introduced
or its release stage is changed.

* The "Until" column, if not empty, contains the last Kubernetes release in which
you can still use a feature gate.

* If a feature is in the Alpha or Beta state, you can find the feature listed
in the Alpha/Beta feature gate table.

* If a feature is stable you can find all stages for that feature listed in the
Graduated/Deprecated feature gate table.

* The Graduated/Deprecated feature gate table
also lists deprecated and withdrawn features.

Note:
For a reference to old feature gates that are removed, please refer to
feature gates removed.

Feature gates for Alpha or Beta features
Feature gates for features in Alpha or Beta states
| Feature | | Default | | Stage | | Since | | Until |

| AllowParsingUserUIDFromCertAuth | | false | | Alpha | | 1.33 | | 1.33 |

| AllowParsingUserUIDFromCertAuth | | true | | Beta | | 1.34 | | – |

| AllowUnsafeMalformedObjectDeletion | | false | | Alpha | | 1.32 | | 1.36 |

| AllowUnsafeMalformedObjectDeletion | | true | | Beta | | 1.37 | | – |

| APIResponseCompression | | false | | Alpha | | 1.7 | | 1.15 |

| APIResponseCompression | | true | | Beta | | 1.16 | | – |

| APIServerIdentity | | false | | Alpha | | 1.20 | | 1.25 |

| APIServerIdentity | | true | | Beta | | 1.26 | | – |

| APIServerWebhookAuthenticationToken | | false | | Alpha | | 1.37 | | – |

| APIServingWithRoutine | | false | | Alpha | | 1.30 | | – |

| AtomicFIFO | | true | | Beta | | 1.36 | | – |

| AtomicWriteVolumeUserFields | | false | | Alpha | | 1.37 | | – |

| AuthorizePodWebsocketUpgradeCreatePermission | | true | | Beta | | 1.35 | | – |

| CBORServingAndStorage | | false | | Alpha | | 1.32 | | – |

| ClearingNominatedNodeNameAfterBinding | | false | | Alpha | | 1.34 | | 1.34 |

| ClearingNominatedNodeNameAfterBinding | | true | | Beta | | 1.35 | | – |

| CloudControllerManagerWatchBasedRoutesReconciliation | | false | | Alpha | | 1.35 | | – |

| CloudControllerManagerWebhook | | false | | Alpha | | 1.27 | | – |

| ComponentFlagz | | false | | Alpha | | 1.32 | | 1.35 |

| ComponentFlagz | | true | | Beta | | 1.36 | | – |

| ComponentStatusz | | false | | Alpha | | 1.32 | | 1.35 |

| ComponentStatusz | | true | | Beta | | 1.36 | | – |

| CompositePodGroup | | false | | Alpha | | 1.37 | | – |

| ConcurrentWatchObjectDecode | | false | | Beta | | 1.31 | | 1.36 |

| ConcurrentWatchObjectDecode | | true | | Beta | | 1.37 | | – |

| ConstrainedImpersonation | | false | | Alpha | | 1.35 | | 1.35 |

| ConstrainedImpersonation | | true | | Beta | | 1.36 | | – |

| ContainerCheckpoint | | false | | Alpha | | 1.25 | | 1.29 |

| ContainerCheckpoint | | true | | Beta | | 1.30 | | – |

| ContainerRestartRules | | false | | Alpha | | 1.34 | | 1.34 |

| ContainerRestartRules | | true | | Beta | | 1.35 | | – |

| ContainerStopSignals | | false | | Alpha | | 1.33 | | – |

| ContextualLogging | | false | | Alpha | | 1.24 | | – |

| ContextualLogging | | true | | Beta | | 1.30 | | – |

| ControllerManagerReleaseLeaderElectionLockOnExit | | false | | Alpha | | 1.36 | | – |

| CoordinatedLeaderElection | | false | | Alpha | | 1.31 | | 1.32 |

| CoordinatedLeaderElection | | false | | Beta | | 1.33 | | – |

| CPUManagerPolicyAlphaOptions | | false | | Alpha | | 1.23 | | – |

| CPUManagerPolicyBetaOptions | | true | | Beta | | 1.23 | | – |

| CRDObservedGenerationTracking | | false | | Beta | | 1.35 | | – |

| CRIListStreaming | | false | | Alpha | | 1.36 | | – |

| CrossNamespaceVolumeDataSource | | false | | Alpha | | 1.26 | | – |

| CSIVolumeHealth | | false | | Alpha | | 1.21 | | – |

| CustomCPUCFSQuotaPeriod | | false | | Alpha | | 1.12 | | – |

| DeclarativeValidationBeta | | true | | Beta | | 1.36 | | – |

| DefaultPodSysctls | | false | | Alpha | | 1.37 | | – |

| DeploymentReplicaSetTerminatingReplicas | | false | | Alpha | | 1.33 | | 1.34 |

| DeploymentReplicaSetTerminatingReplicas | | true | | Beta | | 1.35 | | – |

| DetectCacheInconsistency | | true | | Beta | | 1.34 | | – |

| DisableCPUQuotaWithExclusiveCPUs | | true | | Beta | | 1.33 | | – |

| DRAConsumableCapacity | | false | | Alpha | | 1.34 | | 1.35 |

| DRAConsumableCapacity | | true | | Beta | | 1.36 | | – |

| DRADerivedAttributes | | false | | Alpha | | 1.37 | | – |

| DRADeviceBindingConditions | | false | | Alpha | | 1.34 | | 1.35 |

| DRADeviceBindingConditions | | true | | Beta | | 1.36 | | – |

| DRADeviceCompatibilityGroups | | false | | Alpha | | 1.37 | | – |

| DRAListTypeAttributes | | false | | Alpha | | 1.36 | | – |

| DRANodeAllocatableResources | | false | | Alpha | | 1.36 | | – |

| DRAOptionalNodeOperations | | false | | Alpha | | 1.37 | | – |

| DRAPartitionableDevices | | false | | Alpha | | 1.33 | | 1.35 |

| DRAPartitionableDevices | | true | | Beta | | 1.36 | | – |

| DRAPartitionableDevicesType | | false | | Alpha | | 1.37 | | – |

| DRAResourceClaimGranularStatusAuthorization | | true | | Beta | | 1.36 | | – |

| DRAResourcePoolStatus | | false | | Alpha | | 1.36 | | – |

| DRASchedulerFilterTimeout | | false | | Alpha | | 1.34 | | – |

| DRAWorkloadResourceClaims | | false | | Alpha | | 1.36 | | – |

| DRAWorkloadResourceClaims | | false | | Beta | | 1.37 | | – |

| EmptyDirVolumeMode | | false | | Alpha | | 1.37 | | – |

| EnvFiles | | false | | Alpha | | 1.34 | | 1.34 |

| EnvFiles | | true | | Beta | | 1.35 | | – |

| EtcdRangeStream | | true | | Beta | | 1.37 | | – |

| EventedPLEG | | false | | Alpha | | 1.26 | | – |

| ExcludeAdmissionWebhookVirtualResources | | true | | Beta | | 1.37 | | – |

| ExtendWebSocketsToKubelet | | true | | Beta | | 1.36 | | – |

| GenericWorkload | | false | | Alpha | | 1.35 | | 1.36 |

| GenericWorkload | | false | | Beta | | 1.37 | | – |

| GracefulNodeShutdown | | false | | Alpha | | 1.20 | | 1.20 |

| GracefulNodeShutdown | | true | | Beta | | 1.21 | | – |

| GracefulNodeShutdownBasedOnPodPriority | | false | | Alpha | | 1.23 | | 1.23 |

| GracefulNodeShutdownBasedOnPodPriority | | true | | Beta | | 1.24 | | – |

| GRPCContainerProbeTLS | | false | | Alpha | | 1.37 | | – |

| H2CContainerProbe | | false | | Alpha | | 1.37 | | – |

| HPAScaleToZero | | false | | Alpha | | 1.16 | | 1.36 |

| HPAScaleToZero | | true | | Beta | | 1.37 | | – |

| HugepageAwareEviction | | true | | Beta | | 1.37 | | – |

| ImageVolumeWithDigest | | false | | Alpha | | 1.35 | | – |

| InOrderInformers | | true | | Alpha | | 1.33 | | 1.33 |

| InOrderInformers | | true | | Beta | | 1.34 | | – |

| InPlacePodLevelResourcesVerticalScaling | | false | | Alpha | | 1.35 | | 1.35 |

| InPlacePodLevelResourcesVerticalScaling | | true | | Beta | | 1.36 | | – |

| InPlacePodVerticalScalingExclusiveCPUs | | false | | Alpha | | 1.32 | | – |

| InPlacePodVerticalScalingExclusiveMemory | | false | | Alpha | | 1.34 | | – |

| InPlacePodVerticalScalingMemoryBackedVolumes | | false | | Alpha | | 1.37 | | – |

| InPlacePodVerticalScalingSchedulerPreemption | | false | | Alpha | | 1.37 | | – |

| KubeletCrashLoopBackOffMax | | false | | Alpha | | 1.32 | | 1.34 |

| KubeletCrashLoopBackOffMax | | true | | Beta | | 1.35 | | – |

| KubeletEnsureSecretPulledImages | | false | | Alpha | | 1.33 | | 1.34 |

| KubeletEnsureSecretPulledImages | | true | | Beta | | 1.35 | | – |

| KubeletInUserNamespace | | false | | Alpha | | 1.22 | | 1.36 |

| KubeletInUserNamespace | | true | | Beta | | 1.37 | | – |

| KubeletSeparateDiskGC | | false | | Alpha | | 1.29 | | 1.30 |

| KubeletSeparateDiskGC | | true | | Beta | | 1.31 | | – |

| KubeletServiceAccountTokenForCredentialProviders | | false | | Alpha | | 1.33 | | 1.33 |

| KubeletServiceAccountTokenForCredentialProviders | | true | | Beta | | 1.34 | | – |

| KubeProxyNFTablesLocalhostNodePorts | | false | | Alpha | | 1.37 | | – |

| ListFromCacheSnapshot | | false | | Alpha | | 1.33 | | 1.33 |

| ListFromCacheSnapshot | | true | | Beta | | 1.34 | | – |

| LocalStorageCapacityIsolationFSQuotaMonitoring | | false | | Alpha | | 1.15 | | 1.30 |

| LocalStorageCapacityIsolationFSQuotaMonitoring | | false | | Beta | | 1.31 | | – |

| LoggingAlphaOptions | | false | | Alpha | | 1.24 | | – |

| LoggingBetaOptions | | true | | Beta | | 1.24 | | – |

| ManifestBasedAdmissionControlConfig | | false | | Alpha | | 1.36 | | 1.36 |

| ManifestBasedAdmissionControlConfig | | true | | Beta | | 1.37 | | – |

| MatchLabelKeysInPodTopologySpread | | false | | Alpha | | 1.25 | | 1.26 |

| MatchLabelKeysInPodTopologySpread | | true | | Beta | | 1.27 | | – |

| MatchLabelKeysInPodTopologySpreadSelectorMerge | | true | | Beta | | 1.34 | | – |

| MaxUnavailableStatefulSet | | false | | Alpha | | 1.24 | | 1.34 |

| MaxUnavailableStatefulSet | | true | | Beta | | 1.35.0 | | 1.35.3 |

| MaxUnavailableStatefulSet | | false | | Beta | | 1.35.4 | | 1.36 |

| MaxUnavailableStatefulSet | | true | | Beta | | 1.37 | | – |

| MemoryQoS | | false | | Alpha | | 1.22 | | 1.36 |

| MemoryQoS | | true | | Beta | | 1.37 | | – |

| MutablePodResourcesForSuspendedJobs | | false | | Alpha | | 1.35 | | 1.35 |

| MutablePodResourcesForSuspendedJobs | | true | | Beta | | 1.36 | | – |

| MutablePVNodeAffinity | | false | | Alpha | | 1.35 | | – |

| MutableSchedulingDirectivesForSuspendedJobs | | false | | Alpha | | 1.35 | | 1.35 |

| MutableSchedulingDirectivesForSuspendedJobs | | true | | Beta | | 1.36 | | – |

| NativeHistograms | | false | | Alpha | | 1.36 | | 1.36 |

| NativeHistograms | | true | | Beta | | 1.37 | | – |

| NodeLifecycleConditions | | false | | Alpha | | 1.37 | | – |

| NominatedNodeNameForExpectation | | false | | Alpha | | 1.34 | | 1.34 |

| NominatedNodeNameForExpectation | | true | | Beta | | 1.35 | | – |

| OpenAPIEnums | | false | | Alpha | | 1.23 | | 1.23 |

| OpenAPIEnums | | true | | Beta | | 1.24 | | – |

| OpportunisticBatching | | true | | Beta | | 1.35 | | – |

| PersistentVolumeClaimUnusedSinceTime | | false | | Alpha | | 1.36 | | 1.36 |

| PersistentVolumeClaimUnusedSinceTime | | true | | Beta | | 1.37 | | – |

| PodAndContainerStatsFromCRI | | false | | Alpha | | 1.23 | | 1.36 |

| PodAndContainerStatsFromCRI | | false | | Beta | | 1.37 | | – |

| PodDeletionCost | | false | | Alpha | | 1.21 | | 1.21 |

| PodDeletionCost | | true | | Beta | | 1.22 | | – |

| PodGroupPreemptionPolicy | | false | | Alpha | | 1.37 | | – |

| PodLevelResourceManagers | | false | | Alpha | | 1.36 | | 1.36 |

| PodLevelResourceManagers | | false | | Beta | | 1.37 | | – |

| PodLevelResources | | false | | Alpha | | 1.32 | | 1.33 |

| PodLevelResources | | true | | Beta | | 1.34 | | – |

| PodLogsQuerySplitStreams | | false | | Alpha | | 1.32 | | – |

| PodsAPI | | false | | Alpha | | 1.36 | | 1.36 |

| PodsAPI | | true | | Beta | | 1.37 | | – |

| PodTopologyLabelsAdmission | | false | | Alpha | | 1.33 | | 1.34 |

| PodTopologyLabelsAdmission | | true | | Beta | | 1.35 | | – |

| PortForwardWebsockets | | false | | Alpha | | 1.30 | | 1.30 |

| PortForwardWebsockets | | true | | Beta | | 1.31 | | – |

| PreventStaticPodAPIReferences | | true | | Beta | | 1.34 | | – |

| QOSReserved | | false | | Alpha | | 1.11 | | – |

| ReduceDefaultCrashLoopBackOffDecay | | false | | Alpha | | 1.33 | | – |

| ReloadKubeletServerCertificateFile | | true | | Beta | | 1.31 | | – |

| RemoteRequestHeaderUID | | false | | Alpha | | 1.32 | | – |

| ResourceHealthStatus | | false | | Alpha | | 1.31 | | 1.35 |

| ResourceHealthStatus | | true | | Beta | | 1.36 | | – |

| RestartAllContainersOnContainerExits | | false | | Alpha | | 1.35 | | 1.35 |

| RestartAllContainersOnContainerExits | | true | | Beta | | 1.36 | | – |

| RotateKubeletServerCertificate | | false | | Alpha | | 1.7 | | 1.11 |

| RotateKubeletServerCertificate | | true | | Beta | | 1.12 | | – |

| RuntimeClassInImageCriApi | | false | | Alpha | | 1.29 | | – |

| SchedulerAsyncAPICalls | | true | | Beta | | 1.34 | | – |

| SchedulerAsyncPreemption | | false | | Alpha | | 1.32 | | 1.32 |

| SchedulerAsyncPreemption | | true | | Beta | | 1.33 | | – |

| SchedulerPopFromBackoffQ | | true | | Beta | | 1.33 | | – |

| ServiceAccountNodeAudienceRestriction | | false | | Beta | | 1.32 | | 1.32 |

| ServiceAccountNodeAudienceRestriction | | true | | Beta | | 1.33 | | – |

| ShardedListAndWatch | | false | | Alpha | | 1.36 | | – |

| SizeBasedListCostEstimate | | true | | Beta | | 1.34 | | – |

| StaleControllerConsistencyDaemonSet | | true | | Beta | | 1.36 | | – |

| StaleControllerConsistencyJob | | true | | Beta | | 1.36 | | – |

| StaleControllerConsistencyReplicaSet | | true | | Beta | | 1.36 | | – |

| StaleControllerConsistencyStatefulSet | | true | | Beta | | 1.36 | | – |

| StatefulSetRecreateStrategy | | false | | Alpha | | 1.37 | | – |

| StorageCapacityScoring | | false | | Alpha | | 1.33 | | 1.36 |

| StorageCapacityScoring | | true | | Beta | | 1.37 | | – |

| StorageVersionAPI | | false | | Alpha | | 1.20 | | – |

| StorageVersionHash | | false | | Alpha | | 1.14 | | 1.14 |

| StorageVersionHash | | true | | Beta | | 1.15 | | – |

| StorageVersionMigrator | | false | | Alpha | | 1.30 | | 1.34 |

| StorageVersionMigrator | | false | | Beta | | 1.35 | | – |

| StrictIPCIDRValidation | | false | | Alpha | | 1.33 | | 1.35 |

| StrictIPCIDRValidation | | true | | Beta | | 1.36 | | – |

| StructuredAuthenticationConfigurationEgressSelector | | true | | Beta | | 1.34 | | – |

| StructuredAuthenticationConfigurationJWKSMetrics | | true | | Beta | | 1.35 | | – |

| SupplementalGroupsPolicy | | false | | Alpha | | 1.31 | | 1.32 |

| SupplementalGroupsPolicy | | true | | Beta | | 1.33 | | – |

| SystemdWatchdog | | true | | Beta | | 1.32 | | – |

| TaintTolerationComparisonOperators | | false | | Alpha | | 1.35 | | – |

| TokenRequestServiceAccountUIDValidation | | true | | Beta | | 1.34 | | – |

| TopologyAwareWorkloadScheduling | | false | | Alpha | | 1.36 | | – |

| TopologyManagerPolicyAlphaOptions | | false | | Alpha | | 1.26 | | – |

| TopologyManagerPolicyBetaOptions | | false | | Beta | | 1.26 | | 1.27 |

| TopologyManagerPolicyBetaOptions | | true | | Beta | | 1.28 | | – |

| TranslateStreamCloseWebsocketRequests | | false | | Alpha | | 1.29 | | 1.29 |

| TranslateStreamCloseWebsocketRequests | | true | | Beta | | 1.30 | | – |

| UnauthenticatedHTTP2DOSMitigation | | false | | Beta | | 1.28 | | 1.28 |

| UnauthenticatedHTTP2DOSMitigation | | true | | Beta | | 1.29 | | – |

| UnknownVersionInteroperabilityProxy | | false | | Alpha | | 1.28 | | 1.35 |

| UnknownVersionInteroperabilityProxy | | true | | Beta | | 1.36 | | – |

| UnlockWhileProcessingFIFO | | true | | Beta | | 1.36 | | – |

| UserNamespacesHostNetworkSupport | | false | | Alpha | | 1.35 | | – |

| VolumeBindMountOptions | | false | | Alpha | | 1.37 | | – |

| VolumeLimitScaling | | false | | Alpha | | 1.35 | | 1.36 |

| VolumeLimitScaling | | true | | Beta | | 1.37 | | – |

| WatchList | | false | | Alpha | | 1.27 | | 1.31 |

| WatchList | | true | | Beta | | 1.32 | | 1.32 |

| WatchList | | false | | Beta | | 1.33 | | 1.33 |

| WatchList | | true | | Beta | | 1.34 | | – |

| WatchListClient | | false | | Beta | | 1.30 | | 1.34 |

| WatchListClient | | true | | Beta | | 1.35 | | – |

| WindowsCPUAndMemoryAffinity | | false | | Alpha | | 1.32 | | – |

| WindowsGracefulNodeShutdown | | false | | Alpha | | 1.32 | | 1.33 |

| WindowsGracefulNodeShutdown | | true | | Beta | | 1.34 | | – |

| WorkloadWithJob | | false | | Alpha | | 1.36 | | – |

Feature gates for graduated or deprecated features
Feature Gates for Graduated or Deprecated Features
| Feature | | Default | | Stage | | Since | | Until |

| AllowDNSOnlyNodeCSR | | false | | Deprecated | | 1.31 | | – |

| AllowInsecureKubeletCertificateSigningRequests | | false | | Deprecated | | 1.31 | | – |

| AnonymousAuthConfigurableEndpoints | | false | | Alpha | | 1.31 | | 1.31 |

| AnonymousAuthConfigurableEndpoints | | true | | Beta | | 1.32 | | 1.33 |

| AnonymousAuthConfigurableEndpoints | | true | | Stable | | 1.34 | | – |

| AnyVolumeDataSource | | false | | Alpha | | 1.18 | | 1.23 |

| AnyVolumeDataSource | | true | | Beta | | 1.24 | | 1.32 |

| AnyVolumeDataSource | | true | | Stable | | 1.33 | | – |

| APIServerTracing | | false | | Alpha | | 1.22 | | 1.26 |

| APIServerTracing | | true | | Beta | | 1.27 | | 1.33 |

| APIServerTracing | | true | | Stable | | 1.34 | | – |

| AuthorizeNodeWithSelectors | | false | | Alpha | | 1.31 | | 1.31 |

| AuthorizeNodeWithSelectors | | true | | Beta | | 1.32 | | 1.33 |

| AuthorizeNodeWithSelectors | | true | | Stable | | 1.34 | | – |

| AuthorizeWithSelectors | | false | | Alpha | | 1.31 | | 1.31 |

| AuthorizeWithSelectors | | true | | Beta | | 1.32 | | 1.33 |

| AuthorizeWithSelectors | | true | | Stable | | 1.34 | | – |

| BtreeWatchCache | | true | | Beta | | 1.32 | | 1.32 |

| BtreeWatchCache | | true | | Stable | | 1.33 | | – |

| ChangeContainerStatusOnKubeletRestart | | false | | Deprecated | | 1.35 | | – |

| ClusterTrustBundle | | false | | Alpha | | 1.27 | | 1.32 |

| ClusterTrustBundle | | false | | Beta | | 1.33 | | 1.36 |

| ClusterTrustBundle | | true | | Stable | | 1.37 | | – |

| ClusterTrustBundleProjection | | false | | Alpha | | 1.29 | | 1.32 |

| ClusterTrustBundleProjection | | false | | Beta | | 1.33 | | 1.36 |

| ClusterTrustBundleProjection | | true | | Stable | | 1.37 | | – |

| ConsistentListFromCache | | false | | Alpha | | 1.28 | | 1.30 |

| ConsistentListFromCache | | true | | Beta | | 1.31 | | 1.33 |

| ConsistentListFromCache | | true | | Stable | | 1.34 | | – |

| CPUManagerPolicyOptions | | false | | Alpha | | 1.22 | | 1.22 |

| CPUManagerPolicyOptions | | true | | Beta | | 1.23 | | 1.32 |

| CPUManagerPolicyOptions | | true | | Stable | | 1.33 | | – |

| CRDValidationRatcheting | | false | | Alpha | | 1.28 | | 1.29 |

| CRDValidationRatcheting | | true | | Beta | | 1.30 | | 1.32 |

| CRDValidationRatcheting | | true | | Stable | | 1.33 | | – |

| CronJobsScheduledAnnotation | | true | | Beta | | 1.28 | | 1.31 |

| CronJobsScheduledAnnotation | | true | | Stable | | 1.32 | | – |

| CSIServiceAccountTokenSecrets | | true | | Beta | | 1.35 | | 1.35 |

| CSIServiceAccountTokenSecrets | | true | | Stable | | 1.36 | | – |

| CustomResourceFieldSelectors | | false | | Alpha | | 1.30 | | 1.30 |

| CustomResourceFieldSelectors | | true | | Beta | | 1.31 | | 1.31 |

| CustomResourceFieldSelectors | | true | | Stable | | 1.32 | | – |

| DeclarativeValidation | | true | | Beta | | 1.33 | | 1.35 |

| DeclarativeValidation | | true | | Stable | | 1.36 | | – |

| DeclarativeValidationTakeover | | false | | Beta | | 1.33 | | 1.35 |

| DeclarativeValidationTakeover | | false | | Deprecated | | 1.36 | | – |

| DisableAllocatorDualWrite | | false | | Alpha | | 1.31 | | 1.32 |

| DisableAllocatorDualWrite | | false | | Beta | | 1.33 | | 1.33 |

| DisableAllocatorDualWrite | | true | | Stable | | 1.34 | | – |

| DisableNodeKubeProxyVersion | | false | | Alpha | | 1.29 | | 1.30 |

| DisableNodeKubeProxyVersion | | true | | Beta | | 1.31.0 | | 1.31.0 |

| DisableNodeKubeProxyVersion | | false | | Deprecated | | 1.31.1 | | – |

| DisableNodeKubeProxyVersion | | false | | Deprecated | | 1.32 | | 1.32 |

| DisableNodeKubeProxyVersion | | true | | Deprecated | | 1.33 | | – |

| DRAAdminAccess | | false | | Alpha | | 1.32 | | 1.33 |

| DRAAdminAccess | | true | | Beta | | 1.34 | | 1.35 |

| DRAAdminAccess | | true | | Stable | | 1.36 | | – |

| DRADeviceTaintRules | | false | | Alpha | | 1.35 | | 1.35 |

| DRADeviceTaintRules | | false | | Beta | | 1.36 | | 1.37 |

| DRADeviceTaintRules | | true | | Stable | | 1.37 | | – |

| DRADeviceTaints | | false | | Alpha | | 1.33 | | 1.35 |

| DRADeviceTaints | | true | | Beta | | 1.36 | | 1.37 |

| DRADeviceTaints | | true | | Stable | | 1.37 | | – |

| DRAExtendedResource | | false | | Alpha | | 1.34 | | 1.35 |

| DRAExtendedResource | | true | | Beta | | 1.36 | | 1.36 |

| DRAExtendedResource | | true | | Stable | | 1.37 | | – |

| DRAPrioritizedList | | false | | Alpha | | 1.33 | | 1.33 |

| DRAPrioritizedList | | true | | Beta | | 1.34 | | 1.35 |

| DRAPrioritizedList | | true | | Stable | | 1.36 | | – |

| DRAResourceClaimDeviceStatus | | false | | Alpha | | 1.32 | | 1.32 |

| DRAResourceClaimDeviceStatus | | true | | Beta | | 1.33 | | 1.36 |

| DRAResourceClaimDeviceStatus | | true | | Stable | | 1.37 | | – |

| DynamicResourceAllocation | | false | | Alpha | | 1.30 | | 1.31 |

| DynamicResourceAllocation | | false | | Beta | | 1.32 | | 1.33 |

| DynamicResourceAllocation | | true | | Stable | | 1.34 | | 1.34 |

| DynamicResourceAllocation | | true | | Stable | | 1.35 | | – |

| ElasticIndexedJob | | true | | Beta | | 1.27 | | 1.30 |

| ElasticIndexedJob | | true | | Stable | | 1.31 | | – |

| ExecProbeTimeout | | true | | Stable | | 1.20 | | – |

| ExternalServiceAccountTokenSigner | | false | | Alpha | | 1.32 | | 1.33 |

| ExternalServiceAccountTokenSigner | | true | | Beta | | 1.34 | | 1.35 |

| ExternalServiceAccountTokenSigner | | true | | Stable | | 1.36 | | – |

| GitRepoVolumeDriver | | false | | Deprecated | | 1.33 | | – |

| HostnameOverride | | false | | Alpha | | 1.34 | | 1.34 |

| HostnameOverride | | true | | Beta | | 1.35 | | 1.36 |

| HostnameOverride | | true | | Stable | | 1.37 | | – |

| HPAConfigurableTolerance | | false | | Alpha | | 1.33 | | 1.34 |

| HPAConfigurableTolerance | | false | | Beta | | 1.35 | | 1.36 |

| HPAConfigurableTolerance | | true | | Stable | | 1.37 | | – |

| ImageMaximumGCAge | | false | | Alpha | | 1.29 | | 1.29 |

| ImageMaximumGCAge | | true | | Beta | | 1.30 | | 1.34 |

| ImageMaximumGCAge | | true | | Stable | | 1.35 | | – |

| ImageVolume | | false | | Alpha | | 1.31 | | 1.32 |

| ImageVolume | | false | | Beta | | 1.33 | | 1.34 |

| ImageVolume | | true | | Beta | | 1.35 | | 1.35 |

| ImageVolume | | true | | Stable | | 1.36 | | – |

| InformerResourceVersion | | false | | Alpha | | 1.30 | | 1.34 |

| InformerResourceVersion | | true | | Stable | | 1.35 | | – |

| InPlacePodVerticalScaling | | false | | Alpha | | 1.27 | | 1.32 |

| InPlacePodVerticalScaling | | true | | Beta | | 1.33 | | 1.34 |

| InPlacePodVerticalScaling | | true | | Stable | | 1.35 | | – |

| InPlacePodVerticalScalingAllocatedStatus | | false | | Alpha | | 1.32 | | 1.32 |

| InPlacePodVerticalScalingAllocatedStatus | | false | | Deprecated | | 1.33 | | – |

| JobBackoffLimitPerIndex | | false | | Alpha | | 1.28 | | 1.28 |

| JobBackoffLimitPerIndex | | true | | Beta | | 1.29 | | 1.32 |

| JobBackoffLimitPerIndex | | true | | Stable | | 1.33 | | – |

| JobManagedBy | | false | | Alpha | | 1.30 | | 1.31 |

| JobManagedBy | | true | | Beta | | 1.32 | | 1.34 |

| JobManagedBy | | true | | Stable | | 1.35 | | – |

| JobPodReplacementPolicy | | false | | Alpha | | 1.28 | | 1.28 |

| JobPodReplacementPolicy | | true | | Beta | | 1.29 | | 1.33 |

| JobPodReplacementPolicy | | true | | Stable | | 1.34 | | – |

| JobSuccessPolicy | | false | | Alpha | | 1.30 | | 1.30 |

| JobSuccessPolicy | | true | | Beta | | 1.31 | | 1.32 |

| JobSuccessPolicy | | true | | Stable | | 1.33 | | – |

| KMSv1 | | true | | Deprecated | | 1.28 | | 1.28 |

| KMSv1 | | false | | Deprecated | | 1.29 | | – |

| KubeletCgroupDriverFromCRI | | false | | Alpha | | 1.28 | | 1.30 |

| KubeletCgroupDriverFromCRI | | true | | Beta | | 1.31 | | – |

| KubeletCgroupDriverFromCRI | | true | | Stable | | 1.34 | | – |

| KubeletFineGrainedAuthz | | false | | Alpha | | 1.32 | | 1.32 |

| KubeletFineGrainedAuthz | | true | | Beta | | 1.33 | | 1.35 |

| KubeletFineGrainedAuthz | | true | | Stable | | 1.36 | | – |

| KubeletPodResourcesDynamicResources | | false | | Alpha | | 1.27 | | 1.33 |

| KubeletPodResourcesDynamicResources | | true | | Beta | | 1.34 | | 1.35 |

| KubeletPodResourcesDynamicResources | | true | | Stable | | 1.36 | | – |

| KubeletPodResourcesGet | | false | | Alpha | | 1.27 | | 1.33 |

| KubeletPodResourcesGet | | true | | Beta | | 1.34 | | 1.35 |

| KubeletPodResourcesGet | | true | | Stable | | 1.36 | | – |

| KubeletPSI | | false | | Alpha | | 1.33 | | 1.33 |

| KubeletPSI | | true | | Beta | | 1.34 | | 1.35 |

| KubeletPSI | | true | | Stable | | 1.36 | | – |

| KubeletTracing | | false | | Alpha | | 1.25 | | 1.26 |

| KubeletTracing | | true | | Beta | | 1.27 | | 1.33 |

| KubeletTracing | | true | | Stable | | 1.34 | | – |

| KubeProxyIPVS | | true | | Deprecated | | 1.37 | | – |

| LogarithmicScaleDown | | false | | Alpha | | 1.21 | | 1.21 |

| LogarithmicScaleDown | | true | | Beta | | 1.22 | | 1.30 |

| LogarithmicScaleDown | | true | | Stable | | 1.31 | | – |

| MatchLabelKeysInPodAffinity | | false | | Alpha | | 1.29 | | 1.30 |

| MatchLabelKeysInPodAffinity | | true | | Beta | | 1.31 | | 1.32 |

| MatchLabelKeysInPodAffinity | | true | | Stable | | 1.33 | | – |

| MemoryManager | | false | | Alpha | | 1.21 | | 1.21 |

| MemoryManager | | true | | Beta | | 1.22 | | 1.31 |

| MemoryManager | | true | | Stable | | 1.32 | | – |

| MultiCIDRServiceAllocator | | false | | Alpha | | 1.27 | | 1.30 |

| MultiCIDRServiceAllocator | | false | | Beta | | 1.31 | | 1.32 |

| MultiCIDRServiceAllocator | | true | | Stable | | 1.33 | | – |

| MutableCSINodeAllocatableCount | | false | | Alpha | | 1.33 | | 1.33 |

| MutableCSINodeAllocatableCount | | false | | Beta | | 1.34 | | 1.34 |

| MutableCSINodeAllocatableCount | | true | | Beta | | 1.35 | | 1.35 |

| MutableCSINodeAllocatableCount | | true | | Stable | | 1.36 | | – |

| MutatingAdmissionPolicy | | false | | Alpha | | 1.30 | | 1.33 |

| MutatingAdmissionPolicy | | false | | Beta | | 1.34 | | 1.35 |

| MutatingAdmissionPolicy | | true | | Stable | | 1.36 | | – |

| NFTablesProxyMode | | false | | Alpha | | 1.29 | | 1.30 |

| NFTablesProxyMode | | true | | Beta | | 1.31 | | 1.32 |

| NFTablesProxyMode | | true | | Stable | | 1.33 | | – |

| NodeDeclaredFeatures | | false | | Alpha | | 1.35 | | 1.35 |

| NodeDeclaredFeatures | | true | | Beta | | 1.36 | | 1.36 |

| NodeDeclaredFeatures | | true | | Stable | | 1.37 | | – |

| NodeInclusionPolicyInPodTopologySpread | | false | | Alpha | | 1.25 | | 1.25 |

| NodeInclusionPolicyInPodTopologySpread | | true | | Beta | | 1.26 | | 1.32 |

| NodeInclusionPolicyInPodTopologySpread | | true | | Stable | | 1.33 | | – |

| NodeLogQuery | | false | | Alpha | | 1.27 | | 1.29 |

| NodeLogQuery | | false | | Beta | | 1.30 | | 1.35 |

| NodeLogQuery | | true | | Stable | | 1.36 | | – |

| NodeSwap | | false | | Alpha | | 1.22 | | 1.27 |

| NodeSwap | | false | | Beta | | 1.28 | | 1.29 |

| NodeSwap | | true | | Beta | | 1.30 | | 1.33 |

| NodeSwap | | true | | Stable | | 1.34 | | – |

| OrderedNamespaceDeletion | | false | | Beta | | 1.30 | | 1.32 |

| OrderedNamespaceDeletion | | true | | Beta | | 1.33 | | 1.33 |

| OrderedNamespaceDeletion | | true | | Stable | | 1.34 | | – |

| PodCertificateRequest | | false | | Alpha | | 1.34 | | 1.34 |

| PodCertificateRequest | | false | | Beta | | 1.35 | | 1.36 |

| PodCertificateRequest | | true | | Stable | | 1.37 | | – |

| PodIndexLabel | | true | | Beta | | 1.28 | | 1.31 |

| PodIndexLabel | | true | | Stable | | 1.32 | | – |

| PodLifecycleSleepAction | | false | | Alpha | | 1.29 | | 1.29 |

| PodLifecycleSleepAction | | true | | Beta | | 1.30 | | 1.33 |

| PodLifecycleSleepAction | | true | | Stable | | 1.34 | | – |

| PodLifecycleSleepActionAllowZero | | false | | Alpha | | 1.32 | | 1.32 |

| PodLifecycleSleepActionAllowZero | | true | | Beta | | 1.33 | | 1.33 |

| PodLifecycleSleepActionAllowZero | | true | | Stable | | 1.34 | | – |

| PodObservedGenerationTracking | | false | | Alpha | | 1.33 | | 1.33 |

| PodObservedGenerationTracking | | true | | Beta | | 1.34 | | 1.34 |

| PodObservedGenerationTracking | | true | | Stable | | 1.35 | | – |

| PodReadyToStartContainersCondition | | false | | Alpha | | 1.28 | | 1.28 |

| PodReadyToStartContainersCondition | | true | | Beta | | 1.29 | | 1.36 |

| PodReadyToStartContainersCondition | | true | | Stable | | 1.37 | | – |

| PodSchedulingReadiness | | false | | Alpha | | 1.26 | | 1.26 |

| PodSchedulingReadiness | | true | | Beta | | 1.27 | | 1.29 |

| PodSchedulingReadiness | | true | | Stable | | 1.30 | | – |

| PreferSameTrafficDistribution | | false | | Alpha | | 1.33 | | 1.33 |

| PreferSameTrafficDistribution | | true | | Beta | | 1.34 | | 1.34 |

| PreferSameTrafficDistribution | | true | | Stable | | 1.35 | | – |

| ProcMountType | | false | | Alpha | | 1.12 | | 1.30 |

| ProcMountType | | false | | Beta | | 1.31 | | 1.32 |

| ProcMountType | | true | | Beta | | 1.33 | | 1.35 |

| ProcMountType | | true | | Stable | | 1.36 | | – |

| RecoverVolumeExpansionFailure | | false | | Alpha | | 1.23 | | 1.31 |

| RecoverVolumeExpansionFailure | | true | | Beta | | 1.32 | | 1.33 |

| RecoverVolumeExpansionFailure | | true | | Stable | | 1.34 | | – |

| RecursiveReadOnlyMounts | | false | | Alpha | | 1.30 | | 1.30 |

| RecursiveReadOnlyMounts | | true | | Beta | | 1.31 | | 1.32 |

| RecursiveReadOnlyMounts | | true | | Stable | | 1.33 | | – |

| RelaxedDNSSearchValidation | | false | | Alpha | | 1.32 | | 1.32 |

| RelaxedDNSSearchValidation | | true | | Beta | | 1.33 | | 1.33 |

| RelaxedDNSSearchValidation | | true | | Stable | | 1.34 | | – |

| RelaxedEnvironmentVariableValidation | | false | | Alpha | | 1.30 | | 1.31 |

| RelaxedEnvironmentVariableValidation | | true | | Beta | | 1.32 | | 1.33 |

| RelaxedEnvironmentVariableValidation | | true | | Stable | | 1.34 | | – |

| RelaxedServiceNameValidation | | false | | Alpha | | 1.34 | | 1.35 |

| RelaxedServiceNameValidation | | true | | Beta | | 1.36 | | 1.36 |

| RelaxedServiceNameValidation | | true | | Stable | | 1.37 | | – |

| ResilientWatchCacheInitialization | | true | | Beta | | 1.31 | | 1.33 |

| ResilientWatchCacheInitialization | | true | | Stable | | 1.34 | | – |

| RetryGenerateName | | false | | Alpha | | 1.30 | | 1.30 |

| RetryGenerateName | | true | | Beta | | 1.31 | | 1.31 |

| RetryGenerateName | | true | | Stable | | 1.32 | | – |

| SchedulerQueueingHints | | true | | Beta | | 1.28 | | 1.28 |

| SchedulerQueueingHints | | false | | Beta | | 1.29 | | 1.31 |

| SchedulerQueueingHints | | true | | Beta | | 1.32 | | 1.33 |

| SchedulerQueueingHints | | true | | Stable | | 1.34 | | – |

| SELinuxChangePolicy | | false | | Alpha | | 1.32 | | 1.32 |

| SELinuxChangePolicy | | true | | Beta | | 1.33 | | 1.35 |

| SELinuxChangePolicy | | true | | Stable | | 1.36 | | – |

| SELinuxMount | | false | | Alpha | | 1.30 | | 1.32 |

| SELinuxMount | | false | | Beta | | 1.33 | | 1.36 |

| SELinuxMount | | true | | Stable | | 1.37 | | – |

| SELinuxMountReadWriteOncePod | | false | | Alpha | | 1.25 | | 1.26 |

| SELinuxMountReadWriteOncePod | | false | | Beta | | 1.27 | | 1.27 |

| SELinuxMountReadWriteOncePod | | true | | Beta | | 1.28 | | 1.35 |

| SELinuxMountReadWriteOncePod | | true | | Stable | | 1.36 | | – |

| SeparateCacheWatchRPC | | true | | Beta | | 1.28 | | 1.32 |

| SeparateCacheWatchRPC | | false | | Deprecated | | 1.33 | | – |

| SeparateTaintEvictionController | | true | | Beta | | 1.29 | | 1.33 |

| SeparateTaintEvictionController | | true | | Stable | | 1.34 | | – |

| ServiceAccountTokenJTI | | false | | Alpha | | 1.29 | | 1.29 |

| ServiceAccountTokenJTI | | true | | Beta | | 1.30 | | 1.31 |

| ServiceAccountTokenJTI | | true | | Stable | | 1.32 | | – |

| ServiceAccountTokenNodeBinding | | false | | Alpha | | 1.29 | | 1.30 |

| ServiceAccountTokenNodeBinding | | true | | Beta | | 1.31 | | 1.32 |

| ServiceAccountTokenNodeBinding | | true | | Stable | | 1.33 | | – |

| ServiceAccountTokenNodeBindingValidation | | false | | Alpha | | 1.29 | | 1.29 |

| ServiceAccountTokenNodeBindingValidation | | true | | Beta | | 1.30 | | 1.31 |

| ServiceAccountTokenNodeBindingValidation | | true | | Stable | | 1.32 | | – |

| ServiceAccountTokenPodNodeInfo | | false | | Alpha | | 1.29 | | 1.29 |

| ServiceAccountTokenPodNodeInfo | | true | | Beta | | 1.30 | | 1.31 |

| ServiceAccountTokenPodNodeInfo | | true | | Stable | | 1.32 | | – |

| ServiceTrafficDistribution | | false | | Alpha | | 1.30 | | 1.30 |

| ServiceTrafficDistribution | | true | | Beta | | 1.31 | | 1.32 |

| ServiceTrafficDistribution | | true | | Stable | | 1.33 | | – |

| SidecarContainers | | false | | Alpha | | 1.28 | | 1.28 |

| SidecarContainers | | true | | Beta | | 1.29 | | 1.32 |

| SidecarContainers | | true | | Stable | | 1.33 | | – |

| StatefulSetAutoDeletePVC | | false | | Alpha | | 1.23 | | 1.26 |

| StatefulSetAutoDeletePVC | | true | | Beta | | 1.27 | | 1.31 |

| StatefulSetAutoDeletePVC | | true | | Stable | | 1.32 | | – |

| StatefulSetStartOrdinal | | false | | Alpha | | 1.26 | | 1.26 |

| StatefulSetStartOrdinal | | true | | Beta | | 1.27 | | 1.30 |

| StatefulSetStartOrdinal | | true | | Stable | | 1.31 | | – |

| StorageNamespaceIndex | | true | | Beta | | 1.30 | | 1.32 |

| StorageNamespaceIndex | | true | | Deprecated | | 1.33 | | – |

| StreamingCollectionEncodingToJSON | | true | | Beta | | 1.33 | | 1.33 |

| StreamingCollectionEncodingToJSON | | true | | Stable | | 1.34 | | – |

| StreamingCollectionEncodingToProtobuf | | true | | Alpha | | 1.33 | | 1.33 |

| StreamingCollectionEncodingToProtobuf | | true | | Stable | | 1.34 | | – |

| StrictCostEnforcementForVAP | | false | | Beta | | 1.30 | | 1.31 |

| StrictCostEnforcementForVAP | | true | | Stable | | 1.32 | | – |

| StrictCostEnforcementForWebhooks | | false | | Beta | | 1.31 | | 1.31 |

| StrictCostEnforcementForWebhooks | | true | | Stable | | 1.32 | | – |

| StructuredAuthenticationConfiguration | | false | | Alpha | | 1.29 | | 1.29 |

| StructuredAuthenticationConfiguration | | true | | Beta | | 1.30 | | 1.33 |

| StructuredAuthenticationConfiguration | | true | | Stable | | 1.34 | | – |

| StructuredAuthorizationConfiguration | | false | | Alpha | | 1.29 | | 1.29 |

| StructuredAuthorizationConfiguration | | true | | Beta | | 1.30 | | 1.31 |

| StructuredAuthorizationConfiguration | | true | | Stable | | 1.32 | | – |

| TopologyAwareHints | | false | | Alpha | | 1.21 | | 1.22 |

| TopologyAwareHints | | false | | Beta | | 1.23 | | 1.23 |

| TopologyAwareHints | | true | | Beta | | 1.24 | | 1.32 |

| TopologyAwareHints | | true | | Stable | | 1.33 | | – |

| TopologyManagerPolicyOptions | | false | | Alpha | | 1.26 | | 1.27 |

| TopologyManagerPolicyOptions | | true | | Beta | | 1.28 | | 1.31 |

| TopologyManagerPolicyOptions | | true | | Stable | | 1.32 | | – |

| UserNamespacesSupport | | false | | Alpha | | 1.28 | | 1.29 |

| UserNamespacesSupport | | false | | Beta | | 1.30 | | 1.32 |

| UserNamespacesSupport | | true | | Beta | | 1.33 | | 1.35 |

| UserNamespacesSupport | | true | | Stable | | 1.36 | | – |

| VolumeAttributesClass | | false | | Alpha | | 1.29 | | 1.30 |

| VolumeAttributesClass | | false | | Beta | | 1.31 | | 1.33 |

| VolumeAttributesClass | | true | | Stable | | 1.34 | | 1.35 |

| VolumeAttributesClass | | true | | Stable | | 1.36 | | – |

| WatchCacheInitializationPostStartHook | | false | | Beta | | 1.31 | | 1.35 |

| WatchCacheInitializationPostStartHook | | true | | Beta | | 1.36 | | 1.36 |

| WatchCacheInitializationPostStartHook | | true | | Stable | | 1.37 | | – |

| WatchFromStorageWithoutResourceVersion | | false | | Beta | | 1.30 | | 1.32 |

| WatchFromStorageWithoutResourceVersion | | false | | Deprecated | | 1.33 | | – |

| WindowsHostNetwork | | true | | Alpha | | 1.26 | | 1.32 |

| WindowsHostNetwork | | false | | Deprecated | | 1.33 | | – |

| WinDSR | | false | | Alpha | | 1.14 | | 1.32 |

| WinDSR | | true | | Beta | | 1.33 | | 1.33 |

| WinDSR | | true | | Stable | | 1.34 | | – |

| WinOverlay | | false | | Alpha | | 1.14 | | 1.19 |

| WinOverlay | | true | | Beta | | 1.20 | | 1.33 |

| WinOverlay | | true | | Stable | | 1.34 | | – |

Using a feature

Feature stages

A feature can be in Alpha, Beta or GA stage.
An Alpha feature means:

* Disabled by default.

* Might be buggy. Enabling the feature may expose bugs.

* Support for feature may be dropped at any time without notice.

* The API may change in incompatible ways in a later software release without notice.

* Recommended for use only in short-lived testing clusters, due to increased
risk of bugs and lack of long-term support.

A Beta feature means:

* Usually enabled by default. Beta API groups are
disabled by default.

* The feature is well tested. Enabling the feature is considered safe.

* Support for the overall feature will not be dropped, though details may change.

* The schema and/or semantics of objects may change in incompatible ways in a
subsequent beta or stable release. When this happens, we will provide instructions
for migrating to the next version. This may require deleting, editing, and
re-creating API objects. The editing process may require some thought.
This may require downtime for applications that rely on the feature.

* Recommended for only non-business-critical uses because of potential for
incompatible changes in subsequent releases. If you have multiple clusters
that can be upgraded independently, you may be able to relax this restriction.

Note:
Please do try Beta features and give feedback on them!
After they exit beta, it may not be practical for us to make more changes.

A General Availability (GA) feature is also referred to as a stable feature. It means:

* The feature is always enabled; you cannot disable it.

* The corresponding feature gate is no longer needed.

* Stable versions of features will appear in released software for many subsequent versions.

List of feature gates

Each feature gate is designed for enabling/disabling a specific feature.
AllowDNSOnlyNodeCSR
Allow kubelet to request a certificate without any Node IP available, only with DNS names.
AllowInsecureKubeletCertificateSigningRequests
Disable node admission validation of
CertificateSigningRequests
for kubelet signers. Unless you disable this feature gate, Kubernetes enforces that new
kubelet certificates have a commonName matching system:node:$nodeName.
AllowParsingUserUIDFromCertAuth
When this feature is enabled, the subject name attribute 1.3.6.1.4.1.57683.2
in an X.509 certificate will be parsed as the user UID during certificate authentication.
AllowUnsafeMalformedObjectDeletion
Enables the cluster operator to identify corrupt resource(s) using the list
operation, and introduces an option ignoreStoreReadErrorWithClusterBreakingPotential
that the operator can set to perform unsafe and force delete operation of
such corrupt resource(s) using the Kubernetes API.
AnonymousAuthConfigurableEndpoints
Enable configurable endpoints for anonymous auth
for the API server.
AnyVolumeDataSource
Enable use of any custom resource as the DataSource of a
PVC.
APIResponseCompression
Compress the API responses for LIST or GET requests.
APIServerIdentity
Assign each API server an ID in a cluster, using a Lease.
APIServerTracing
Add support for distributed tracing in the API server.
See Traces for Kubernetes System Components for more details.
APIServerWebhookAuthenticationToken
Enables the kube-apiserver to issue short-lived, scoped ServiceAccount tokens
for authenticating to
admission webhooks.
These tokens are bound to a specific ValidatingWebhookConfiguration or
MutatingWebhookConfiguration and are scoped to particular API groups
via attestation claims in the
TokenRequest API.
APIServingWithRoutine
This feature gate enables an API server performance improvement:
the API server can use separate goroutines (lightweight threads managed by the Go runtime)
to serve watch
requests.
AtomicFIFO
A client-go implementation of a FIFO queue that uses atomic operations to ensure events that come in
batches, such as those from a ListAndWatch call, are processed in a single chunk. This is in contrast to
the previous implementation which would process these events one by one, potentially causing the internal
cache to become temporarily inconsistent with the API server. This feature gate can be toggled in the
kube-controller-manager and any client-go based controller.
AtomicWriteVolumeUserFields
This feature gate exists in the Kubernetes API server and kubelet.

Used from the kube-apiserver, it allows users to set the user and defaultUser fields
across configMap, secret, downwardAPI and projected volumes.

In kubelet, if the user or defaultUser fields are specified for a volume,
it sets the owner UID of the volume's data files during file creation.
AuthorizeNodeWithSelectors
Make the Node authorizer use fine-grained selector authorization.
AuthorizePodWebsocketUpgradeCreatePermission
When the AuthorizePodWebsocketUpgradeCreatePermission feature gate is true,
clients must be authorized to create Pod subresources even when triggering their
creation using a WebSocket.

The connection upgrade request occurs for each of the following subresources: pods/exec,
pods/attach, and pods/portforward. This feature gate fixes a security gap caused by
the protocol transition: while SPDY requests utilize HTTP POST (naturally aligning with
the create RBAC permission), the WebSocket protocol requires an HTTP GET request for
the handshake. To correct this defect, a synthetic RBAC check is now applied to ensure
WebSocket upgrades strictly enforce the create permission, matching the existing
SPDY security model.

You may want to disable this feature gate if you have existing clients or custom tooling
that rely on the previous behavior—specifically, if they connect via WebSockets but do not
currently hold the create RBAC permission.
AuthorizeWithSelectors
Allows authorization to use field and label selectors.
Enables fieldSelector and labelSelector fields in the SubjectAccessReview API,
passes field and label selector information to authorization webhooks,
enables fieldSelector and labelSelector functions in the authorizer CEL library,
and enables checking fieldSelector and labelSelector fields in authorization webhook matchConditions.
BtreeWatchCache
When enabled, the API server will replace the legacy HashMap-based watch cache
with a BTree-based implementation. This replacement may bring performance improvements.
CBORServingAndStorage
Enables CBOR as a supported encoding for requests and
responses, and as the preferred storage
encoding for custom resources.
ChangeContainerStatusOnKubeletRestart
Enable legacy writes to update container ready status after the kubelet detects a
restart.

This feature gate was introduced to allow you revert the behavior to a previously used default.
If you are satisfied with the default behavior, you do not need to enable this
feature gate.
ClearingNominatedNodeNameAfterBinding
Enable clearing .status.nominatedNodeName whenever Pods are bound to nodes.
CloudControllerManagerWatchBasedRoutesReconciliation
Enables a watch-based route reconciliation mechanism (rather than reconciling at a fixed interval)
within the cloud-controller-manager library.
CloudControllerManagerWebhook
Enable webhooks in cloud controller manager.
ClusterTrustBundle
This feature gate exists in the Kubernetes API server and the controller manager.

Used from the kube-apiserver, it enables ClusterTrustBundle support.

In the Kubernetes controller manager, it is used to control publishing of a ClusterTrustBundle
for the kubernetes.io/kube-apiserver-serving signer.
ClusterTrustBundleProjection
clusterTrustBundle projected volume sources.
ComponentFlagz
Enables the component's flagz endpoint.
See zpages for more information.
ComponentStatusz
Enables the component's statusz endpoint.
See zpages for more information.
CompositePodGroup
Enable hierarchical gang scheduling for CompositePodGroups and PodGroups.

Enabling the CompositePodGroup feature gate requires that the GenericWorkload and TopologyAwareWorkloadScheduling
feature gates are enabled as well.
ConcurrentWatchObjectDecode
Enable concurrent watch object decoding. This is to avoid starving the API server's
watch cache when a conversion webhook is installed.
ConsistentListFromCache
Enhance Kubernetes API server performance by serving consistent list requests
directly from its watch cache, improving scalability and response times.
To consistent list from cache Kubernetes requires a newer etcd version (v3.4.31+ or v3.5.13+),
that includes fixes to watch progress request feature.
If older etcd version is provided Kubernetes will automatically detect it and fallback to serving consistent reads from etcd.
Progress notifications ensure watch cache is consistent with etcd while reducing
the need for resource-intensive quorum reads from etcd.

See the Kubernetes documentation on Semantics for get and list for more details.
ConstrainedImpersonation
Enables impersonation that is constrained to specific requests instead of being all or nothing.
ContainerCheckpoint
Enables the kubelet checkpoint API.
See Kubelet Checkpoint API for more details.
ContainerRestartRules
Enables the ability to configure container-level restart policy and restart rules.
See Container Restart Policy and Rules for more details.
ContainerStopSignals
Enables usage of the StopSignal lifecycle for containers for configuring custom stop signals using which the containers would be stopped.
ContextualLogging
Enables extra details in log output of Kubernetes components that support
contextual logging.
ControllerManagerReleaseLeaderElectionLockOnExit
Enables the kube-controller-manager to actively release its leader election lock
during leader transitions, rather than waiting for the lock's TTL to expire.
This allows a new leader to be elected more quickly.
CoordinatedLeaderElection
Enables the behaviors supporting the LeaseCandidate API, and also enables
coordinated leader election for the Kubernetes control plane, deterministically.
CPUManagerPolicyAlphaOptions
This allows fine-tuning of CPUManager policies,
experimental, Alpha-quality options
This feature gate guards a group of CPUManager options whose quality level is alpha.
This feature gate will never graduate to beta or stable.
CPUManagerPolicyBetaOptions
This allows fine-tuning of CPUManager policies,
experimental, Beta-quality options
This feature gate guards a group of CPUManager options whose quality level is beta.
This feature gate will never graduate to stable.
CPUManagerPolicyOptions
Allow fine-tuning of CPUManager policies.
CRDObservedGenerationTracking
Allows for the observed generation to be tracked in CRD conditions. Setting to
false will make it so CRD conditions will have the observed generation wiped.
CRDValidationRatcheting
Enable updates to custom resources to contain
violations of their OpenAPI schema if the offending portions of the resource
update did not change. See Validation Ratcheting for more details.
CRIListStreaming
Enable streaming RPCs for CRI list operations (ListContainers,
ListPodSandbox, ListImages). When enabled, the kubelet uses server-side
streaming RPCs (e.g., StreamContainers, StreamPodSandboxes) that allow the
container runtime to divide results across multiple response messages,
bypassing the 16 MiB gRPC message size limit. This allows listing containers
on nodes with thousands of containers without failures. If the container
runtime does not support streaming RPCs, the kubelet falls back to unary RPCs.
CronJobsScheduledAnnotation
Set the scheduled job time as an
annotation on Jobs that were created
on behalf of a CronJob.
CrossNamespaceVolumeDataSource
Enable the usage of cross namespace volume data source
to allow you to specify a source namespace in the dataSourceRef field of a
PersistentVolumeClaim.
CSIServiceAccountTokenSecrets
Enables CSI drivers to opt-in for receiving service account tokens from kubelet
through the dedicated secrets field in NodePublishVolumeRequest instead of the volume_context field.
CSIVolumeHealth
Enable support for CSI volume health monitoring on node.
CustomCPUCFSQuotaPeriod
Enable nodes to change cpuCFSQuotaPeriod in
kubelet config.
CustomResourceFieldSelectors
Enable selectableFields in the
CustomResourceDefinition API to allow filtering
of custom resource list, watch and deletecollection requests.
DeclarativeValidation
Enables declarative validation of in-tree Kubernetes APIs. When enabled, APIs with declarative validation rules
(defined using IDL tags in the Go code) will have both the generated declarative validation code
and the original hand-written validation code executed.
The results are compared, and any discrepancies are reported via the declarative_validation_mismatch_total metric.
Only the hand-written validation result is returned to the user (eg: actually validates in the request path).
The original hand-written validation are still the authoritative validations
when this is enabled but this can be changed if the
DeclarativeValidationBeta feature gate
is enabled in addition to this gate.
This feature gate only operates on the kube-apiserver component.
DeclarativeValidationBeta
This feature gate acts as the Global Safety Switch for Beta-stage validation rules (+k8s:beta).
It allows cluster admins to disable enforcement for validations in the Beta stage if
regressions are found, forcing them back to Shadow mode.

In Shadow mode, declarative validation is executed and mismatches against handwritten
validation are logged as metrics, but failures do not reject requests.
Handwritten validation remains authoritative and enforced.

Enforcement logic for resources using WithDeclarativeEnforcement():

* Standard tags (no prefix): Always Enforced (Bypasses this gate).

* Beta tags (+k8s:beta): Enforced when this gate is enabled (default), otherwise Shadowed.

* Alpha tags (+k8s:alpha): Always Shadowed.

This gate has no effect if the master DeclarativeValidation feature gate is disabled.
DeclarativeValidationTakeover
Deprecated: in favor of DeclarativeValidationBeta.

When enabled, along with the DeclarativeValidation
feature gate, declarative validation errors are returned directly to the caller,
replacing hand-written validation errors for rules that have declarative implementations.
When disabled (and DeclarativeValidation is enabled), hand-written validation errors are always returned,
effectively putting declarative validation in a mismatch validation mode
that monitors but does not affect API responses.
This mismatch validation mode allows for the monitoring of the declarative_validation_mismatch_total
and declarative_validation_panic_total metrics which are implementation details for a safer rollout,
average user shouldn't need to interact with it directly.
This feature gate only operates on the kube-apiserver component.
Note: Although declarative validation aims for functional equivalence with hand-written validation,
the exact description of error messages may differ between the two approaches.
DefaultPodSysctls
Enables the defaultPodSysctls field in KubeletConfiguration, allowing Node administrators to specify a default set of namespaced kernel parameters (sysctls) that the kubelet applies to all Pods on the Node. See Setting Sysctls for All Pods for more details.
DeploymentReplicaSetTerminatingReplicas
Enables a new status field .status.terminatingReplicas in Deployments and ReplicaSets to allow tracking of terminating pods.
DetectCacheInconsistency
Enable cache inconsistency detection in the API server.
DisableAllocatorDualWrite
You can enable the MultiCIDRServiceAllocator feature gate. The API server supports migration
from the old bitmap ClusterIP allocators to the new IPAddress allocators.

The API server performs a dual-write on both allocators. This feature gate disables the dual write
on the new Cluster IP allocators; you can enable this feature gate if you have completed the
relevant stage of the migration.
DisableCPUQuotaWithExclusiveCPUs
When the feature gate DisableCPUQuotaWithExclusiveCPUs is enabled (the default), then Kubernetes
does not enforce CPU quota for Pods that use the Guaranteed
QoS class.

You can disable the DisableCPUQuotaWithExclusiveCPUs feature gate to restore the legacy behavior.
DisableNodeKubeProxyVersion
Disable setting the kubeProxyVersion field of the Node.
DRAAdminAccess
Enables support for requesting admin access
in a ResourceClaim or a ResourceClaimTemplate. Admin access grants access to
in-use devices and may enable additional permissions when making the device
available in a container. Starting with Kubernetes v1.33, only users authorized
to create ResourceClaim or ResourceClaimTemplate objects in namespaces labeled
with resource.kubernetes.io/admin-access: "true" (case-sensitive) can use the
adminAccess field. This ensures that non-admin users cannot misuse the
feature. Starting with Kubernetes v1.34, this label has been updated to resource.kubernetes.io/admin-access: "true".
DRAConsumableCapacity
Enables device sharing across multiple ResourceClaims or requests.

Additionally, if a device supports sharing, its resource (capacity) can be managed through a defined sharing policy.
DRADerivedAttributes
Enables derivedAttributes in Dynamic Resource Allocation (DRA), letting
ResourceClaim and ResourceClaimTemplate authors compute virtual device
attributes with per-device CEL expressions, for use in matchAttribute and
distinctAttribute constraints.

For more information, see
Derived attributes
in the DRA API Objects documentation.
DRADeviceBindingConditions
Enables support for DeviceBindingConditions in the DRA related fields.
This allows for thorough device readiness checks and attachment processes before Bind phase.
DRADeviceCompatibilityGroups
Enables support for device compatibility groups
in DRA. Drivers can declare opaque compatibility groups on each
consumesCounters entry of a device in a ResourceSlice, and the scheduler
only co-allocates devices drawing from the same counter set when their
declared groups intersect. Requires DRAPartitionableDevices to be enabled.
DRADeviceTaintRules
Enables support for
tainting devices through DeviceTaintRule objects
when using dynamic resource allocation to manage devices.

This feature gate has no effect unless you also enable the DRADeviceTaints feature gate.
DRADeviceTaints
Enables support for
tainting devices and selectively tolerating those taints
when using dynamic resource allocation to manage devices.
DRAExtendedResource
Enables support for the Extended Resource allocation by DRA feature.
It makes it possible to specify an extended resource name in a DeviceClass.
DRAListTypeAttributes
Enables list-type attribute fields (bools, ints, strings, versions) for devices
in ResourceSlice, allowing a device to advertise multiple values for a single attribute.

When enabled, matchAttribute uses set-intersection semantics (the sets of attribute
values across all selected devices must have a non-empty intersection), and
distinctAttribute uses pairwise-disjoint semantics (the sets must share no values).
Scalar attributes remain backward-compatible, treated as singleton sets.

Also adds the includes() helper function to CEL device selector expressions, which
works on both scalar and list-type attributes.

For more information, see
List type attributes
in the Dynamic Resource Allocation documentation.
DRANodeAllocatableResources
Enables the kube-scheduler to incorporate node allocatable resources (such as
CPU, memory, and hugepages) managed by Dynamic Resource Allocation (DRA) into
its standard node resource accounting.

When enabled, DRA drivers can use the nodeAllocatableResources field on
ResourceSlice devices to specify how their devices consume node allocatable
resources. This field supports two different use cases:

* mapping: For drivers that directly provide a native node resource (e.g., a CPU
or Memory DRA driver). It supports scaling capacities or device counts.

* overhead: For devices that require auxiliary node dependencies (e.g., an
accelerator that consumes host memory). It supports per-pod or per-container costs.

This allows the scheduler to combine these DRA allocations with standard Pod requests
to prevent node over-subscription during Pod admission.

It also exposes the status.nodeAllocatableResourceClaimStatuses field on the
Pod API to track the resulting resource allocations. The kubelet consumes this to
update Pod and container cgroup settings and adjust OOM scores.

For more information, see
Node Allocatable Resources
in the Dynamic Resource Allocation documentation.
DRAOptionalNodeOperations
Enables support for optional node-local operations in Dynamic Resource
Allocation (DRA). This allows drivers to declare that specific node operations
(NodePrepareResources and/or NodeUnprepareResources) can be skipped for
their devices, enabling the kubelet to bypass unnecessary gRPC calls.

For more information, see
Optional node operations
in the Dynamic Resource Allocation documentation.
DRAPartitionableDevices
Enables support for requesting Partitionable Devices
for DRA. This lets drivers advertise multiple devices that maps to the same resources
of a physical device.
DRAPartitionableDevicesType
Enables the PartitionTypeAttribute field on ResourceSlices, which opts a
partitionable
resource pool into the typed partition summary view of
ResourcePoolStatusRequest.
The field names a device attribute (such as a MIG profile) whose value groups
each partition type, so that a ResourcePoolStatusRequest can report how many
devices of each partition type are still allocatable. This builds on the
DRAPartitionableDevices
and
DRAResourcePoolStatus
feature gates, both of which must also be enabled.
DRAPrioritizedList
Allows specifying a prioritized list of alternative devices that can be allocated to a request in
a claim if the preferred alternative is not available.
DRAResourceClaimDeviceStatus
Enables support the ResourceClaim.status.devices field and for setting this
status from DRA drivers. It requires the DynamicResourceAllocation feature
gate to be enabled.
DRAResourceClaimGranularStatusAuthorization
Enables support for granular authorization of ResourceClaim status updates.
This feature requires additional fine-grained access permissions when modifying
specific fields within ResourceClaim status objects.
DRAResourcePoolStatus
Enables the ResourcePoolStatusRequest API for querying the
availability of devices in DRA resource pools.
When enabled, users can create ResourcePoolStatusRequest objects to get a
point-in-time snapshot of device availability (total, allocated, available, and
unavailable devices) for a specific driver and optionally a specific pool.
A controller in kube-controller-manager processes these one-time requests and
populates the status with pool information.
DRASchedulerFilterTimeout
Enables aborting the per-node filter operation in the scheduler after a certain
time (10 seconds by default, configurable in the DynamicResources scheduler
plugin configuration).
DRAWorkloadResourceClaims
Enables PodGroup resources from the
Workload API to make requests for
devices through
Dynamic Resource Allocation
that can be shared by their member Pods.
DynamicResourceAllocation
Enables support for resources with custom parameters and a lifecycle
that is independent of a Pod. Allocation of resources is handled
by the Kubernetes scheduler based on "structured parameters".
ElasticIndexedJob
Enables Indexed Jobs to be scaled up or down by mutating both
spec.completions and spec.parallelism together such that spec.completions == spec.parallelism.
See docs on elastic Indexed Jobs
for more details.
EmptyDirVolumeMode
Enables setting Unix permission bits on emptyDir volume directories using the
mode field in emptyDir volume sources. When enabled, users can specify a value
between 0000 and 01777 (octal) to control the directory permissions at creation
time. If mode is not specified, the default 0777 behavior is preserved.
EnvFiles
Support defining container's Environment Variable Values via File.
See Define Environment Variable Values Using An Init Container for more details.
EtcdRangeStream
Enables the kube-apiserver to use etcd's RangeStream RPC to stream large list
responses from etcd, instead of fetching them in a single Range response. This
reduces memory spikes in both etcd and the kube-apiserver when serving large
LIST requests.
EventedPLEG
Enable support for the kubelet to receive container life cycle events from the
container runtime via
an extension to CRI.
(PLEG is an abbreviation for “Pod lifecycle event generator”).
For this feature to be useful, you also need to enable support for container lifecycle events
in each container runtime running in your cluster. If the container runtime does not announce
support for container lifecycle events then the kubelet automatically switches to the legacy
generic PLEG mechanism, even if you have this feature gate enabled.
ExcludeAdmissionWebhookVirtualResources
Exclude non-persisted (virtual) authentication and authorization resources,
such as TokenReview and SubjectAccessReview, from admission webhooks.
This matches the set of resources that ValidatingAdmissionPolicy and
MutatingAdmissionPolicy already exclude, and prevents a misbehaving webhook
from blocking the cluster's own authentication and authorization requests.
Disable this feature gate to restore the previous behavior of dispatching
admission webhooks for these resources.
ExecProbeTimeout
Ensure kubelet respects exec probe timeouts.
This feature gate exists in case any of your existing workloads depend on a
now-corrected fault where Kubernetes ignored exec probe timeouts. See
readiness probes.
ExtendWebSocketsToKubelet
When ExtendWebSocketsToKubelet is enabled and a kubelet node advertises support,
exec/attach/portforward streams are proxied directly to the kubelet rather than
being translated or tunneled at the API server. Critically, the same
stream translation and tunneling handlers used at the API server are now set up
identically at the kubelet — the logic is simply moved closer to the container
runtime. This feature depends on NodeDeclaredFeatures graduating to beta so that
kubelet capability advertisement is reliable in production clusters.
ExternalServiceAccountTokenSigner
Enable setting --service-account-signing-endpoint to make the kube-apiserver use external signer for token signing and token verifying key management.
GenericWorkload
Enables support for the Workload API and PodGroup API to express scheduling requirements at the workload level.

When enabled, Pods can reference a specific PodGroup to influence the way that they are scheduled. Starting in Kubernetes v1.37, this feature gate also encompasses gang scheduling, and workload-aware preemption.
GitRepoVolumeDriver
This controls if the gitRepo volume plugin is supported or not.
The gitRepo volume plugin is disabled by default starting v1.33 release.
This provides a way for users to enable it.
GracefulNodeShutdown
Enables support for graceful shutdown in kubelet.
During a system shutdown, kubelet will attempt to detect the shutdown event
and gracefully terminate pods running on the node. See
Graceful Node Shutdown
for more details.
GracefulNodeShutdownBasedOnPodPriority
Enables the kubelet to check Pod priorities
when shutting down a node gracefully.
GRPCContainerProbeTLS
Enables TLS support for gRPC container probes. When enabled,
you can add the mode field to the grpc field in gRPC probes. Setting
mode: TLS on a liveness, readiness, or startup probe causes the kubelet
to connect over TLS (with InsecureSkipVerify).
See Configure Liveness, Readiness and Startup Probes.
H2CContainerProbe
Enables HTTP/2 cleartext (h2c) support for HTTP container probes. When enabled,
you can add the protocol field to the httpGet field in HTTP probes. Setting
protocol: HTTP2 on a liveness, readiness, or startup probe causes the kubelet to
probe over h2c instead of HTTP/1.1.
See Configure Liveness, Readiness and Startup Probes.
HostnameOverride
Allows setting any FQDN as the pod's hostname.
HPAConfigurableTolerance
Enables setting a tolerance threshold
for HorizontalPodAutoscaler metrics.
HPAScaleToZero
Enables setting minReplicas to 0 for HorizontalPodAutoscaler
resources when using custom or external metrics.
HugepageAwareEviction
Subtracts hugepage capacity from memory.available so the kubelet's eviction
signal reflects actual regular-memory availability. Without this gate, hugepage
reservations inflate AvailableBytes, delaying eviction and causing OOM kills
on nodes with hugepages configured.
ImageMaximumGCAge
Enables the kubelet configuration field imageMaximumGCAge, allowing an administrator to specify the age after which an image will be garbage collected.
ImageVolume
Allow using the image volume source in a Pod.
This volume source lets you mount a container image as a read-only volume.
ImageVolumeWithDigest
For each image volume in a Pod,
image digest as part of the pod's status.
InformerResourceVersion
Allow clients to use the LastSyncResourceVersion() call on informers, enabling
them to perform actions based on the current resource version. When disabled,
LastSyncResourceVersion() succeeds but returns an empty string. Used by
kube-controller-manager for StorageVersionMigration.
InOrderInformers
Force the informers to deliver watch stream events in order instead of out of order.
InPlacePodLevelResourcesVerticalScaling
Enables the in-place vertical scaling of resources for a Pod (For example, changing a
running Pod's pod-level CPU or memory requests/limits without needing to restart
it). For details, see the documentation on In-place Pod-level Resources Vertical Scaling.
InPlacePodVerticalScaling
Enables in-place Pod vertical scaling.
InPlacePodVerticalScalingAllocatedStatus
Enables the allocatedResources field in the container status.
This feature requires the InPlacePodVerticalScaling gate be enabled as well.
InPlacePodVerticalScalingExclusiveCPUs
Enable resource resizing for containers in Guaranteed pods with integer CPU requests.
It applies only in nodes with InPlacePodVerticalScaling and CPUManager features enabled,
and the CPUManager policy set to static.
InPlacePodVerticalScalingExclusiveMemory
Allow resource resize for containers in Guaranteed Pods when the memory manager policy is set to "Static".
Applies only to nodes with InPlacePodVerticalScaling and memory manager features enabled.
InPlacePodVerticalScalingMemoryBackedVolumes
Enables in-place vertical scaling for memory-backed emptyDir volume size limits.
InPlacePodVerticalScalingSchedulerPreemption
Enables scheduler preemption of lower-priority pods to fulfill deferred
in-place pod resize requests.
JobBackoffLimitPerIndex
Allows specifying the maximal number of pod
retries per index in Indexed jobs.
JobManagedBy
Allows to delegate reconciliation of a Job object to an external controller.
JobPodReplacementPolicy
Allows you to specify pod replacement for terminating pods in a Job
JobSuccessPolicy
Allow users to specify when a Job can be declared as succeeded based on the set of succeeded pods.
KMSv1
Enables KMS v1 API for encryption at rest. See
Using a KMS Provider for data encryption
for more details.
KubeletCgroupDriverFromCRI
Enable detection of the kubelet cgroup driver
configuration option from the CRI.
This feature gate is now on for all clusters. However, it only works on nodes
where there is a CRI container runtime that supports the RuntimeConfig
CRI call. If the CRI supports this feature, the kubelet ignores the
cgroupDriver configuration setting (or deprecated --cgroup-driver command
line argument). If the container runtime
doesn't support it, the kubelet falls back to using the driver configured using
the cgroupDriver configuration setting.
The kubelet will stop falling back to this configuration in Kubernetes 1.36.
Thus, users must upgrade their CRI container runtime to a version that supports
the RuntimeConfig CRI call by then. Admins can use the metric
kubelet_cri_losing_support to see if there are any nodes in their cluster that
will lose support in 1.36. The following CRI versions support this CRI call:

* containerd: Support was added in v2.0.0

* CRI-O: Support was added in v1.28.0

KubeletCrashLoopBackOffMax
Enables support for configurable per-node backoff maximums for restarting
containers in the CrashLoopBackOff state.
For more details, check the crashLoopBackOff.maxContainerRestartPeriod field in the
kubelet config file.
KubeletEnsureSecretPulledImages
Ensure that pods requesting an image are authorized to access the image
with the provided credentials when the image is already present on the node.
See Ensure Image Pull Credential Verification.
KubeletFineGrainedAuthz
Enable fine-grained authorization
for the kubelet's HTTP(s) API.
KubeletInUserNamespace
Enables support for running kubelet in a
user namespace.
See Running Kubernetes Node Components as a Non-root User.
KubeletPodResourcesDynamicResources
Extend the kubelet's
pod resources monitoring gRPC API
endpoints List and Get to include resources allocated in ResourceClaims
via Dynamic Resource Allocation.

Below is an example of GPU metrics to show how this API is consumed by
NVIDIA dcgm-exporter to collect per pod GPU metrics allocated by
NVIDIA DRA driver:

DCGM_FI_PROF_PCIE_RX_BYTES{gpu="0",UUID="GPU-a4f34abc-7715-3560-dcea-7238b9611a45",pci_bus_id="00000009:01:00.0",device="nvidia0",modelName="NVIDIA GH200 96GB HBM3",Hostname="sc-starwars-xxxx",container="ctr",dra_claim_name="single-gpu",dra_claim_namespace="gpu-test3",dra_device_name="gpu-0",dra_driver_name="gpu.nvidia.com",dra_pool_name="sc-starwars-xxxx",namespace="gpu-test3",pod="pod1"} 23792

DCGM_FI_PROF_PCIE_RX_BYTES{gpu="0",UUID="GPU-a4f34abc-7715-3560-dcea-7238b9611a45",pci_bus_id="00000009:01:00.0",device="nvidia0",modelName="NVIDIA GH200 96GB HBM3",Hostname="sc-starwars-xxxx",container="ctr",dra_claim_name="single-gpu",dra_claim_namespace="gpu-test3",dra_device_name="gpu-0",dra_driver_name="gpu.nvidia.com",dra_pool_name="sc-starwars-xxxx",namespace="gpu-test3",pod="pod2"} 23792

with Pod DRA info:

container="ctr",
dra_claim_name="single-gpu",
dra_claim_namespace="gpu-test3",
dra_device_name="gpu-0",dra_driver_name="gpu.nvidia.com",
dra_pool_name="sc-starwars-xxxx",
namespace="gpu-test3",
pod="pod1"

KubeletPodResourcesGet
Enable the Get gRPC endpoint on kubelet's for Pod resources.
This API augments the resource allocation reporting.
KubeletPSI
Enable kubelet to surface Pressure Stall Information (PSI) metrics in the Summary API and Prometheus metrics.
KubeletSeparateDiskGC
The split image filesystem feature enables kubelet to perform garbage collection
of images (read-only layers) and/or containers (writeable layers) deployed on
separate filesystems.
KubeletServiceAccountTokenForCredentialProviders
Enable kubelet to send the service account token bound to the pod for which the image is being pulled to the credential provider plugin.
KubeletTracing
Add support for distributed tracing in the kubelet.
When enabled, kubelet CRI interface and authenticated http servers are instrumented to generate
OpenTelemetry trace spans.
See Traces for Kubernetes System Components for more details.
KubeProxyIPVS
Enable support for the deprecated ipvs proxy mode in kube-proxy.
KubeProxyNFTablesLocalhostNodePorts
Enables localhost NodePort Service proxying with the nftables mode of
kube-proxy.
ListFromCacheSnapshot
Enables the API server to generate snapshots for the watch cache store and using them to serve LIST requests.
LocalStorageCapacityIsolationFSQuotaMonitoring
When LocalStorageCapacityIsolation
is enabled for
local ephemeral storage,
the backing filesystem for emptyDir volumes supports project quotas,
and UserNamespacesSupport is enabled,
project quotas are used to monitor emptyDir volume storage consumption rather than using filesystem walk, ensuring better performance and accuracy.
LogarithmicScaleDown
Enable semi-random selection of pods to evict on controller scaledown
based on logarithmic bucketing of pod timestamps.
LoggingAlphaOptions
Allow fine-tuning of experimental, alpha-quality logging options.
LoggingBetaOptions
Allow fine-tuning of experimental, beta-quality logging options.
ManifestBasedAdmissionControlConfig
Enable loading admission webhooks and CEL-based admission policies from
static manifest files on disk via the staticManifestsDir field in
AdmissionConfiguration. These policies are active from API server startup,
survive etcd unavailability, and can protect API-based admission resources
from modification.
MatchLabelKeysInPodAffinity
Enable the matchLabelKeys and mismatchLabelKeys fields for
pod (anti)affinity.
MatchLabelKeysInPodTopologySpread
Enable the matchLabelKeys field for
Pod topology spread constraints.
MatchLabelKeysInPodTopologySpreadSelectorMerge
Enable merging of selectors built from matchLabelKeys into labelSelector of
Pod topology spread constraints.
This feature gate can be enabled when matchLabelKeys feature is enabled with the MatchLabelKeysInPodTopologySpread feature flag.
MaxUnavailableStatefulSet
Enables setting the maxUnavailable field for the
rolling update strategy
of a StatefulSet. The field specifies the maximum number of Pods
that can be unavailable during the update.
MemoryManager
Allows setting memory affinity for a container based on
NUMA topology.
MemoryQoS
Enable memory protection and usage throttling for Pods and containers using
the cgroup v2 memory controller. When memoryThrottlingFactor is set, the
kubelet sets memory.high for throttling on Burstable and BestEffort
containers. The kubelet optionally sets memory.min and memory.low for
tiered memory protection when memoryReservationPolicy is set to
TieredReservation. Feature requires both - feature gate enablement and
kubelet configuration setting.
MultiCIDRServiceAllocator
Track IP address allocations for Service cluster IPs using IPAddress objects.
MutableCSINodeAllocatableCount
Make the .spec.drivers[*].allocatable.count field of a CSINode mutable.
Also, enable a CSIDriver field, nodeAllocatableUpdatePeriodSeconds.

This allows periodic updates to a node's reported allocatable volume capacity,
preventing stateful pods from becoming stuck due to outdated information
that the kube-scheduler would otherwise rely upon.
MutablePodResourcesForSuspendedJobs
Enable the ability to patch pod templates for suspended Jobs, in order to change requests or limits for infrastructure resources.
MutablePVNodeAffinity
Allow update to the .spec.nodeAffinity field of a PersistentVolume.
See Updates to node affinity for more details.
MutableSchedulingDirectivesForSuspendedJobs
Enable the ability to patch pod templates for suspended Jobs, in order to change the pod scheduling directives.
MutatingAdmissionPolicy
Enable MutatingAdmissionPolicy support, which allows
CEL mutations to
be applied during admission control.

For Kubernetes v1.30 and v1.31, this feature gate existed but had no effect.
NativeHistograms
Enables Kubernetes components to expose metrics in Prometheus Native Histogram format for improved efficiency and finer bucket resolution.
See Native Histograms for more information.
NFTablesProxyMode
Allow running kube-proxy in nftables mode.
NodeDeclaredFeatures
Enables Nodes to report supported features via their .status. This enables the
scheduler and admission controller to prevent operations on nodes lacking features
required by the Pod. See Node Declared Features.
NodeInclusionPolicyInPodTopologySpread
Enable using nodeAffinityPolicy and nodeTaintsPolicy in
Pod topology spread constraints
when calculating pod topology spread skew.
NodeLifecycleConditions
Enables well-known Node conditions that report drain, maintenance, and
Graceful Node Shutdown
lifecycle state. See
Node lifecycle conditions.
NodeLogQuery
Enables querying logs of node services using the /logs endpoint.
NodeSwap
Enable the kubelet to allocate swap memory for Kubernetes workloads on a node.
Must be used with KubeletConfiguration.failSwapOn set to false.
For more details, please see swap memory
NominatedNodeNameForExpectation
When enabled, kube-scheduler uses .status.nominatedNodeName to express where a
Pod is going to be bound. The .status.nominatedNodeName field is set when kube-scheduler
triggers preemption of pods, or anticipates that WaitOnPermit or PreBinding phase will take
relatively long.
Other components may read and use .status.nominatedNodeName, but should not set it.

When disabled, kube-scheduler will only set .status.nominatedNodeName before triggering preemption.
OpenAPIEnums
Enables populating "enum" fields of OpenAPI schemas in the
spec returned from the API server.
OpportunisticBatching
Enable reusing of scheduling results from the previous scheduling cycle for equivalent pods.
OrderedNamespaceDeletion
While deleting namespace, the pods resources is going to be deleted before the rest of resources.
PersistentVolumeClaimUnusedSinceTime
When enabled, the PVC protection controller adds an Unused condition to
PersistentVolumeClaims that tracks whether the PVC is currently referenced by
any non-terminal Pod. The condition's lastTransitionTime records when the PVC
last transitioned between being in use and being unused.
PodAndContainerStatsFromCRI
Configure the kubelet to gather container and pod stats from the CRI container runtime rather than gathering them from cAdvisor.
As of 1.26, this also includes gathering metrics from CRI and emitting them over /metrics/cadvisor (rather than having cAdvisor emit them directly).
PodCertificateRequest
Enable PodCertificateRequest objects and podCertificate projected volume
sources.
PodDeletionCost
Enable the Pod Deletion Cost
feature which allows users to influence ReplicaSet downscaling order.
PodGroupPreemptionPolicy
Enables the support for PreemptionPolicy field in PodGroup API and Workload API.

When enabled, if a PodGroup has PreemptionPolicy: Never it will not perform workload aware preemption.
PodIndexLabel
Enables the Job controller and StatefulSet controller to add the pod index as a label when creating new pods. See Job completion mode docs and StatefulSet pod index label docs for more details.
PodLevelResourceManagers
Enable Pod-level resource managers: the ability for the Topology, CPU, and
Memory managers to use information from .spec.resources to perform NUMA
alignment for an entire pod and manage resources flexibly for the containers
within that pod.
PodLevelResources
Enable Pod level resources: the ability to specify resource requests and limits
at the Pod level, rather than only for specific containers.
PodLifecycleSleepAction
Enables the sleep action in Container lifecycle hooks (preStop and postStart).
PodLifecycleSleepActionAllowZero
Enables setting zero value for the sleep action in
container lifecycle hooks.
PodLogsQuerySplitStreams
Enable fetching specific log streams (either stdout or stderr) from a container's log streams, using the Pod API.
PodObservedGenerationTracking
Enables the kubelet to set observedGeneration in the Pod .status, and enables other components to set observedGeneration in pod conditions.
This feature allows reflecting the .metadata.generation of the Pod at the time that the overall status, or some specific condition, was being recorded.
Storing it helps avoid risks associated with lost updates.
PodReadyToStartContainersCondition
Enable the kubelet to mark the PodReadyToStartContainers condition on pods.

This feature gate was previously known as PodHasNetworkCondition, and the associated condition was
named PodHasNetwork.
PodsAPI
Enables the kubelet Pods API gRPC service.
See Kubelet Pods API for more details.
PodSchedulingReadiness
Enable setting schedulingGates field to control a Pod's scheduling readiness.
PodTopologyLabelsAdmission
Enables the PodTopologyLabels admission plugin.
See Pod Topology Labels
for details.
PortForwardWebsockets
Allow WebSocket streaming of the
portforward sub-protocol (port-forward) from clients requesting
version v2 (v2.portforward.k8s.io) of the sub-protocol.
PreferSameTrafficDistribution
Allows usage of the values PreferSameZone and PreferSameNode in
the Service trafficDistribution
field.
PreventStaticPodAPIReferences
Denies Pod admission if static Pods reference other API objects.
ProcMountType
Enables control over the type proc mounts for containers
by setting the procMount field of a Pod's securityContext.
QOSReserved
Allows resource reservations at the QoS level preventing pods
at lower QoS levels from bursting into resources requested at higher QoS levels
(memory only for now).
RecoverVolumeExpansionFailure
Enables users to edit their PVCs to smaller
sizes so as they can recover from previously issued volume expansion failures.
See Recovering from Failure when Expanding Volumes
for more details.
RecursiveReadOnlyMounts
Enables support for recursive read-only mounts.
For more details, see read-only mounts.
ReduceDefaultCrashLoopBackOffDecay
Enabled reduction of both the initial delay and the maximum delay accrued
between container restarts for a node for containers in CrashLoopBackOff
across the cluster to 1s initial delay and 60s maximum delay.
RelaxedDNSSearchValidation
Relax the server side validation for the DNS search string
(.spec.dnsConfig.searches) for containers. For example,
with this gate enabled, it is okay to include the _ character
in the DNS name search string.
RelaxedEnvironmentVariableValidation
Allow almost all printable ASCII characters in environment variables.
RelaxedServiceNameValidation
Enables relaxed validation for Service object names, allowing the use of RFC 1123 label names instead of RFC 1035 label names.

This feature allows Service object names to start with a digit.
ReloadKubeletServerCertificateFile
Enable the kubelet TLS server to update its certificate if the specified certificate file are changed.

This feature is useful when specifying tlsCertFile and tlsPrivateKeyFile in kubelet configuration.
The feature gate has no effect for other cases such as using TLS bootstrap.
RemoteRequestHeaderUID
Enable the API server to accept UIDs (user IDs) via request header authentication.
This will also make the kube-apiserver's API aggregator add UIDs via standard headers when
forwarding requests to the servers serving the aggregated API.
ResilientWatchCacheInitialization
Enables resilient watchcache initialization to avoid controlplane overload.
ResourceHealthStatus
Enable the allocatedResourcesStatus field within the .status for a Pod. The field
reports additional details for each container in the Pod,
with the health information for each device assigned to the Pod.

Starting in v1.36 (beta), the health report includes an optional message field that
provides additional human-readable context about the health status, such as error details
or failure reasons.

This feature applies to devices managed by both Device Plugins and Dynamic Resource Allocation. See Device plugin and unhealthy devices for more details.
RestartAllContainersOnContainerExits
Enables the ability to specify
RestartAllContainers as an action in container restartPolicyRules. When a container's exit matches a rule with this action, the entire Pod is terminated and restarted in-place.

RestartAllContainersOnContainerExits depends on both the ContainerRestartRules and NodeDeclaredFeatures feature gates. If the dependent feature gates are not enabled, kubelet startup can fail.

See Restart All Containers for more details.
RetryGenerateName
Enables retrying of object creation when the
API server
is expected to generate a name.

When this feature is enabled, requests using generateName are retried automatically in case the
control plane detects a name conflict with an existing object, up to a limit of 8 total attempts.
RotateKubeletServerCertificate
Enable the rotation of the server TLS certificate on the kubelet.
See kubelet configuration
for more details.
RuntimeClassInImageCriApi
Enables images to be pulled based on the runtime class
of the pods that reference them.
SchedulerAsyncAPICalls
Change the kube-scheduler to make the entire scheduling cycle free of blocking requests to the Kubernetes API server.
Instead, interact with the Kubernetes API using asynchronous code.
SchedulerAsyncPreemption
Enable running some expensive operations within the scheduler, associated with
preemption, asynchronously.
Asynchronous processing of preemption improves overall Pod scheduling latency.
SchedulerPopFromBackoffQ
Improves scheduling queue behavior by popping pods from the backoffQ when the activeQ is empty.
This allows to process potentially schedulable pods ASAP, eliminating a penalty effect of the backoff queue.
SchedulerQueueingHints
Enables scheduler queueing hints,
which benefits to reduce the useless requeuing.
The scheduler retries scheduling pods if something changes in the cluster that could make the pod scheduled.
Queueing hints are internal signals that allow the scheduler to filter the changes in the cluster
that are relevant to the unscheduled pod, based on previous scheduling attempts.
SELinuxChangePolicy
Enables spec.securityContext.seLinuxChangePolicy field.
This field can be used to opt-out from applying the SELinux label to the pod
volumes using mount options. This is required when a single volume that supports
mounting with SELinux mount option is shared between Pods that have different
SELinux labels, such as a privileged and unprivileged Pods.

Enabling the SELinuxChangePolicy feature gate requires the feature gate SELinuxMountReadWriteOncePod to
be enabled.
SELinuxMount
Speeds up container startup by allowing kubelet to mount volumes
for a Pod directly with the correct SELinux label instead of changing each file on the volumes
recursively.
It widens the performance improvements behind the SELinuxMountReadWriteOncePod
feature gate by extending the implementation to all volumes.
SELinuxMountReadWriteOncePod
Speeds up container startup by allowing kubelet to mount volumes
for a Pod directly with the correct SELinux label instead of changing each file on the volumes
recursively. The initial implementation focused on ReadWriteOncePod volumes.
SeparateCacheWatchRPC
Allows the API server watch cache to create a watch on a dedicated RPC.
This prevents watch cache from being starved by other watches.
SeparateTaintEvictionController
Enables running the taint based eviction controller,
that performs Taint-based Evictions,
as a standalone controller (separate from the node lifecycle controller).
ServiceAccountNodeAudienceRestriction
This gate is used to restrict the audience for which the kubelet can request a service account token for.
ServiceAccountTokenJTI
Controls whether JTIs (UUIDs) are embedded into generated service account tokens,
and whether these JTIs are recorded into the Kubernetes audit log for future requests made by these tokens.
ServiceAccountTokenNodeBinding
Controls whether the API server allows binding service account tokens to Node objects.
ServiceAccountTokenNodeBindingValidation
Controls whether the apiserver will validate a Node reference in service account tokens.
ServiceAccountTokenPodNodeInfo
Controls whether the apiserver embeds the node name and uid
for the associated node when issuing service account tokens bound to Pod objects.
ServiceTrafficDistribution
Allows usage of the optional spec.trafficDistribution field in Services. The
field offers a way to express preferences for how traffic is distributed to
Service endpoints.
ShardedListAndWatch
Enable support for the shardSelector parameter on list and watch requests,
allowing clients to receive a filtered subset of objects based on hash ranges of
metadata fields (such as UID). See
Sharded list and watch
for more details.
SidecarContainers
Allow setting the restartPolicy of an init container to
Always so that the container becomes a sidecar container (restartable init containers).
See Sidecar containers and restartPolicy
for more details.
SizeBasedListCostEstimate
Enables APF to use size of objects for estimating request cost.
StaleControllerConsistencyDaemonSet
Enables behavior within the DaemonSet controller to ensure that prior writes to
the API server are observed before proceeding with additional reconciliation for the same DaemonSet.
This is to prevent stale cache from causing incorrect or spurious updates to the DaemonSet.
StaleControllerConsistencyJob
Enables behavior within the Job controller to ensure that prior writes to
the API server are observed before proceeding with additional reconciliation for the same Job.
This is to prevent stale cache from causing incorrect or spurious updates to the Job.
StaleControllerConsistencyReplicaSet
Enables behavior within the ReplicaSet controller to ensure that prior writes to
the API server are observed before proceeding with additional reconciliation for the same ReplicaSet.
This is to prevent stale cache from causing incorrect or spurious updates to the ReplicaSet.
StaleControllerConsistencyStatefulSet
Enables behavior within the StatefulSet controller to ensure that prior writes to
the API server are observed before proceeding with additional reconciliation for the same StatefulSet.
This is to prevent stale cache from causing incorrect or spurious updates to the StatefulSet.
StatefulSetAutoDeletePVC
Allows the use of the optional .spec.persistentVolumeClaimRetentionPolicy field,
providing control over the deletion of PVCs in a StatefulSet's lifecycle.
See
PersistentVolumeClaim retention
for more details.
StatefulSetRecreateStrategy
Enables the Recreate update strategy for StatefulSets, which deletes all of a
StatefulSet's Pods before creating new Pods that reflect modifications made to the
StatefulSet's .spec.template. See
Recreate for details.
StatefulSetStartOrdinal
Allow configuration of the start ordinal in a
StatefulSet. See
Start ordinal
for more details.
StorageCapacityScoring
The feature gate VolumeCapacityPriority was used in v1.32 to support storage that are
statically provisioned. Starting from v1.33, the new feature gate StorageCapacityScoring
replaces the old VolumeCapacityPriority gate with added support to dynamically provisioned storage.
When StorageCapacityScoring is enabled, the VolumeBinding plugin in the kube-scheduler is extended
to score Nodes based on the storage capacity on each of them.
This feature is applicable to CSI volumes that supported Storage Capacity,
including local storage backed by a CSI driver.
StorageNamespaceIndex
Enables a namespace indexer for namespace scoped resources
in API server cache to accelerate list operations.
StorageVersionAPI
Enable the
storage version API.
StorageVersionHash
Allow API servers to expose the storage version hash in the
discovery.
StorageVersionMigrator
Enables the migration of the storage
version of a
resource.
StreamingCollectionEncodingToJSON
Allow the API server JSON encoder to encode collections item by item, instead of all at once.
StreamingCollectionEncodingToProtobuf
Allow the API server Protobuf encoder to encode collections item by item, instead of all at once.
StrictCostEnforcementForVAP
Apply strict CEL cost validation for ValidatingAdmissionPolicies.
StrictCostEnforcementForWebhooks
Apply strict CEL cost validation for matchConditions within
admission webhooks.
StrictIPCIDRValidation
Use stricter validation for fields containing IP addresses and CIDR values.

In particular, with this feature gate enabled, octets within IPv4 addresses are
not allowed to have any leading 0s, and IPv4-mapped IPv6 values (e.g.
::ffff:192.168.0.1) are forbidden. These sorts of values can potentially cause
security problems when different components interpret the same string as
referring to different IP addresses (as in CVE-2021-29923).

This tightening applies only to fields in build-in API kinds, and not to
custom resource kinds, values in Kubernetes configuration files, or
command-line arguments.
StructuredAuthenticationConfiguration
Enable structured authentication configuration
for the API server.
StructuredAuthenticationConfigurationEgressSelector
Enables Egress Selector in Structured Authentication Configuration.
StructuredAuthenticationConfigurationJWKSMetrics
Enables additional metrics for JSON Web Key Set (JWKS) operations in JWT authenticators
configured via --authentication-config. When enabled, the API server records metrics about
the last time JWKS was fetched and the hash value of the JWKS response.
See the metrics reference for details.
StructuredAuthorizationConfiguration
Enable structured authorization configuration, so that cluster administrators
can specify more than one authorization webhook
in the API server handler chain.
SupplementalGroupsPolicy
Enables support for fine-grained SupplementalGroups control.
For more details, see Configure fine-grained SupplementalGroups control for a Pod.
SystemdWatchdog
Allow using systemd watchdog to monitor the health status of kubelet.
See Kubelet Systemd Watchdog
for more details.
TaintTolerationComparisonOperators
Enables numeric comparison operators (Lt and Gt) for
tolerations.
TokenRequestServiceAccountUIDValidation
This is used to ensure that the UID provided in the TokenRequest matches
the UID of the ServiceAccount for which the token is being requested.
It helps prevent misuse of the TokenRequest API by ensuring that
tokens are only issued for the correct ServiceAccount.
TopologyAwareHints
Enables topology aware routing based on topology hints
in EndpointSlices. See Topology Aware
Hints for more
details.
TopologyAwareWorkloadScheduling
Enable topology-aware scheduling for Workloads.
TopologyManagerPolicyAlphaOptions
Allow fine-tuning of topology manager policies,
experimental, Alpha-quality options.
This feature gate guards a group of topology manager options whose quality level is alpha.
This feature gate will never graduate to beta or stable.
TopologyManagerPolicyBetaOptions
Allow fine-tuning of topology manager policies,
experimental, Beta-quality options.
This feature gate guards a group of topology manager options whose quality level is beta.
This feature gate will never graduate to stable.
TopologyManagerPolicyOptions
Enable fine-tuning
of topology manager policies.
TranslateStreamCloseWebsocketRequests
Allow WebSocket streaming of the
remote command sub-protocol (exec, cp, attach) from clients requesting
version 5 (v5) of the sub-protocol.
UnauthenticatedHTTP2DOSMitigation
Enables HTTP/2 Denial of Service (DoS) mitigations for unauthenticated clients.
Kubernetes v1.28.0 through v1.28.2 do not include this feature gate.
UnknownVersionInteroperabilityProxy
Proxy resource requests to the correct peer kube-apiserver when
multiple kube-apiservers exist at varied versions.
See Mixed version proxy for more information.
UnlockWhileProcessingFIFO
Enable use of a FIFO queue within client-go that unlocks while processing events. If not enabled,
the queue instead holds the lock for the entire duration of processing events, which could lead
to performance issues in high-throughput scenarios. This feature gate can be toggled in the
kube-controller-manager and any client-go based controller.

You can only enable this feature gate if the
AtomicFIFO feature gate is also enabled.
UserNamespacesHostNetworkSupport
When enabled, pods are allowed to use both hostNetwork and User Namespaces simultaneously.
UserNamespacesSupport
Enable user namespace support for Pods.
VolumeAttributesClass
Enable support for VolumeAttributesClasses.
See Volume Attributes Classes
for more information.
VolumeBindMountOptions
Enables setting bind mount options (noexec, nodev, nosuid) per container
volume mount using the bindMountOptions field in volumeMounts. When enabled,
the kubelet passes these options to the container runtime, which applies them as
Linux bind mount flags. The container runtime must support the mount_options
field in the CRI Mount message. This field has no effect on Windows nodes.
VolumeLimitScaling
Enables volume limit scaling for CSI drivers. This allows scheduler to
co-ordinate better with cluster-autoscaler for storage limits.
See Storage Limits
for more information.
WatchCacheInitializationPostStartHook
Enables post-start-hook for watchcache initialization to be part of readyz (with timeout).
WatchFromStorageWithoutResourceVersion
Enables watches without resourceVersion to be served from storage.
WatchList
Enable support for streaming initial state of objects in watch requests.
WatchListClient
Allows an API client to request a stream of data rather than fetching a full list.
This functionality is available in client-go and requires the
WatchList
feature to be enabled on the server.
If the WatchList is not supported on the server, the client will seamlessly fall back to a standard list request.
WindowsCPUAndMemoryAffinity
Add CPU and Memory Affinity support to Windows nodes with CPUManager,
MemoryManager
and topology manager.
WindowsGracefulNodeShutdown
Enables support for windows node graceful shutdown in kubelet.
During a system shutdown, kubelet will attempt to detect the shutdown event
and gracefully terminate pods running on the node. See
Graceful Node Shutdown
for more details.
WindowsHostNetwork
Enables support for joining Windows containers to a hosts' network namespace.
WinDSR
Allows kube-proxy to create DSR loadbalancers for Windows.
WinOverlay
Allows kube-proxy to run in overlay mode for Windows.
WorkloadWithJob
Enables the Job controller to compile a Job's .spec.scheduling configuration into
Workload and PodGroup
objects before it creates any Pods.
When .spec.scheduling is omitted, the Job defaults to the Basic scheduling policy. See
Integrate with Workload APIs
for details.

What's next

* The deprecation policy for Kubernetes explains
the project's approach to removing features and components.

* Since Kubernetes 1.24, new beta APIs are not enabled by default. When enabling a beta
feature, you will also need to enable any associated API resources.
For example, to enable a particular resource like
storage.k8s.io/v1beta1/csistoragecapacities, set --runtime-config=storage.k8s.io/v1beta1/csistoragecapacities.
See API Versioning for more details on the command line flags.

* See Configure Feature Gates
for step-by-step guidance on enabling feature gates.

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

Last modified January 27, 2026 at 10:03 AM PST: fix: currentVersion skew in feature flag docs (#54170) (8d4885bbb0)
