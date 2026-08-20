import { ProtocolError } from "./protocol.js";

export const LEASE_STORAGE_KEY = "nativeAgentTabLeasesV1";
export const DEFAULT_LEASE_DURATION_MS = 60_000;
export const MIN_LEASE_DURATION_MS = 30_000;
export const MAX_LEASE_DURATION_MS = 300_000;

const ALARM_PREFIX = "nativeagent.chrome.lease.";
const ID_PATTERN = /^[A-Za-z0-9._:-]{1,128}$/;

export class TabLeaseManager {
  constructor({ chromeApi, emitEvent, now = () => Date.now(), uuid = () => crypto.randomUUID() }) {
    this.chrome = chromeApi;
    this.emitEvent = emitEvent;
    this.now = now;
    this.uuid = uuid;
    this.leases = new Map();
    this.pendingOperation = Promise.resolve();
  }

  restore() {
    return this.serial(() => this.restoreLocked());
  }

  async restoreLocked() {
    const stored = await this.chrome.storage.session.get(LEASE_STORAGE_KEY);
    const rows = stored[LEASE_STORAGE_KEY];
    if (!Array.isArray(rows)) return;

    let changed = false;
    const seenTabs = new Set();
    for (const row of rows) {
      if (!validStoredLease(row) || seenTabs.has(row.tabId)) {
        changed = true;
        continue;
      }
      if (Date.parse(row.expiresAt) <= this.now()) {
        changed = true;
        continue;
      }
      try {
        await this.chrome.tabs.get(row.tabId);
      } catch {
        changed = true;
        continue;
      }
      this.leases.set(row.leaseId, row);
      seenTabs.add(row.tabId);
      await this.scheduleExpiry(row);
    }
    if (changed) await this.persist();
  }

  acquire(payload) {
    return this.serial(() => this.acquireLocked(payload));
  }

  async acquireLocked(payload) {
    let tab;
    let ownership;
    if (payload.mode === "create") {
      tab = await this.chrome.tabs.create({
        active: false,
        ...(payload.initialUrl ? { url: payload.initialUrl } : {}),
      });
      ownership = "created";
      if (tab.active === true) {
        if (Number.isInteger(tab.id)) await this.bestEffortRemoveTab(tab.id);
        throw new ProtocolError(
          "focus_invariant_failed",
          "Chrome activated a tab that NativeAgent requested in the background.",
        );
      }
    } else {
      tab = await this.chrome.tabs.get(payload.tabId);
      if (tab.url !== payload.expectedTab.url || (tab.title ?? "") !== payload.expectedTab.title) {
        throw new ProtocolError(
          "tab_identity_changed",
          "The claimed tab no longer matches the exact URL and title supplied by the host.",
        );
      }
      ownership = "claimed";
    }

    if (!Number.isInteger(tab.id)) {
      throw new ProtocolError("tab_unavailable", "Chrome did not return a stable tab id.");
    }
    if (this.leaseForTab(tab.id)) {
      if (ownership === "created") await this.bestEffortRemoveTab(tab.id);
      throw new ProtocolError("tab_already_leased", "The tab already belongs to a NativeAgent lease.");
    }

    const nowMs = this.now();
    const durationMs = payload.leaseDurationMs ?? DEFAULT_LEASE_DURATION_MS;
    const lease = {
      leaseId: this.uuid(),
      tabId: tab.id,
      windowId: tab.windowId,
      ownership,
      state: "active",
      userSequence: 0,
      createdAt: new Date(nowMs).toISOString(),
      renewedAt: new Date(nowMs).toISOString(),
      expiresAt: new Date(nowMs + durationMs).toISOString(),
      originalTab: {
        active: Boolean(tab.active),
        title: tab.title ?? "",
        url: tab.url ?? "",
      },
    };

    this.leases.set(lease.leaseId, lease);
    try {
      await this.persist();
      await this.scheduleExpiry(lease);
    } catch (error) {
      this.leases.delete(lease.leaseId);
      if (ownership === "created") await this.bestEffortRemoveTab(tab.id);
      throw error;
    }
    const result = publicLease(lease);
    this.emitEvent("lease.granted", result);
    return result;
  }

  renew(payload) {
    return this.serial(() => this.renewLocked(payload));
  }

  async renewLocked(payload) {
    const lease = this.requireLease(payload.leaseId);
    this.requireSequence(lease, payload.expectedUserSequence);
    const nowMs = this.now();
    const durationMs = payload.leaseDurationMs ?? DEFAULT_LEASE_DURATION_MS;
    lease.renewedAt = new Date(nowMs).toISOString();
    lease.expiresAt = new Date(nowMs + durationMs).toISOString();
    await this.persist();
    await this.scheduleExpiry(lease);
    const result = publicLease(lease);
    this.emitEvent("lease.renewed", result);
    return result;
  }

  release(payload, reason = "host_released") {
    return this.serial(() => this.releaseLocked(payload, reason));
  }

  async releaseLocked(payload, reason = "host_released") {
    const lease = this.requireLease(payload.leaseId);
    this.leases.delete(lease.leaseId);
    await this.clearExpiry(lease.leaseId);
    await this.persist();

    let tabClosed = false;
    if (lease.ownership === "created" && payload.closeCreatedTab !== false) {
      try {
        const currentTab = await this.chrome.tabs.get(lease.tabId);
        if (currentTab.active !== true) {
          await this.chrome.tabs.remove(lease.tabId);
          tabClosed = true;
        }
      } catch {
        // An already-closed ephemeral tab is still a complete release.
      }
    }
    const event = releaseEvent(lease, reason);
    this.emitEvent("lease.released", event);
    return { ...event, released: true, tabClosed };
  }

  yieldForTab(tabId, reason) {
    return this.serial(() => this.yieldForTabLocked(tabId, reason));
  }

  async yieldForTabLocked(tabId, reason) {
    const lease = this.leaseForTab(tabId);
    if (!lease) return false;

    this.leases.delete(lease.leaseId);
    await this.clearExpiry(lease.leaseId);
    await this.persist();
    this.emitEvent("lease.yielded", {
      leaseId: lease.leaseId,
      tabId: lease.tabId,
      reason,
      userSequence: lease.userSequence + 1,
    });
    return true;
  }

  tabRemoved(tabId) {
    return this.serial(() => this.tabRemovedLocked(tabId));
  }

  async tabRemovedLocked(tabId) {
    const lease = this.leaseForTab(tabId);
    if (!lease) return false;
    this.leases.delete(lease.leaseId);
    await this.clearExpiry(lease.leaseId);
    await this.persist();
    this.emitEvent("lease.released", releaseEvent(lease, "tab_closed"));
    return true;
  }

  alarmFired(alarmName) {
    return this.serial(() => this.alarmFiredLocked(alarmName));
  }

  async alarmFiredLocked(alarmName) {
    if (!alarmName.startsWith(ALARM_PREFIX)) return false;
    const leaseId = alarmName.slice(ALARM_PREFIX.length);
    const lease = this.leases.get(leaseId);
    if (!lease) return false;
    if (Date.parse(lease.expiresAt) > this.now()) {
      await this.scheduleExpiry(lease);
      return false;
    }
    await this.releaseLocked({ leaseId, closeCreatedTab: true }, "lease_expired");
    return true;
  }

  requireForPageAction(payload) {
    const lease = this.requireLease(payload.leaseId);
    if (payload.expectedUserSequence !== undefined) {
      this.requireSequence(lease, payload.expectedUserSequence);
    }
    return lease;
  }

  requireLease(leaseId) {
    const lease = this.leases.get(leaseId);
    if (!lease) throw new ProtocolError("lease_not_found", "The tab lease does not exist.");
    return lease;
  }

  requireSequence(lease, expectedUserSequence) {
    if (lease.userSequence !== expectedUserSequence) {
      throw new ProtocolError(
        "stale_user_sequence",
        "The tab changed after the host last observed it.",
        { userSequence: lease.userSequence },
      );
    }
  }

  leaseForTab(tabId) {
    return [...this.leases.values()].find((lease) => lease.tabId === tabId);
  }

  serial(operation) {
    const result = this.pendingOperation.then(operation, operation);
    this.pendingOperation = result.then(() => undefined, () => undefined);
    return result;
  }

  async persist() {
    await this.chrome.storage.session.set({ [LEASE_STORAGE_KEY]: [...this.leases.values()] });
  }

  async scheduleExpiry(lease) {
    await this.chrome.alarms.create(`${ALARM_PREFIX}${lease.leaseId}`, {
      when: Date.parse(lease.expiresAt),
    });
  }

  async clearExpiry(leaseId) {
    await this.chrome.alarms.clear(`${ALARM_PREFIX}${leaseId}`);
  }

  async bestEffortRemoveTab(tabId) {
    try {
      await this.chrome.tabs.remove(tabId);
    } catch {
      // Cleanup cannot recover focus, but must not hide the original invariant error.
    }
  }
}

function validStoredLease(row) {
  return row !== null
    && typeof row === "object"
    && ID_PATTERN.test(row.leaseId)
    && Number.isInteger(row.tabId)
    && Number.isInteger(row.windowId)
    && (row.ownership === "created" || row.ownership === "claimed")
    && row.state === "active"
    && Number.isInteger(row.userSequence)
    && row.userSequence >= 0
    && Number.isFinite(Date.parse(row.createdAt))
    && Number.isFinite(Date.parse(row.renewedAt))
    && Number.isFinite(Date.parse(row.expiresAt))
    && row.originalTab !== null
    && typeof row.originalTab === "object"
    && typeof row.originalTab.active === "boolean"
    && typeof row.originalTab.title === "string"
    && typeof row.originalTab.url === "string";
}

function publicLease(lease) {
  return structuredClone(lease);
}

function releaseEvent(lease, reason) {
  return {
    leaseId: lease.leaseId,
    tabId: lease.tabId,
    reason,
    userSequence: lease.userSequence,
  };
}
