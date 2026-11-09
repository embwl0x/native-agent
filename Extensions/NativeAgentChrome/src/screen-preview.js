// Local Screen pane frames. No storage, page mutation, debugger attachment or focus change.
// Embedded surfaces are painted out: their secrets cannot be judged from the parent document.
export async function captureScreenPreview(payload, workspace, admit) {
  const owned = await workspace.requireForPageAction(payload);
  const receipt = { tabId: owned.tabId, url: owned.url, title: owned.title, userSequence: owned.userSequence };
  let background;
  let stage = "tab inspection";
  try {
    await admit();
    const tab = await chrome.tabs.get(owned.tabId);
    background = !tab.active;
    if (background) {
      if (payload.hasReadText) {
        return { ...receipt, state: "background", reason: "background tab; showing the returned read" };
      }
      const targets = await chrome.debugger.getTargets();
      if (!targets.some(target => target.tabId === tab.id && target.attached)) {
        return { ...receipt, state: "background", reason: "tab is in the background; a picture would show a new debugging banner" };
      }
    }
    // Exact document + viewport before and after capture. Missing masks never authorize an image.
    stage = "secure-field inspection";
    const before = await inspect(tab.id);
    await admit();
    let blob;
    stage = "tab capture";
    if (background) {
      const capture = await chrome.debugger.sendCommand({ tabId: tab.id }, "Page.captureScreenshot", {
        format: "png", fromSurface: true, captureBeyondViewport: false,
      });
      if (typeof capture?.data !== "string" || !capture.data.length) throw new Error("Chrome returned no tab picture");
      blob = new Blob([Uint8Array.from(atob(capture.data), byte => byte.charCodeAt(0))], { type: "image/png" });
    } else {
      // This window's selected tab must remain the exact target; never select a tab to capture it.
      const selected = await chrome.tabs.query({ windowId: tab.windowId, active: true });
      if (selected.length !== 1 || selected[0].id !== tab.id) throw new Error("The visible tab changed before capture");
      const data = await chrome.tabs.captureVisibleTab(tab.windowId, { format: "png" });
      const encoded = data.split(",")[1];
      if (!encoded) throw new Error("Chrome returned no visible tab picture");
      blob = new Blob([Uint8Array.from(atob(encoded), byte => byte.charCodeAt(0))], { type: "image/png" });
    }
    stage = "secure-field geometry verification";
    const after = await inspect(tab.id);
    await admit();
    const current = await chrome.tabs.get(tab.id);
    if (current.active !== tab.active || current.windowId !== tab.windowId || current.url !== tab.url
        || before.documentId !== after.documentId || JSON.stringify(before.result) !== JSON.stringify(after.result)) {
      return { ...receipt, state: "unavailable", reason: "tab or secure-field geometry changed during capture; picture withheld" };
    }
    stage = "secure-field painting and resizing";
    const picture = await maskCapturedPicture(blob, before.result, payload.maxWidth);
    await admit();
    return { ...receipt, state: "frame", ...picture };
  } catch {
    // This is the preview's own unavailable result, never a replacement action or an effect verdict.
    // Browser API errors can contain page addresses. Keep their stage, never page/query/field data, in the caption.
    return { ...receipt, state: "unavailable", reason: `${background ? "tab is in the background; " : ""}${stage} could not supply a safe picture` };
  }
}

async function inspect(tabId) {
  const readings = await chrome.scripting.executeScript({ target: { tabId, frameIds: [0] }, func: secureFieldGeometry });
  const reading = readings[0];
  if (readings.length !== 1 || !reading?.documentId || !reading.result || reading.result.error) {
    throw new Error(reading?.result?.error ?? "Secure fields could not be inspected");
  }
  return reading;
}

// Injected in the isolated extension world. Never reads a field's value, including in closed shadow roots.
function secureFieldGeometry() {
  const viewport = window.visualViewport;
  if (!viewport || viewport.width <= 0 || viewport.height <= 0
      || ![viewport.width, viewport.height, viewport.offsetLeft, viewport.offsetTop, scrollX, scrollY].every(Number.isFinite)) {
    return { error: "The tab has no readable viewport" };
  }
  const rects = [], roots = [document];
  let count = 0;
  while (roots.length) {
    for (const element of roots.pop().querySelectorAll("*")) {
      if (++count > 50_000) return { error: "Secure-field inspection exceeded its bounded document walk" };
      if (element instanceof HTMLElement) {
        const shadow = chrome.dom.openOrClosedShadowRoot(element);
        if (shadow) roots.push(shadow);
      }
      const autocomplete = (element.getAttribute("autocomplete") ?? "").toLowerCase();
      const secure = element.matches('input[type="password" i]') || autocomplete.includes("password") || autocomplete.includes("cc-");
      const embedded = element.matches("iframe, frame, object, embed, fencedframe");
      if (secure || embedded) {
        const rect = element.getBoundingClientRect();
        if (![rect.x, rect.y, rect.width, rect.height].every(Number.isFinite) || rect.width < 0 || rect.height < 0) {
          return { error: "Secure-field bounds could not be read" };
        }
        if (rect.width > 0 && rect.height > 0) rects.push({ x: rect.x, y: rect.y, width: rect.width, height: rect.height });
      }
    }
  }
  return { width: viewport.width, height: viewport.height, offsetLeft: viewport.offsetLeft, offsetTop: viewport.offsetTop,
    scrollX, scrollY, url: location.href, rects };
}

// Standalone preview captures are painted here; returned looks are painted only on the Mac.
async function maskCapturedPicture(blob, masks, maxWidth) {
  const bitmap = await createImageBitmap(blob);
  try {
    if (bitmap.width <= 0 || bitmap.height <= 0 || bitmap.width * bitmap.height > 32_000_000) {
      throw new Error("The tab picture is empty or exceeds the bounded painter");
    }
    // Mask at source resolution before downscaling, just like the Mac path.
    const canvas = new OffscreenCanvas(bitmap.width, bitmap.height);
    const context = canvas.getContext("2d");
    if (!context) throw new Error("The secure-field painter is unavailable");
    context.drawImage(bitmap, 0, 0);
    context.fillStyle = "#181818";
    const scaleX = bitmap.width / masks.width, scaleY = bitmap.height / masks.height;
    for (const rect of masks.rects) {
      const x = Math.floor((rect.x - masks.offsetLeft) * scaleX) - 2;
      const y = Math.floor((rect.y - masks.offsetTop) * scaleY) - 2;
      context.fillRect(x, y, Math.ceil(rect.width * scaleX) + 4, Math.ceil(rect.height * scaleY) + 4);
    }
    const scale = Math.min(1, maxWidth / bitmap.width);
    const width = Math.max(1, Math.round(bitmap.width * scale));
    const height = Math.max(1, Math.round(bitmap.height * scale));
    const small = new OffscreenCanvas(width, height);
    const painter = small.getContext("2d");
    if (!painter) throw new Error("The preview resizer is unavailable");
    painter.drawImage(canvas, 0, 0, width, height);
    const jpeg = await small.convertToBlob({ type: "image/jpeg", quality: 0.75 });
    if (jpeg.size > 650_000) throw new Error("The masked picture exceeds the preview transport bound");
    const bytes = new Uint8Array(await jpeg.arrayBuffer());
    let binary = "";
    for (let start = 0; start < bytes.length; start += 8192) binary += String.fromCharCode(...bytes.subarray(start, start + 8192));
    return { format: "jpeg", width, height, data: btoa(binary) };
  } finally { bitmap.close(); }
}

// A look's existing lease reads geometry once, immediately before its one capture.
// Missing geometry belongs only to the pane, never to the agent's read or its failures.
export async function readPicturePreviewGeometry(target, viewport) {
  try { return await pictureFieldGeometry(target, viewport); }
  catch { return null; }
}

// Read the exact DOM (with shadow trees), without attaching again or injecting into a PDF.
async function pictureFieldGeometry(target, viewport) {
  const snapshot = await chrome.debugger.sendCommand(target, "DOMSnapshot.captureSnapshot", { computedStyles: [] });
  const document = snapshot.documents?.at(0);
  const strings = snapshot.strings;
  if (!document || !Array.isArray(strings) || !Array.isArray(document.nodes?.attributes)
      || !Array.isArray(document.nodes?.nodeName) || !Array.isArray(document.layout?.nodeIndex) || !Array.isArray(document.layout?.bounds)
      || !(viewport?.clientWidth > 0) || !(viewport?.clientHeight > 0)
      || ![viewport.clientWidth, viewport.clientHeight, viewport.pageX, viewport.pageY].every(Number.isFinite)
      || document.nodes.attributes.length > 50_000) {
    throw new Error("The picture's secure-field geometry is unavailable");
  }
  const rects = [];
  // A 24 KiB metadata allowance at 192 JSON bytes per four-number rect permits 128 masks.
  // More masks cover the whole capture rather than growing the response or dropping a secret.
  const maxRects = Math.floor(24 * 1024 / 192);
  // DOMSnapshot uses -1 for an empty string, including boolean attribute values.
  const stringAt = index => {
    if (index === -1) return "";
    if (!Number.isSafeInteger(index) || index < 0) return undefined;
    const value = strings.at(index);
    return typeof value === "string" ? value : undefined;
  };
  // The snapshot's attribute and layout tables are parallel, with indexes into strings/nodes.
  for (const [position, nodeIndex] of document.layout.nodeIndex.entries()) {
    const validNodeIndex = Number.isSafeInteger(nodeIndex) && nodeIndex >= 0;
    const attributes = validNodeIndex ? document.nodes.attributes.at(nodeIndex) : undefined;
    const tag = validNodeIndex ? stringAt(document.nodes.nodeName.at(nodeIndex))?.toLowerCase() : undefined;
    let readable = !!tag && Array.isArray(attributes) && attributes.length % 2 === 0;
    const attrs = new Map();
    if (readable) {
      for (let index = 0; index < attributes.length; index += 2) {
        const name = stringAt(attributes.at(index)), value = stringAt(attributes.at(index + 1));
        if (name === undefined || value === undefined) { readable = false; break; }
        attrs.set(name.toLowerCase(), value.toLowerCase());
      }
    }
    const autocomplete = attrs.get("autocomplete") ?? "";
    const secure = (tag === "input" && attrs.get("type") === "password") || autocomplete.includes("password") || autocomplete.includes("cc-");
    if (!readable) throw new Error("The picture's node identity or attributes could not be read");
    const embedded = ["iframe", "frame", "object", "embed", "fencedframe"].includes(tag);
    if (!secure && !embedded) continue;
    const bounds = document.layout.bounds.at(position);
    const [x, y, width, height] = Array.isArray(bounds) ? bounds : [];
    if (!Array.isArray(bounds) || bounds.length !== 4 || ![x, y, width, height].every(Number.isFinite) || width < 0 || height < 0) {
      throw new Error("The picture's secure-field bounds could not be read");
    }
    const localX = x - viewport.pageX, localY = y - viewport.pageY;
    const farX = localX + width, farY = localY + height;
    if (![localX, localY, farX, farY].every(Number.isFinite)) {
      throw new Error("The picture's capture-relative bounds could not be read");
    }
    const left = Math.max(0, localX), top = Math.max(0, localY);
    const right = Math.min(viewport.clientWidth, farX), bottom = Math.min(viewport.clientHeight, farY);
    if (right > left && bottom > top) {
      if (rects.length === maxRects) {
        return { width: viewport.clientWidth, height: viewport.clientHeight,
          rects: [{ x: 0, y: 0, width: viewport.clientWidth, height: viewport.clientHeight }] };
      }
      rects.push({ x: left, y: top, width: right - left, height: bottom - top });
    }
  }
  return { width: viewport.clientWidth, height: viewport.clientHeight, rects };
}
