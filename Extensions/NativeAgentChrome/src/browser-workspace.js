import { ProtocolError } from "./protocol.js";

export const WORKSPACE_STORAGE_KEY = "nativeAgentBrowserWorkspaceV1";

// Presentation/placement only. TabLeaseManager remains the sole tab owner.
// Work is visible beside the user's tabs, but never selects a tab or window.
export class BrowserWorkspace {
  constructor(chromeApi) { this.chrome = chromeApi; }

  async createTab(initialUrl) {
    const chrome = this.chrome;
    const stored = (await chrome.storage.session.get(WORKSPACE_STORAGE_KEY))[WORKSPACE_STORAGE_KEY];
    let workspace = null;
    if (stored?.version === 2 && Number.isInteger(stored.groupId)) {
      try {
        const group = await chrome.tabGroups.get(stored.groupId);
        const window = await chrome.windows.get(group.windowId);
        if (window.type === "normal") {
          workspace = { version: 2, windowId: window.id, groupId: group.id };
        }
      } catch { /* A removed group is recreated in the user's current browser window. */ }
    }
    if (!workspace) {
      const window = await chrome.windows.getLastFocused({ windowTypes: ["normal"] });
      if (!Number.isInteger(window?.id) || window.type !== "normal") {
        throw new ProtocolError("workspace_unavailable", "Open a normal Chrome window for the agent's grouped tabs.");
      }
      workspace = { version: 2, windowId: window.id };
      // An extension reload clears session storage, not Chrome's visible groups.
      // Reuse the unambiguous shared presentation group in this window only.
      // This grants no leases or authority over tabs already in that group.
      const groups = await chrome.tabGroups.query({ windowId: window.id, title: "NativeAgent" });
      if (groups.length > 1) {
        throw new ProtocolError("workspace_ambiguous", "Multiple NativeAgent groups are open in this window; consolidate them before creating another work tab.");
      }
      if (groups.length === 1) workspace.groupId = groups[0].id;
    }

    let tab;
    try {
      tab = await chrome.tabs.create({ windowId: workspace.windowId, active: false,
        url: initialUrl ?? "about:blank" });
      if (!Number.isInteger(tab?.id) || tab.active !== false || tab.windowId !== workspace.windowId) {
        throw new ProtocolError("focus_invariant_failed", "Chrome did not create an inactive workspace tab.");
      }
      let groupId;
      if (Number.isInteger(workspace.groupId)) {
        try {
          const group = await chrome.tabGroups.get(workspace.groupId);
          if (group.windowId === workspace.windowId) groupId = group.id;
        } catch { /* The user may have ungrouped or closed all old work tabs. */ }
      }
      const newGroup = groupId === undefined;
      groupId = await chrome.tabs.group({ tabIds: [tab.id],
        ...(groupId !== undefined ? { groupId } : { createProperties: { windowId: workspace.windowId } }) });
      if (newGroup) await chrome.tabGroups.update(groupId, { title: "NativeAgent", color: "purple", collapsed: false });
      await chrome.storage.session.set({ [WORKSPACE_STORAGE_KEY]: { ...workspace, groupId } });
      // Grouping/recovery is asynchronous; do not return a tab taken over meanwhile.
      tab = await chrome.tabs.get(tab.id);
      if (tab.active !== false || tab.windowId !== workspace.windowId || tab.groupId !== groupId) {
        throw new ProtocolError("workspace_changed", "The new tab was activated or moved during workspace setup.");
      }
      return tab;
    } catch (error) {
      if (Number.isInteger(tab?.id)) {
        try {
          const current = await chrome.tabs.get(tab.id);
          if (current.active === false && current.windowId === workspace.windowId) await chrome.tabs.remove(tab.id);
        } catch { /* Preserve the original setup failure. */ }
      }
      throw error;
    }
  }
}
