// Air Traffic für Safari (SPEC §20.2): Rechtsklick auf Links und Symbolleisten-Knopf.
// Übergabe per Native Messaging an SafariWebExtensionHandler, der airtraffic://open?… öffnet.
// Keine Host-Berechtigungen, kein Content-Script.

// Hinweis: Nur ASCII im Code – Safari liest Hintergrund-Skripte nicht zuverlässig als UTF-8.
// Nicht-ASCII-Zeichen in Strings als \uXXXX schreiben (SPEC §21.1).
const api = globalThis.browser ?? globalThis.chrome;

const MENU_OPEN = "airtraffic-open";
const MENU_CHOOSE = "airtraffic-choose";

function isWebURL(value) {
  if (typeof value !== "string") return false;
  try {
    const url = new URL(value);
    return url.protocol === "http:" || url.protocol === "https:";
  } catch {
    return false;
  }
}

async function sendToAirTraffic(url, prompt) {
  if (!isWebURL(url)) {
    console.warn("Air Traffic: nur http/https-Links");
    return;
  }
  try {
    // Safari ignoriert die Anwendungs-ID und spricht immer die eigene App-Erweiterung an.
    const response = await api.runtime.sendNativeMessage("de.neoskop.AirTraffic", {
      action: "open",
      url,
      prompt: Boolean(prompt),
    });
    if (!response?.ok) console.warn("Air Traffic:", response?.error ?? "keine Antwort");
  } catch (error) {
    console.error("Air Traffic: Native Messaging fehlgeschlagen", error);
  }
}

// Bei jedem Start der Hintergrundseite neu anlegen (removeAll vermeidet doppelte IDs).
async function createMenus() {
  await api.contextMenus.removeAll();
  api.contextMenus.create({ id: MENU_OPEN, title: "Mit Air Traffic \u00f6ffnen", contexts: ["link"] });
  api.contextMenus.create({ id: MENU_CHOOSE, title: "Mit Air Traffic ausw\u00e4hlen \u2026", contexts: ["link"] });
}

createMenus().catch((error) => console.error("Air Traffic: Men\u00fc", error));

api.contextMenus.onClicked.addListener((info) => {
  if (info.menuItemId === MENU_OPEN) sendToAirTraffic(info.linkUrl, false);
  if (info.menuItemId === MENU_CHOOSE) sendToAirTraffic(info.linkUrl, true);
});

// Symbolleisten-Knopf: aktuelle Seite (activeTab liefert tab.url nur nach dem Klick).
api.action.onClicked.addListener((tab) => sendToAirTraffic(tab?.url, false));
