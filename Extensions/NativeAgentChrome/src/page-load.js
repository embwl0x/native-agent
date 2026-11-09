// One document's arrival, shared by navigation and reads. The clock only records evidence.
export class PageLoads {
  constructor(chrome, changed) {
    this.documents = new Map();
    this.changed = changed;
    chrome.webNavigation.onBeforeNavigate.addListener(details => {
      if (details.frameId !== 0) return;
      this.newDocument(details.tabId);
      this.changed(details.tabId);
    });
    chrome.webNavigation.onCommitted.addListener(details => {
      if (details.frameId !== 0) return;
      const state = this.documents.get(details.tabId) ?? this.newDocument(details.tabId);
      if (state.documentId !== details.documentId) {
        state.contentAt = null;
        state.loadedAt = null;
      }
      state.documentId = details.documentId;
      state.committedAt = this.now();
      state.url = details.url;
      state.error = null;
      this.changed(details.tabId);
    });
    const routeChanged = details => {
      if (details.frameId !== 0) return;
      const state = this.documents.get(details.tabId) ?? this.newDocument(details.tabId);
      this.documents.set(details.tabId, { ...state, documentId: details.documentId, url: details.url,
        contentAt: null, loadedAt: null, error: null });
      this.changed(details.tabId);
    };
    chrome.webNavigation.onHistoryStateUpdated.addListener(routeChanged);
    chrome.webNavigation.onReferenceFragmentUpdated.addListener(routeChanged);
    // Chrome's own load-completed event: a page with no readable prose has still arrived when its document finishes loading.
    chrome.webNavigation.onCompleted.addListener(details => {
      if (details.frameId !== 0) return;
      const state = this.documents.get(details.tabId);
      if (!state || (details.documentId && state.documentId && details.documentId !== state.documentId)) return;
      state.loadedAt = this.now();
      this.changed(details.tabId);
    });
    chrome.webNavigation.onErrorOccurred.addListener(details => {
      if (details.frameId !== 0) return;
      const state = this.documents.get(details.tabId) ?? this.newDocument(details.tabId);
      if (details.documentId && state.documentId && details.documentId !== state.documentId) return;
      state.error = details.error;
      this.changed(details.tabId);
    });
    chrome.tabs.onRemoved.addListener(tabId => this.remove(tabId));
    chrome.tabs.onReplaced.addListener((_added, removed) => this.remove(removed));
  }

  now() { return performance.timeOrigin + performance.now(); }

  newDocument(tabId) {
    const state = { documentId: null,
      committedAt: null, contentAt: null, loadedAt: null, error: null };
    this.documents.set(tabId, state);
    return state;
  }

  reader(tabId, documentId, observation) {
    const state = this.documents.get(tabId) ?? this.newDocument(tabId);
    if (state.documentId && state.documentId !== documentId && state.committedAt !== null) return;
    state.documentId = documentId;
    state.url = observation.url;
    state.contentAt = observation.contentPresent === true && Number.isFinite(observation.contentPresentAt) ? observation.contentPresentAt : null;
    this.changed(tabId);
  }

  arrival(tabId, documentId) {
    const state = this.documents.get(tabId);
    if (!state || state.documentId !== documentId) return null;
    if (state.error) return { error: state.error };
    const content = state.contentAt !== null;
    // Chrome's loaded event also admits documents whose prose the reader does not recognize.
    // Either event proves arrival, not completion of later script-rendered content.
    if (content) return { by: "content_present" };
    return state.loadedAt !== null ? { by: "document_loaded" } : null;
  }

  remove(tabId) {
    this.documents.delete(tabId);
  }
}
