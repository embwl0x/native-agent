import { ProtocolError } from "./protocol.js";

const GROUP_TITLE = "NativeAgent";

export function tabNotOwnedError(tabId, reason) {
  const message = reason === "tab_missing" ? `No tab ${tabId} exists any more (tab_missing).`
    : reason === "tab_active" ? "The person selected this tab, so it is theirs now (tab_active)."
    : reason === "outside_group" || reason === "group_changed" ? `This tab left the NativeAgent group (${reason}).`
    : `This tab is the person's own now (${reason}).`;
  return new ProtocolError("tab_not_owned", message, { reason });
}

// Chrome's group is the authority. This map holds only page-safety sequences
// and their release cause, plus tab metadata; requireTab checks Chrome again.
export class BrowserWorkspace {
  constructor(chromeApi, ownershipEnded, tabsChanged) {
    this.chrome = chromeApi;
    this.ownershipEnded = ownershipEnded;
    this.tabsChanged = tabsChanged;
    this.lastProjection = null;
    this.tabs = new Map();
    this.yielding = new Map();
    this.tabStates = new Map();
    this.groupIds = new Set();
  }

  tabForId(tabId) { return this.tabs.get(tabId); }

  remember(tab) {
    const value = { tabId: tab.id, windowId: tab.windowId, groupId: tab.groupId,
      title: tab.title ?? "", url: tab.url ?? "", audible: tab.audible === true, mutedInfo: tab.mutedInfo ?? null,
      userSequence: this.tabStates.get(tab.id)?.userSequence ?? 0 };
    this.tabStates.set(tab.id, { userSequence: value.userSequence });
    this.tabs.set(tab.id, value);
    return value;
  }

  publish() {
    const tabs = [...this.tabs.values()].sort((a, b) => a.tabId - b.tabId);
    const projection = JSON.stringify(tabs);
    if (projection === this.lastProjection) return;
    this.lastProjection = projection;
    this.tabsChanged(tabs);
  }

  // Old groups were presentation, not authority. Keep only proved ownership.
  async migrateLegacyCustody() {
    if (!this.legacyMigration) this.legacyMigration = this.migrateLegacyCustodyLocked().catch(error => {
      this.legacyMigration = null;
      throw error;
    });
    return this.legacyMigration;
  }

  async migrateLegacyCustodyLocked() {
    const custody = "nativeAgentTabCustodyV1", leases = "nativeAgentTabLeasesV1", reload = "nativeAgentExtensionReloadV1";
    const marker = "nativeAgentGroupAuthorityV1";
    const local = await this.chrome.storage.local.get([reload, marker]);
    if (local[marker] === true) return;
    const session = await this.chrome.storage.session.get([custody, leases]);
    const stores = [session, local[reload]?.session ?? {}];
    const custodyRows = stores.flatMap(store => Array.isArray(store[custody]) ? store[custody] : []);
    const leaseRows = stores.flatMap(store => Array.isArray(store[leases]) ? store[leases] : []);
    // Group-authority releases already removed these stores; their groups are owned.
    const groups = stores.some(store => Object.hasOwn(store, custody) || Object.hasOwn(store, leases))
      ? await this.chrome.tabGroups.query({ title: GROUP_TITLE }) : [];
    for (const group of groups) for (const tab of await this.chrome.tabs.query({ groupId: group.id })) {
      const records = custodyRows.filter(row => row?.tabId === tab.id);
      const proved = records.length ? records.every(row => row.userOwned === false && !row.unverifiedNavigation
        && ["created", "claimed", "adopted"].includes(row.ownership) && row.lastAgentURL === (tab.url ?? ""))
        : leaseRows.some(row => row?.tabId === tab.id && row.windowId === tab.windowId
          && typeof row.leaseId === "string" && /^[A-Za-z0-9._:-]{1,128}$/.test(row.leaseId)
          && ["created", "claimed", "adopted"].includes(row.ownership)
          && (row.renderingMode === undefined || (row.renderingMode === "visible_work_window" && row.ownership === "created"))
          && row.state === "active" && Number.isInteger(row.userSequence) && row.userSequence >= 0
          && Number.isFinite(Date.parse(row.createdAt)) && Number.isFinite(Date.parse(row.renewedAt))
          && Number.isFinite(Date.parse(row.expiresAt))
          && (Date.parse(row.expiresAt) > Date.now() || (Number.isFinite(row.pausedRemainingMs) && row.pausedRemainingMs > 0))
          && typeof row.originalTab?.active === "boolean" && typeof row.originalTab?.title === "string"
          && typeof row.originalTab?.url === "string");
      if (!proved || tab.active) await this.chrome.tabs.ungroup(tab.id);
    }
    // Checkpoint only after every hand-back succeeds; keep evidence on failure.
    await this.chrome.storage.local.set({ [marker]: true });
    await this.chrome.storage.session.remove([custody, leases]);
    await this.chrome.storage.local.remove(reload);
  }

  async refresh() {
    await this.migrateLegacyCustody();
    for (const [tabId, entry] of [...this.yielding]) await this.yieldForTab(tabId, entry.reason);
    const groups = await this.chrome.tabGroups.query({ title: GROUP_TITLE });
    this.groupIds = new Set(groups.map(group => group.id));
    const tabs = (await Promise.all(groups.map(group => this.chrome.tabs.query({ groupId: group.id })))).flat();
    const owned = new Set();
    for (const tab of tabs) {
      if (this.groupIds.has(tab.groupId) && !this.yielding.has(tab.id)) {
        // A reload can miss activation. The selected grouped tab is now User's.
        if (tab.active) { await this.yieldForTab(tab.id, "tab_active"); continue; }
        owned.add(tab.id);
        this.remember(tab);
      }
    }
    for (const id of [...this.tabs.keys()]) if (!owned.has(id)) this.endOwnership(id, "outside_group");
    this.publish();
  }

  async requireTab(tabId) {
    await this.migrateLegacyCustody();
    const unfinished = this.yielding.get(tabId);
    if (unfinished) await this.yieldForTab(tabId, unfinished.reason);
    const tab = await this.currentTab(tabId);
    if (!tab) {
      this.endOwnership(tabId, "tab_missing");
      throw tabNotOwnedError(tabId, "tab_missing");
    }
    if (tab.active && tab.groupId >= 0) {
      await this.yieldForTab(tabId, "tab_active");
      throw tabNotOwnedError(tabId, "tab_active");
    }
    let reason = this.tabStates.get(tabId)?.reason ?? "outside_group";
    if (tab && !this.yielding.has(tabId) && tab.groupId >= 0) {
      const group = await this.currentGroup(tab.groupId);
      if (group?.title === GROUP_TITLE && !this.yielding.has(tabId)) {
        const current = await this.currentTab(tabId);
        if (!current) {
          this.endOwnership(tabId, "tab_missing");
          throw tabNotOwnedError(tabId, "tab_missing");
        }
        if (current.active) {
          await this.yieldForTab(tabId, "tab_active");
          throw tabNotOwnedError(tabId, "tab_active");
        }
        if (current.groupId === group.id && !this.yielding.has(tabId)) return this.remember(current);
        reason = this.tabStates.get(tabId)?.reason ?? "group_changed";
      }
    }
    reason = this.tabStates.get(tabId)?.reason ?? reason;
    this.endOwnership(tabId, reason);
    throw tabNotOwnedError(tabId, reason);
  }

  async currentTab(tabId) {
    try { return await this.chrome.tabs.get(tabId); }
    catch (error) {
      if (error?.message === `No tab with id: ${tabId}.`) return null;
      throw error;
    }
  }

  async currentGroup(groupId) {
    try { return await this.chrome.tabGroups.get(groupId); }
    catch (error) {
      if (error?.message === `No group with id: ${groupId}.`) return null;
      throw error;
    }
  }

  async requireForPageAction(payload) {
    const tab = await this.requireTab(payload.tabId);
    if (payload.expectedUserSequence !== undefined && payload.expectedUserSequence !== tab.userSequence) {
      throw new ProtocolError("user_sequence_changed", "The tab changed after the last page read; read it again before acting.");
    }
    return tab;
  }

  endOwnership(tabId, reason) {
    const tab = this.tabs.get(tabId);
    if (!tab) return;
    this.tabs.delete(tabId);
    this.tabStates.set(tabId, { userSequence: tab.userSequence + 1, reason });
    this.ownershipEnded({ ...tab, userSequence: tab.userSequence + 1 }, reason);
    this.publish();
  }

  yieldForTab(tabId, reason) {
    const entry = this.yielding.get(tabId) ?? { reason, operation: null, error: null };
    if (entry.operation) return entry.operation;
    // Revoke before awaiting Chrome. A racing page request cannot use the tab.
    this.endOwnership(tabId, reason);
    this.yielding.set(tabId, entry);
    const operation = (async () => {
      const tab = await this.currentTab(tabId);
      if (!tab || tab.groupId < 0) return;
      const group = await this.currentGroup(tab.groupId);
      if (group?.title === GROUP_TITLE) await this.chrome.tabs.ungroup(tabId);
    })();
    entry.operation = operation;
    // Retain the failure and refusal, but let a later real ownership edge
    // finish the hand-back. No timer retries or admission before confirmation.
    void operation.then(() => {
      if (this.yielding.get(tabId) === entry) this.yielding.delete(tabId);
    }, error => { entry.error = error; entry.operation = null; });
    return operation;
  }

  tabUpdated(tabId, change, tab) {
    if (change.groupId !== undefined && this.tabs.has(tabId)) {
      this.endOwnership(tabId, "group_changed");
    }
    if (this.tabs.has(tabId)) { this.remember(tab); this.publish(); }
  }

  groupUpdated(group) {
    if (group.title !== GROUP_TITLE) {
      for (const tab of [...this.tabs.values()]) if (tab.groupId === group.id) this.endOwnership(tab.tabId, "outside_group");
    }
  }

  groupRemoved(group) {
    for (const tab of [...this.tabs.values()]) if (tab.groupId === group.id) this.endOwnership(tab.tabId, "outside_group");
  }

  tabRemoved(tabId) {
    this.endOwnership(tabId, "tab_closed");
    this.tabStates.delete(tabId);
  }

  async createTab(requireActive) {
    await this.migrateLegacyCustody();
    let window = await this.chrome.windows.getLastFocused({ windowTypes: ["normal"] }).catch(() => null);
    // No normal window (only DevTools, or all closed): open one in the background.
    // Its own blank tab stays active, so her tab is still created inactive.
    requireActive();
    let createdWindow = false;
    if (!Number.isInteger(window?.id)) {
      window = await this.chrome.windows.create({ focused: false, url: "about:blank" });
      createdWindow = true;
    }
    if (!Number.isInteger(window?.id) || window.type !== "normal") {
      throw new ProtocolError("workspace_unavailable", "Open a normal Chrome window for your NativeAgent tabs.");
    }
    const groups = await this.chrome.tabGroups.query({ windowId: window.id, title: GROUP_TITLE });
    try { requireActive(); }
    catch (error) {
      if (error.code === "action_cancelled" && createdWindow) {
        throw new ProtocolError("action_outcome_unknown", `Window ${window.id} and its initial blank tab were created before cancellation. No navigation was sent. Inspect that window before starting another request.`,
          { windowId: window.id });
      }
      throw error;
    }
    const tab = await this.chrome.tabs.create({ windowId: window.id, active: false, url: "about:blank" });
    if (!Number.isInteger(tab?.id) || tab.active !== false) {
      throw new ProtocolError("focus_invariant_failed", "Chrome did not create an inactive NativeAgent tab.");
    }
    let groupId;
    try {
      requireActive();
      groupId = await this.chrome.tabs.group({ tabIds: [tab.id],
        ...(groups.length ? { groupId: groups[0].id } : { createProperties: { windowId: window.id } }) });
      requireActive();
      if (!groups.length) await this.chrome.tabGroups.update(groupId, { title: GROUP_TITLE, color: "purple", collapsed: false });
    } catch (error) {
      if (error.code === "action_cancelled") {
        throw new ProtocolError("action_outcome_unknown", `Tab ${tab.id} in window ${window.id} was created before cancellation; its grouping may be incomplete. No navigation was sent. Inspect that tab before starting another request.`,
          { tabId: tab.id, windowId: window.id, groupId });
      }
      throw error;
    }
    const current = await this.chrome.tabs.get(tab.id);
    if (current.active || current.groupId !== groupId || this.yielding.has(tab.id)) {
      await this.yieldForTab(tab.id, "tab_activated_during_creation");
      throw new ProtocolError("workspace_changed", "The new tab was activated or moved during setup.");
    }
    return this.requireTab(tab.id);
  }

  async closeTab(payload, requireActive) {
    const tab = await this.requireForPageAction(payload);
    requireActive();
    await this.chrome.tabs.remove(tab.tabId);
    return { tabId: tab.tabId, url: tab.url, title: tab.title, tabClosed: true };
  }
}
